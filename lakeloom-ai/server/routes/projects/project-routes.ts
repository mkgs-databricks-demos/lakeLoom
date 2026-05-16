/**
 * Project management routes.
 *
 * Full CRUD for lakeLoom projects — the top-level organizational unit.
 * Both iOS and browser clients use these endpoints.
 *
 * Endpoints:
 *   GET    /api/v1/projects          — List projects (cursor-based pagination)
 *   GET    /api/v1/projects/:id      — Fetch single project
 *   POST   /api/v1/projects          — Create project (idempotent via client_generated_id)
 *   PATCH  /api/v1/projects/:id      — Edit name/description
 *   PATCH  /api/v1/projects/:id/archive  — Soft delete
 *   PATCH  /api/v1/projects/:id/restore  — Unarchive
 *
 * Auth: dualAuth — accepts iOS Layer 2 OR browser on-behalf-of-user.
 *
 * Identity model:
 *   Both iOS and browser resolve to the same user_id (SCIM compound ID,
 *   e.g. "1081964970114387@7474657291520070"). This is set during QR pairing
 *   (browser's X-Forwarded-User stored in paired_sessions.user_id) and read
 *   back by iosAuth on every iOS request. The LIST endpoint filters by
 *   created_by_user_id to ensure the same user sees the same projects
 *   regardless of auth path.
 *
 * Pagination: Cursor-based using composite (updated_at, id) for stable ordering.
 * The cursor is an opaque base64url-encoded token. Clients pass ?cursor=<token>
 * to fetch the next page. Response includes `next_cursor` when more rows exist.
 *
 * Contract matches iOS Module 06 (ProjectService) spec:
 *   architecture/LakeLoomMarkdowns/module-06-project-service.md
 */

import { z } from 'zod';
import type { Application } from 'express';
import { dualAuth } from '../../middleware/browser-auth';
import { validationError, AppError, ErrorTypes } from '../../lib/errors';

// ── Interfaces ─────────────────────────────────────────────────────────────

interface LakebaseClient {
  query(text: string, params?: unknown[]): Promise<{ rows: Record<string, unknown>[] }>;
}

interface AppKitContext {
  lakebase: LakebaseClient;
  server: { extend(fn: (app: Application) => void): void };
}

// ── Validation schemas ─────────────────────────────────────────────────────

const CreateProjectBody = z.object({
  name: z.string().min(1, 'Project name is required').max(200, 'Name must be 200 characters or fewer'),
  description: z.string().max(2000).optional().nullable(),
  workspace_id: z.string().optional().nullable(),
  client_generated_id: z.string().max(100).optional().nullable(),
});

const PatchProjectBody = z.object({
  name: z.string().min(1).max(200).optional(),
  description: z.string().max(2000).optional().nullable(),
});

// ── Cursor helpers ─────────────────────────────────────────────────────────
// Cursor encodes (updated_at, id) as base64url JSON. Opaque to clients.
// Using (updated_at DESC, id DESC) ordering — newer projects first, tie-break by id.

interface CursorPayload {
  u: string; // updated_at ISO string
  i: string; // project id (UUIDv7)
}

function encodeCursor(updatedAt: string, id: string): string {
  const payload: CursorPayload = { u: updatedAt, i: id };
  return Buffer.from(JSON.stringify(payload)).toString('base64url');
}

function decodeCursor(cursor: string): CursorPayload | null {
  try {
    const json = Buffer.from(cursor, 'base64url').toString('utf8');
    const parsed = JSON.parse(json);
    if (typeof parsed.u === 'string' && typeof parsed.i === 'string') {
      return parsed as CursorPayload;
    }
    return null;
  } catch {
    return null;
  }
}

// ── Error factories ───────────────────────────────────────────────────────

function projectNotFound(projectId: string): AppError {
  return new AppError({
    type: ErrorTypes.VALIDATION_ERROR,
    status: 404,
    title: 'Project not found',
    detail: `No project found with id '${projectId}'.`,
  });
}

// ── Route setup ────────────────────────────────────────────────────────────

export async function setupProjectRoutes(appkit: AppKitContext): Promise<void> {
  const { lakebase } = appkit;
  const auth = dualAuth({ lakebase });

  appkit.server.extend((app) => {
    // ── GET /api/v1/projects ───────────────────────────────────────────
    // List projects with cursor-based pagination.
    //
    // Scoping: filters by created_by_user_id (consistent across iOS and browser).
    // Both auth paths resolve to the same SCIM compound ID (e.g. "123@456"):
    //   - Browser: from X-Forwarded-User header (set by auth sidecar)
    //   - iOS: from paired_sessions.user_id (stored during QR pairing)
    //
    // Query params:
    //   ?archived=true|false  — filter by archive status (default: false)
    //   ?q=<search>           — ILIKE name search
    //   ?limit=N              — page size (default 25, max 100)
    //   ?cursor=<token>       — opaque cursor from previous response's next_cursor
    //
    // Response:
    //   { projects: [...], next_cursor: "<token>" | null, has_more: boolean }
    //
    app.get('/api/v1/projects', auth, async (req, res, next) => {
      try {
        const userId = req.user!.userId;
        const showArchived = req.query.archived === 'true';
        const search = req.query.q as string | undefined;
        const limit = Math.min(Math.max(parseInt(req.query.limit as string, 10) || 25, 1), 100);
        const cursorParam = req.query.cursor as string | undefined;

        // Decode cursor if provided
        let cursorData: CursorPayload | null = null;
        if (cursorParam) {
          cursorData = decodeCursor(cursorParam);
          if (!cursorData) {
            throw validationError('Invalid cursor token.');
          }
        }

        // Build query — ORDER BY updated_at DESC, id DESC
        // Filter by created_by_user_id for consistent iOS/browser identity.
        let sql = `
          SELECT id, name, description, workspace_id, created_by_user_id,
                 created_by_username, archived, created_at, updated_at
          FROM app.projects
          WHERE created_by_user_id = $1
        `;
        const params: unknown[] = [userId];
        let paramIdx = 2;

        if (!showArchived) {
          sql += ` AND archived = false`;
        }

        if (search && search.trim().length > 0) {
          sql += ` AND name ILIKE $${paramIdx}`;
          params.push(`%${search.trim()}%`);
          paramIdx++;
        }

        // Cursor seek condition — row-value comparison for composite sort
        if (cursorData) {
          sql += ` AND (updated_at, id) < ($${paramIdx}, $${paramIdx + 1})`;
          params.push(cursorData.u, cursorData.i);
          paramIdx += 2;
        }

        // Fetch limit + 1 to detect whether there are more pages
        sql += ` ORDER BY updated_at DESC, id DESC LIMIT $${paramIdx}`;
        params.push(limit + 1);

        const { rows } = await lakebase.query(sql, params);

        // Determine if there's a next page
        const hasMore = rows.length > limit;
        const pageRows = hasMore ? rows.slice(0, limit) : rows;

        // Build next cursor from the last item in this page
        let nextCursor: string | null = null;
        if (hasMore && pageRows.length > 0) {
          const lastRow = pageRows[pageRows.length - 1];
          nextCursor = encodeCursor(
            lastRow.updated_at as string,
            lastRow.id as string,
          );
        }

        res.json({
          projects: pageRows.map(formatProject),
          next_cursor: nextCursor,
          has_more: hasMore,
        });
      } catch (err) {
        next(err);
      }
    });

    // ── GET /api/v1/projects/:id ──────────────────────────────────────
    // Fetch a single project by ID.
    app.get('/api/v1/projects/:id', auth, async (req, res, next) => {
      try {
        const projectId = req.params.id as string;

        const { rows } = await lakebase.query(
          `SELECT id, name, description, workspace_id, created_by_user_id,
                  created_by_username, archived, created_at, updated_at
           FROM app.projects
           WHERE id = $1`,
          [projectId],
        );

        if (rows.length === 0) {
          throw projectNotFound(projectId);
        }

        res.json(formatProject(rows[0]));
      } catch (err) {
        next(err);
      }
    });

    // ── POST /api/v1/projects ─────────────────────────────────────────
    // Create a new project. Idempotent via (created_by_user_id, client_generated_id).
    // Returns 201 on first create, 200 on idempotent re-submit.
    //
    // workspace_id is optional:
    //   - iOS sends it explicitly (from QR payload's workspace.url)
    //   - Browser omits it (server derives from req.user.workspaceId)
    app.post('/api/v1/projects', auth, async (req, res, next) => {
      try {
        const parsed = CreateProjectBody.safeParse(req.body);
        if (!parsed.success) {
          throw validationError(parsed.error.issues.map((i) => i.message).join('; '));
        }

        const { name, description, client_generated_id } = parsed.data;
        // workspace_id: iOS sends explicitly (from QR payload), browser omits.
        // Fallback to user context (workspaceId from auth middleware).
        const workspace_id = parsed.data.workspace_id || req.user!.workspaceId || '';
        const userId = req.user!.userId;
        // Resolve username from platform headers or fallback
        const username =
          (req.headers['x-forwarded-preferred-username'] as string) ||
          (req.headers['x-forwarded-email'] as string) ||
          userId;

        // ── Idempotency check ───────────────────────────────────────
        if (client_generated_id) {
          const { rows: existing } = await lakebase.query(
            `SELECT id, name, description, workspace_id, created_by_user_id,
                    created_by_username, archived, created_at, updated_at
             FROM app.projects
             WHERE created_by_user_id = $1 AND client_generated_id = $2`,
            [userId, client_generated_id],
          );

          if (existing.length > 0) {
            // Idempotent re-submit — return the existing project
            res.status(200).json(formatProject(existing[0]));
            return;
          }
        }

        // ── Insert new project ──────────────────────────────────────
        const { rows } = await lakebase.query(
          `INSERT INTO app.projects
             (name, description, workspace_id, created_by_user_id, created_by_username, client_generated_id)
           VALUES ($1, $2, $3, $4, $5, $6)
           RETURNING id, name, description, workspace_id, created_by_user_id,
                     created_by_username, archived, created_at, updated_at`,
          [name, description ?? null, workspace_id, userId, username, client_generated_id ?? null],
        );

        res.status(201).json(formatProject(rows[0]));
      } catch (err) {
        next(err);
      }
    });

    // ── PATCH /api/v1/projects/:id ────────────────────────────────────
    // Edit project name and/or description.
    app.patch('/api/v1/projects/:id', auth, async (req, res, next) => {
      try {
        const projectId = req.params.id as string;
        const parsed = PatchProjectBody.safeParse(req.body);
        if (!parsed.success) {
          throw validationError(parsed.error.issues.map((i) => i.message).join('; '));
        }

        const { name, description } = parsed.data;

        if (name === undefined && description === undefined) {
          throw validationError('At least one of name or description must be provided.');
        }

        // Verify project exists
        const { rows: existing } = await lakebase.query(
          `SELECT id FROM app.projects WHERE id = $1`,
          [projectId],
        );
        if (existing.length === 0) {
          throw projectNotFound(projectId);
        }

        // Build dynamic update
        const setClauses: string[] = ['updated_at = now()'];
        const values: unknown[] = [];
        let paramIdx = 1;

        if (name !== undefined) {
          setClauses.push(`name = $${paramIdx}`);
          values.push(name);
          paramIdx++;
        }
        if (description !== undefined) {
          setClauses.push(`description = $${paramIdx}`);
          values.push(description);
          paramIdx++;
        }

        values.push(projectId);

        const { rows } = await lakebase.query(
          `UPDATE app.projects
           SET ${setClauses.join(', ')}
           WHERE id = $${paramIdx}
           RETURNING id, name, description, workspace_id, created_by_user_id,
                     created_by_username, archived, created_at, updated_at`,
          values,
        );

        res.json(formatProject(rows[0]));
      } catch (err) {
        next(err);
      }
    });

    // ── PATCH /api/v1/projects/:id/archive ────────────────────────────
    // Soft-delete a project.
    app.patch('/api/v1/projects/:id/archive', auth, async (req, res, next) => {
      try {
        const projectId = req.params.id as string;

        const { rows } = await lakebase.query(
          `UPDATE app.projects
           SET archived = true, updated_at = now()
           WHERE id = $1 AND archived = false
           RETURNING id`,
          [projectId],
        );

        if (rows.length === 0) {
          throw projectNotFound(projectId);
        }

        res.status(204).send();
      } catch (err) {
        next(err);
      }
    });

    // ── PATCH /api/v1/projects/:id/restore ────────────────────────────
    // Unarchive a project.
    app.patch('/api/v1/projects/:id/restore', auth, async (req, res, next) => {
      try {
        const projectId = req.params.id as string;

        const { rows } = await lakebase.query(
          `UPDATE app.projects
           SET archived = false, updated_at = now()
           WHERE id = $1 AND archived = true
           RETURNING id`,
          [projectId],
        );

        if (rows.length === 0) {
          throw projectNotFound(projectId);
        }

        res.status(204).send();
      } catch (err) {
        next(err);
      }
    });

    // ── POST /api/v1/projects/:id/devices ────────────────────────────────
    // Associate a paired device with this project.
    // Creates an assignment so the iPhone knows which project to target.
    // Idempotent: re-assigning the same device returns 200 (not 409).
    app.post('/api/v1/projects/:id/devices', auth, async (req, res, next) => {
      try {
        const projectId = req.params.id as string;
        const { paired_session_id } = req.body ?? {};

        if (!paired_session_id || typeof paired_session_id !== 'string') {
          throw validationError('paired_session_id is required.');
        }

        // Verify project exists
        const { rows: projRows } = await lakebase.query(
          `SELECT id FROM app.projects WHERE id = $1`,
          [projectId],
        );
        if (projRows.length === 0) {
          throw projectNotFound(projectId);
        }

        // Upsert assignment (ON CONFLICT = idempotent)
        const { rows } = await lakebase.query(
          `INSERT INTO app.project_device_assignments
             (project_id, paired_session_id, assigned_by_user_id)
           VALUES ($1, $2, $3)
           ON CONFLICT (project_id, paired_session_id) DO UPDATE
             SET assigned_by_user_id = EXCLUDED.assigned_by_user_id,
                 assigned_at = NOW()
           RETURNING id, project_id, paired_session_id, assigned_by_user_id, assigned_at`,
          [projectId, paired_session_id, req.user!.userId],
        );

        res.status(201).json(rows[0]);
      } catch (err) {
        next(err);
      }
    });

    // ── GET /api/v1/projects/:id/devices ─────────────────────────────────
    // List devices assigned to this project (with device labels from paired_sessions).
    app.get('/api/v1/projects/:id/devices', auth, async (req, res, next) => {
      try {
        const projectId = req.params.id as string;

        const { rows } = await lakebase.query(
          `SELECT pda.id, pda.paired_session_id, pda.assigned_at,
                  ps.device_label, ps.last_seen_at
           FROM app.project_device_assignments pda
           JOIN app.paired_sessions ps ON ps.id = pda.paired_session_id
           WHERE pda.project_id = $1
           ORDER BY pda.assigned_at DESC`,
          [projectId],
        );

        res.json({ devices: rows });
      } catch (err) {
        next(err);
      }
    });

  });
}

// ── Response formatting ──────────────────────────────────────────────────────
// Consistent field names for both iOS and browser clients.

function formatProject(row: Record<string, unknown>) {
  return {
    project_id: row.id,
    project_name: row.name,
    description: row.description,
    workspace_id: row.workspace_id,
    created_by_user_id: row.created_by_user_id,
    created_by_username: row.created_by_username,
    created_at: row.created_at,
    updated_at: row.updated_at,
    archived: row.archived,
  };
}
