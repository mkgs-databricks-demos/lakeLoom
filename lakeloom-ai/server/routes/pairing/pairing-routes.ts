/**
 * Pairing routes — QR generation, device confirmation, and device management.
 *
 * Endpoints:
 *   GET  /api/pairing/qr        — Browser-authenticated. Mints QR payload.
 *   POST /api/pairing/confirm   — iOS-authenticated (Layer 0+1, unbound session OK).
 *   GET  /api/pairing/devices   — Browser-authenticated. Lists paired devices.
 *   GET  /api/pairing/devices/:id/stats — Browser-authenticated. Device activity stats.
 *   PATCH /api/pairing/devices/:id — Browser-authenticated. Rename device.
 *   POST /api/pairing/devices/:id/extend — Browser-authenticated. Extend device expiry.
 *   POST /api/pairing/devices/:id/repair — Browser-authenticated. Re-pair existing device.
 *   DELETE /api/pairing/devices/:id — Browser-authenticated. Soft-revokes a device.
 *   GET  /api/pairing/events    — Browser SSE. Real-time pairing notifications.
 */

import { z } from 'zod';
import type { Application } from 'express';
import { generateSessionToken, verifyEcdsaP256, buildCanonicalMessage, sha256Hex } from '../../lib/crypto';
import {
  xcodeSPNNotProvisioned,
  pairingAlreadyConfirmed,
  deviceNotFound,
  validationError,
  invalidSignature,
} from '../../lib/errors';
import { getSecrets, getMissingKeys, isPairingReady, getXcodeSPNCredentials } from '../../services/secrets-service';
import { addConnection, pushEvent } from '../../services/sse-service';
import { iosAuth } from '../../middleware/ios-auth';

// ── Interfaces ───────────────────────────────────────────────────────────────────

interface LakebaseClient {
  query(text: string, params?: unknown[]): Promise<{ rows: Record<string, unknown>[] }>;
}

interface AppKitContext {
  lakebase: LakebaseClient;
  server: { extend(fn: (app: Application) => void): void };
}

// ── Validation schemas ─────────────────────────────────────────────────────────

const ConfirmBody = z.object({
  device_pubkey: z.string().min(1, 'device_pubkey is required'),
  device_label: z.string().min(1, 'device_label is required').max(100),
  device_id: z.string().uuid().optional(),
});

const RenameBody = z.object({
  label: z.string().min(1, 'Label is required').max(100),
});

const ExtendBody = z.object({
  days: z.number().int().min(1).max(30).default(7),
});

// ── Route setup ────────────────────────────────────────────────────────────────

export async function setupPairingRoutes(appkit: AppKitContext): Promise<void> {
  const { lakebase } = appkit;

  appkit.server.extend((app) => {
    // ── GET /api/pairing/qr ────────────────────────────────────────────────
    app.get('/api/pairing/qr', async (req, res, next) => {
      try {
        if (!isPairingReady()) {
          throw xcodeSPNNotProvisioned(getMissingKeys());
        }

        const userId = req.headers['x-forwarded-user'] as string | undefined;
        const userEmail = req.headers['x-forwarded-email'] as string | undefined;
        if (!userId) {
          throw validationError('User identity not available. Ensure you are authenticated.');
        }

        const username = userEmail ?? (req.headers['x-forwarded-preferred-username'] as string | undefined) ?? null;

        await lakebase.query(
          `DELETE FROM app.paired_sessions
           WHERE user_id = $1 AND device_pubkey IS NULL AND revoked_at IS NULL`,
          [userId],
        );

        const { token, hash } = generateSessionToken();
        const expiresAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000);

        await lakebase.query(
          `INSERT INTO app.paired_sessions (token_hash, user_id, username, workspace_id, expires_at)
           VALUES ($1, $2, $3, $4, $5)`,
          [hash, userId, username, getSecrets().workspaceUrl ?? '', expiresAt.toISOString()],
        );

        const xcodeCreds = getXcodeSPNCredentials()!;
        const secrets = getSecrets();
        const forwardedHost = (req.headers['x-forwarded-host'] as string | undefined) ?? req.headers.host;
        const forwardedProto = (req.headers['x-forwarded-proto'] as string | undefined) ?? 'https';

        const payload = {
          v: 1,
          workspace: {
            url: secrets.workspaceUrl,
            id: process.env.DATABRICKS_WORKSPACE_ID ?? '',
            name: process.env.DATABRICKS_WORKSPACE_NAME ?? '',
            cloud: 'aws',
          },
          user: {
            scim_id: userId,
            user_name: userEmail ?? '',
            display_name: (req.headers['x-forwarded-preferred-username'] as string) ?? userEmail ?? '',
          },
          xcode_spn: {
            client_id: xcodeCreds.clientId,
            client_secret: xcodeCreds.clientSecret,
          },
          session: {
            token,
            expires_at: expiresAt.toISOString(),
          },
          app: {
            base_url: `${forwardedProto}://${forwardedHost}`,
          },
        };

        res.json(payload);
      } catch (err) {
        next(err);
      }
    });

    // ── POST /api/pairing/confirm ──────────────────────────────────────────
    app.post(
      '/api/pairing/confirm',
      iosAuth({ lakebase, allowUnboundSession: true }),
      async (req, res, next) => {
        try {
          const parsed = ConfirmBody.safeParse(req.body);
          if (!parsed.success) {
            throw validationError(parsed.error.issues.map((i) => i.message).join('; '));
          }

          const { device_pubkey, device_label, device_id } = parsed.data;
          const pubkeyBuffer = Buffer.from(device_pubkey, 'base64url');
          const sessionId = req.user!.sessionId;

          const { rows } = await lakebase.query(
            `SELECT device_pubkey FROM app.paired_sessions WHERE id = $1`,
            [sessionId],
          );
          if (rows.length > 0 && rows[0].device_pubkey != null) {
            throw pairingAlreadyConfirmed();
          }

          const timestampStr = req.headers['x-lakeloom-timestamp'] as string;
          const signatureB64 = req.headers['x-lakeloom-signature'] as string;
          if (signatureB64 && pubkeyBuffer.length > 0) {
            const bodyHash = sha256Hex(JSON.stringify(req.body));
            const canonical = buildCanonicalMessage(req.method, req.originalUrl, timestampStr, bodyHash);
            const signature = Buffer.from(signatureB64, 'base64url');
            if (!verifyEcdsaP256(pubkeyBuffer, canonical, signature)) {
              throw invalidSignature();
            }
          }

          await lakebase.query(
            `UPDATE app.paired_sessions
             SET device_pubkey = $1, device_label = $2, device_id = $3::uuid, first_seen_at = now(), last_seen_at = now()
             WHERE id = $4`,
            [pubkeyBuffer, device_label, device_id ?? null, sessionId],
          );

          const userId = req.user!.userId;
          pushEvent(userId, 'device_paired', {
            paired_session_id: sessionId,
            device_label,
          });

          res.json({ paired_session_id: sessionId });
        } catch (err) {
          next(err);
        }
      },
    );

    // ── GET /api/pairing/devices ───────────────────────────────────────────
    // Query params: ?include_revoked=true | ?all_users=true
    app.get('/api/pairing/devices', async (req, res, next) => {
      try {
        const userId = req.headers['x-forwarded-user'] as string | undefined;
        if (!userId) {
          throw validationError('User identity not available.');
        }

        const includeRevoked = req.query.include_revoked === 'true';
        const allUsers = req.query.all_users === 'true';
        const revokedFilter = includeRevoked ? '' : 'AND revoked_at IS NULL';
        const userFilter = allUsers ? '' : 'AND user_id = $1';

        const { rows } = await lakebase.query(
          `SELECT id, device_label, first_seen_at, last_seen_at, expires_at, paired_at, revoked_at, username, user_id
           FROM app.paired_sessions
           WHERE device_pubkey IS NOT NULL ${revokedFilter} ${userFilter}
           ORDER BY paired_at DESC`,
          allUsers ? [] : [userId],
        );

        const devices = rows.map((r) => ({
          id: r.id,
          label: r.device_label,
          first_seen_at: r.first_seen_at,
          last_seen_at: r.last_seen_at,
          expires_at: r.expires_at,
          paired_at: r.paired_at,
          revoked_at: r.revoked_at ?? null,
          username: r.username ?? null,
          user_id: r.user_id,
          is_mine: r.user_id === userId,
        }));

        res.json({ devices });
      } catch (err) {
        next(err);
      }
    });

    // ── GET /api/pairing/devices/:id/stats ─────────────────────────────────
    app.get('/api/pairing/devices/:id/stats', async (req, res, next) => {
      try {
        const userId = req.headers['x-forwarded-user'] as string | undefined;
        if (!userId) {
          throw validationError('User identity not available.');
        }

        const deviceId = req.params.id;

        const { rows: deviceRows } = await lakebase.query(
          `SELECT id, device_label, username, user_id FROM app.paired_sessions WHERE id = $1`,
          [deviceId],
        );
        if (deviceRows.length === 0) {
          throw deviceNotFound();
        }

        const { rows: projectRows } = await lakebase.query(
          `SELECT COUNT(DISTINCT project_id)::int AS project_count
           FROM app.project_device_assignments
           WHERE paired_session_id = $1`,
          [deviceId],
        );

        const { rows: uploadRows } = await lakebase.query(
          `SELECT COUNT(*)::int AS upload_count
           FROM app.uploads
           WHERE paired_session_id = $1 AND revoked_at IS NULL`,
          [deviceId],
        );

        const { rows: captureRows } = await lakebase.query(
          `SELECT
             COUNT(*)::int AS capture_count,
             COUNT(*) FILTER (WHERE state = 'completed')::int AS completed_count,
             COUNT(*) FILTER (WHERE state = 'active')::int AS active_count,
             COUNT(*) FILTER (WHERE state = 'cancelled')::int AS cancelled_count
           FROM app.capture_sessions
           WHERE created_by_paired_session_id = $1 AND revoked_at IS NULL`,
          [deviceId],
        );

        const { rows: kindRows } = await lakebase.query(
          `SELECT kind, COUNT(*)::int AS count
           FROM app.uploads
           WHERE paired_session_id = $1 AND revoked_at IS NULL
           GROUP BY kind
           ORDER BY count DESC`,
          [deviceId],
        );

        const { rows: recentProjectRows } = await lakebase.query(
          `SELECT p.id, p.name, pda.assigned_at
           FROM app.project_device_assignments pda
           JOIN app.projects p ON p.id = pda.project_id
           WHERE pda.paired_session_id = $1
           ORDER BY pda.assigned_at DESC
           LIMIT 1`,
          [deviceId],
        );

        res.json({
          device_id: deviceId,
          project_count: projectRows[0]?.project_count ?? 0,
          upload_count: uploadRows[0]?.upload_count ?? 0,
          capture_count: captureRows[0]?.capture_count ?? 0,
          captures: {
            completed: captureRows[0]?.completed_count ?? 0,
            active: captureRows[0]?.active_count ?? 0,
            cancelled: captureRows[0]?.cancelled_count ?? 0,
          },
          upload_kinds: kindRows.reduce((acc, r) => {
            acc[r.kind as string] = r.count;
            return acc;
          }, {} as Record<string, number>),
          most_recent_project: recentProjectRows.length > 0
            ? { id: recentProjectRows[0].id, name: recentProjectRows[0].name, assigned_at: recentProjectRows[0].assigned_at }
            : null,
        });
      } catch (err) {
        next(err);
      }
    });

    // ── PATCH /api/pairing/devices/:id ─────────────────────────────────────
    // Browser-authenticated. Rename a device (owner only).
    app.patch('/api/pairing/devices/:id', async (req, res, next) => {
      try {
        const userId = req.headers['x-forwarded-user'] as string | undefined;
        if (!userId) {
          throw validationError('User identity not available.');
        }

        const parsed = RenameBody.safeParse(req.body);
        if (!parsed.success) {
          throw validationError(parsed.error.issues.map((i) => i.message).join('; '));
        }

        const deviceId = req.params.id;
        const { label } = parsed.data;

        const { rows } = await lakebase.query(
          `UPDATE app.paired_sessions
           SET device_label = $1
           WHERE id = $2 AND user_id = $3
           RETURNING id, device_label`,
          [label, deviceId, userId],
        );

        if (rows.length === 0) {
          throw deviceNotFound();
        }

        res.json({ id: rows[0].id, label: rows[0].device_label });
      } catch (err) {
        next(err);
      }
    });

    // ── POST /api/pairing/devices/:id/extend ───────────────────────────────
    // Browser-authenticated. Extends the expiry of a paired device (owner only).
    // Body: { days?: number } — defaults to 7, max 30.
    // Extends from the LATER of (current expiry, now) so expired devices are revived.
    app.post('/api/pairing/devices/:id/extend', async (req, res, next) => {
      try {
        const userId = req.headers['x-forwarded-user'] as string | undefined;
        if (!userId) {
          throw validationError('User identity not available.');
        }

        const parsed = ExtendBody.safeParse(req.body ?? {});
        if (!parsed.success) {
          throw validationError(parsed.error.issues.map((i) => i.message).join('; '));
        }

        const deviceId = req.params.id;
        const { days } = parsed.data;

        // Fetch current expiry (owner-gated)
        const { rows: current } = await lakebase.query(
          `SELECT id, expires_at, revoked_at FROM app.paired_sessions
           WHERE id = $1 AND user_id = $2`,
          [deviceId, userId],
        );

        if (current.length === 0) {
          throw deviceNotFound();
        }

        if (current[0].revoked_at) {
          throw validationError('Cannot extend a revoked device. Re-pair instead.');
        }

        // Extend from the later of current expiry or now
        const currentExpiry = new Date(current[0].expires_at as string);
        const base = currentExpiry.getTime() > Date.now() ? currentExpiry : new Date();
        const newExpiry = new Date(base.getTime() + days * 24 * 60 * 60 * 1000);

        await lakebase.query(
          `UPDATE app.paired_sessions SET expires_at = $1 WHERE id = $2 AND user_id = $3`,
          [newExpiry.toISOString(), deviceId, userId],
        );

        res.json({ id: deviceId, expires_at: newExpiry.toISOString() });
      } catch (err) {
        next(err);
      }
    });


    // ── POST /api/pairing/devices/:id/repair ────────────────────────────
    // Browser-authenticated. Re-pairs an existing device by generating a
    // fresh QR payload. Resets the token, clears device_pubkey (awaiting
    // re-confirmation from iOS), sets new expiry, and un-revokes if needed.
    // This avoids creating duplicate device entries when re-pairing a phone.
    app.post('/api/pairing/devices/:id/repair', async (req, res, next) => {
      try {
        if (!isPairingReady()) {
          throw xcodeSPNNotProvisioned(getMissingKeys());
        }

        const userId = req.headers['x-forwarded-user'] as string | undefined;
        const userEmail = req.headers['x-forwarded-email'] as string | undefined;
        if (!userId) {
          throw validationError('User identity not available.');
        }

        const deviceId = req.params.id;

        // Verify device exists and belongs to user
        const { rows: deviceRows } = await lakebase.query(
          `SELECT id, device_label, user_id FROM app.paired_sessions WHERE id = $1 AND user_id = $2`,
          [deviceId, userId],
        );
        if (deviceRows.length === 0) {
          throw deviceNotFound();
        }

        // Generate fresh session token + expiry
        const { token, hash } = generateSessionToken();
        const expiresAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000);

        // Reset the device row: new token, clear pubkey (awaiting confirm), new expiry, un-revoke
        await lakebase.query(
          `UPDATE app.paired_sessions
           SET token_hash = $1, device_pubkey = NULL, expires_at = $2,
               revoked_at = NULL, first_seen_at = NULL, last_seen_at = NULL
           WHERE id = $3 AND user_id = $4`,
          [hash, expiresAt.toISOString(), deviceId, userId],
        );

        // Build same QR payload as GET /api/pairing/qr
        const xcodeCreds = getXcodeSPNCredentials()!;
        const secrets = getSecrets();
        const forwardedHost = (req.headers['x-forwarded-host'] as string | undefined) ?? req.headers.host;
        const forwardedProto = (req.headers['x-forwarded-proto'] as string | undefined) ?? 'https';

        const payload = {
          v: 1,
          workspace: {
            url: secrets.workspaceUrl,
            id: process.env.DATABRICKS_WORKSPACE_ID ?? '',
            name: process.env.DATABRICKS_WORKSPACE_NAME ?? '',
            cloud: 'aws',
          },
          user: {
            scim_id: userId,
            user_name: userEmail ?? '',
            display_name: (req.headers['x-forwarded-preferred-username'] as string) ?? userEmail ?? '',
          },
          xcode_spn: {
            client_id: xcodeCreds.clientId,
            client_secret: xcodeCreds.clientSecret,
          },
          session: {
            token,
            expires_at: expiresAt.toISOString(),
          },
          app: {
            base_url: `${forwardedProto}://${forwardedHost}`,
          },
        };

        res.json(payload);
      } catch (err) {
        next(err);
      }
    });

    // ── DELETE /api/pairing/devices/:id ────────────────────────────────────
    // Browser-authenticated. Soft-revokes a paired device.
    app.delete('/api/pairing/devices/:id', async (req, res, next) => {
      try {
        const userId = req.headers['x-forwarded-user'] as string | undefined;
        if (!userId) {
          throw validationError('User identity not available.');
        }

        const deviceId = req.params.id;
        const { rows } = await lakebase.query(
          `UPDATE app.paired_sessions
           SET revoked_at = now()
           WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL
           RETURNING id`,
          [deviceId, userId],
        );

        if (rows.length === 0) {
          throw deviceNotFound();
        }

        res.status(204).send();
      } catch (err) {
        next(err);
      }
    });

    // ── GET /api/pairing/events ────────────────────────────────────────────
    app.get('/api/pairing/events', (req, res) => {
      const userId = req.headers['x-forwarded-user'] as string | undefined;
      if (!userId) {
        res.status(401).json({ error: 'User identity not available.' });
        return;
      }

      res.setHeader('Content-Type', 'text/event-stream');
      res.setHeader('Cache-Control', 'no-cache');
      res.setHeader('Connection', 'keep-alive');
      res.setHeader('X-Accel-Buffering', 'no');
      res.flushHeaders();

      res.write(': connected\n\n');
      addConnection(userId, res);

      const keepalive = setInterval(() => {
        res.write(': keepalive\n\n');
      }, 30_000);

      req.on('close', () => {
        clearInterval(keepalive);
      });
    });
  });
}
