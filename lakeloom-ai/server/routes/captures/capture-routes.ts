/**
 * Capture session lifecycle routes.
 *
 * Manages the lifecycle of recording sessions (audio + screenshots + transcript).
 * iOS creates a capture before uploading files to it; the server enforces that
 * uploads only go to 'active' captures.
 *
 * Endpoints:
 *   POST   /api/projects/:project_id/captures       — Create a new capture session
 *   PATCH  /api/captures/:capture_session_id        — Transition state (complete/cancel)
 *   GET    /api/captures/:capture_session_id        — Get capture details (+uploads)
 *   GET    /api/projects/:project_id/captures       — List captures for a project
 *
 * All endpoints require iOS Layer 0+1 authentication (iosAuth middleware).
 */

import { z } from 'zod';
import type { Application } from 'express';
import { iosAuth } from '../../middleware/ios-auth';
import { validationError } from '../../lib/errors';

// ── Interfaces ───────────────────────────────────────────────────────────────

interface LakebaseClient {
  query(text: string, params?: unknown[]): Promise<{ rows: Record<string, unknown>[] }>;
}

interface AppKitContext {
  lakebase: LakebaseClient;
  server: { extend(fn: (app: Application) => void): void };
}

// ── Validation schemas ───────────────────────────────────────────────────────

const CreateCaptureBody = z.object({
  label: z.string().max(200).optional(),
  client_ts: z.string().datetime().optional(),
});

const PatchCaptureBody = z.object({
  state: z.enum(['completed', 'cancelled']),
  ended_at: z.string().datetime().optional(),
});

// ── Route setup ──────────────────────────────────────────────────────────────

export async function setupCaptureRoutes(appkit: AppKitContext): Promise<void> {
  const { lakebase } = appkit;
  const auth = iosAuth({ lakebase });

  appkit.server.extend((app) => {
    // ── POST /api/projects/:project_id/captures ────────────────────────────
    // iOS-authenticated. Creates a new active capture session.
    app.post('/api/projects/:project_id/captures', auth, async (req, res, next) => {
      try {
        const parsed = CreateCaptureBody.safeParse(req.body);
        if (!parsed.success) {
          throw validationError(parsed.error.issues.map((i) => i.message).join('; '));
        }

        const { label, client_ts } = parsed.data;
        const projectId = req.params.project_id;
        const userId = req.user!.userId;
        const pairedSessionId = req.user!.sessionId;

        // Resolve device_label from the paired session
        const { rows: deviceRows } = await lakebase.query(
          `SELECT device_label FROM app.paired_sessions WHERE id = $1`,
          [pairedSessionId],
        );
        const deviceLabel = deviceRows.length > 0 ? (deviceRows[0].device_label as string) : null;

        // Determine started_at: prefer client_ts if provided, else server now()
        const startedAt = client_ts ? new Date(client_ts).toISOString() : new Date().toISOString();

        const { rows } = await lakebase.query(
          `INSERT INTO app.capture_sessions
             (project_id, created_by_user_id, created_by_paired_session_id, device_label, label, started_at)
           VALUES ($1, $2, $3, $4, $5, $6)
           RETURNING id, project_id, state, label, started_at`,
          [projectId, userId, pairedSessionId, deviceLabel, label ?? null, startedAt],
        );

        const capture = rows[0];
        res.status(201).json({
          id: capture.id,
          project_id: capture.project_id,
          state: capture.state,
          label: capture.label,
          started_at: capture.started_at,
        });
      } catch (err) {
        next(err);
      }
    });

    // ── PATCH /api/captures/:capture_session_id ────────────────────────────
    // iOS-authenticated. Transitions state: active → completed | cancelled.
    // Authz: only the creating user can transition.
    app.patch('/api/captures/:capture_session_id', auth, async (req, res, next) => {
      try {
        const parsed = PatchCaptureBody.safeParse(req.body);
        if (!parsed.success) {
          throw validationError(parsed.error.issues.map((i) => i.message).join('; '));
        }

        const { state, ended_at } = parsed.data;
        const captureId = req.params.capture_session_id;
        const userId = req.user!.userId;

        // Fetch current capture and verify ownership + state
        const { rows: existing } = await lakebase.query(
          `SELECT id, created_by_user_id, state FROM app.capture_sessions
           WHERE id = $1 AND revoked_at IS NULL`,
          [captureId],
        );

        if (existing.length === 0) {
          throw validationError('Capture session not found.');
        }

        const capture = existing[0];

        if (capture.created_by_user_id !== userId) {
          throw validationError('Only the creating user can transition capture state.');
        }

        if (capture.state !== 'active') {
          throw validationError(
            `Cannot transition from '${capture.state}' to '${state}'. Only 'active' captures can be transitioned.`,
          );
        }

        // Apply state transition
        const endedAtValue = ended_at ? new Date(ended_at).toISOString() : new Date().toISOString();

        const { rows: updated } = await lakebase.query(
          `UPDATE app.capture_sessions
           SET state = $1, ended_at = $2
           WHERE id = $3
           RETURNING id, project_id, state, label, started_at, ended_at`,
          [state, endedAtValue, captureId],
        );

        res.json(updated[0]);
      } catch (err) {
        next(err);
      }
    });

    // ── GET /api/captures/:capture_session_id ──────────────────────────────
    // iOS-authenticated. Returns capture metadata. Supports ?include=uploads.
    app.get('/api/captures/:capture_session_id', auth, async (req, res, next) => {
      try {
        const captureId = req.params.capture_session_id;
        const include = req.query.include as string | undefined;

        const { rows } = await lakebase.query(
          `SELECT id, project_id, created_by_user_id, created_by_paired_session_id,
                  device_label, state, label, started_at, ended_at
           FROM app.capture_sessions
           WHERE id = $1 AND revoked_at IS NULL`,
          [captureId],
        );

        if (rows.length === 0) {
          throw validationError('Capture session not found.');
        }

        const capture = rows[0];

        // Optionally include uploads
        let uploads: Record<string, unknown>[] | undefined;
        if (include === 'uploads') {
          const { rows: uploadRows } = await lakebase.query(
            `SELECT id, kind, volume_path, mime_type, size_bytes, sha256_hex,
                    original_filename, client_ts, uploaded_at
             FROM app.uploads
             WHERE capture_session_id = $1 AND revoked_at IS NULL
             ORDER BY uploaded_at ASC`,
            [captureId],
          );
          uploads = uploadRows;
        }

        res.json({
          ...capture,
          ...(uploads !== undefined && { uploads }),
        });
      } catch (err) {
        next(err);
      }
    });

    // ── GET /api/projects/:project_id/captures ─────────────────────────────
    // iOS-authenticated. Lists captures for a project.
    // Query params: ?state=active|completed|cancelled, ?limit=N, ?before=<ISO>
    app.get('/api/projects/:project_id/captures', auth, async (req, res, next) => {
      try {
        const projectId = req.params.project_id;
        const stateFilter = req.query.state as string | undefined;
        const limit = Math.min(parseInt(req.query.limit as string, 10) || 50, 200);
        const before = req.query.before as string | undefined;

        let sql = `
          SELECT id, project_id, created_by_user_id, device_label, state, label, started_at, ended_at
          FROM app.capture_sessions
          WHERE project_id = $1 AND revoked_at IS NULL
        `;
        const params: unknown[] = [projectId];
        let paramIdx = 2;

        if (stateFilter && ['active', 'completed', 'cancelled'].includes(stateFilter)) {
          sql += ` AND state = $${paramIdx}`;
          params.push(stateFilter);
          paramIdx++;
        }

        if (before) {
          sql += ` AND started_at < $${paramIdx}`;
          params.push(before);
          paramIdx++;
        }

        sql += ` ORDER BY started_at DESC LIMIT $${paramIdx}`;
        params.push(limit);

        const { rows } = await lakebase.query(sql, params);

        res.json({ captures: rows });
      } catch (err) {
        next(err);
      }
    });
  });
}
