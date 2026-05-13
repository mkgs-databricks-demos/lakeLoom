/**
 * Pairing routes — QR generation, device confirmation, and device management.
 *
 * Endpoints:
 *   GET  /api/pairing/qr        — Browser-authenticated. Mints QR payload.
 *   POST /api/pairing/confirm   — iOS-authenticated (Layer 0+1, unbound session OK).
 *   GET  /api/pairing/devices   — Browser-authenticated. Lists paired devices.
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

// ── Interfaces ───────────────────────────────────────────────────────────────

interface LakebaseClient {
  query(text: string, params?: unknown[]): Promise<{ rows: Record<string, unknown>[] }>;
}

interface AppKitContext {
  lakebase: LakebaseClient;
  server: { extend(fn: (app: Application) => void): void };
}

// ── Validation schemas ───────────────────────────────────────────────────────

const ConfirmBody = z.object({
  device_pubkey: z.string().min(1, 'device_pubkey is required'),
  device_label: z.string().min(1, 'device_label is required').max(100),
});

// ── Route setup ──────────────────────────────────────────────────────────────

export async function setupPairingRoutes(appkit: AppKitContext): Promise<void> {
  const { lakebase } = appkit;

  appkit.server.extend((app) => {
    // ── GET /api/pairing/qr ────────────────────────────────────────────────
    // Browser-authenticated (on-behalf-of-user via AppKit).
    // Mints a new session token and returns the QR payload JSON.
    app.get('/api/pairing/qr', async (req, res, next) => {
      try {
        // Check readiness
        if (!isPairingReady()) {
          throw xcodeSPNNotProvisioned(getMissingKeys());
        }

        // Get current user from AppKit on-behalf-of headers
        const userId = req.headers['x-forwarded-user'] as string | undefined;
        const userEmail = req.headers['x-forwarded-email'] as string | undefined;
        if (!userId) {
          throw validationError('User identity not available. Ensure you are authenticated.');
        }

        // Delete any previous unconfirmed pairing for this user
        await lakebase.query(
          `DELETE FROM app.paired_sessions
           WHERE user_id = $1 AND device_pubkey IS NULL AND revoked_at IS NULL`,
          [userId],
        );

        // Generate session token
        const { token, hash } = generateSessionToken();
        const expiresAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000); // 7 days

        // Insert new pairing session
        await lakebase.query(
          `INSERT INTO app.paired_sessions (token_hash, user_id, workspace_id, expires_at)
           VALUES ($1, $2, $3, $4)`,
          [hash, userId, getSecrets().workspaceUrl ?? '', expiresAt.toISOString()],
        );

        // Build QR payload
        const xcodeCreds = getXcodeSPNCredentials()!;
        const secrets = getSecrets();

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
            base_url: `https://${req.headers.host}`,
          },
        };

        res.json(payload);
      } catch (err) {
        next(err);
      }
    });

    // ── POST /api/pairing/confirm ──────────────────────────────────────────
    // iOS-authenticated: Layer 0 (M2M) validated by sidecar, Layer 1 special-case.
    // Binds the device public key to the session.
    app.post(
      '/api/pairing/confirm',
      iosAuth({ lakebase, allowUnboundSession: true }),
      async (req, res, next) => {
        try {
          const parsed = ConfirmBody.safeParse(req.body);
          if (!parsed.success) {
            throw validationError(parsed.error.issues.map((i) => i.message).join('; '));
          }

          const { device_pubkey, device_label } = parsed.data;
          const pubkeyBuffer = Buffer.from(device_pubkey, 'base64url');

          // Get the session (already validated by middleware)
          const sessionId = req.user!.sessionId;

          // Verify the session hasn't already been confirmed
          const { rows } = await lakebase.query(
            `SELECT device_pubkey FROM app.paired_sessions WHERE id = $1`,
            [sessionId],
          );
          if (rows.length > 0 && rows[0].device_pubkey != null) {
            throw pairingAlreadyConfirmed();
          }

          // Self-attestation: verify the supplied signature against the supplied pubkey
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

          // Bind the device key
          await lakebase.query(
            `UPDATE app.paired_sessions
             SET device_pubkey = $1, device_label = $2, first_seen_at = now(), last_seen_at = now()
             WHERE id = $3`,
            [pubkeyBuffer, device_label, sessionId],
          );

          // Push SSE event to browser
          const userId = req.user!.userId;
          pushEvent(userId, 'device_paired', {
            device_id: sessionId,
            device_label,
          });

          res.json({ device_id: sessionId });
        } catch (err) {
          next(err);
        }
      },
    );

    // ── GET /api/pairing/devices ───────────────────────────────────────────
    // Browser-authenticated. Lists all non-revoked paired devices for current user.
    app.get('/api/pairing/devices', async (req, res, next) => {
      try {
        const userId = req.headers['x-forwarded-user'] as string | undefined;
        if (!userId) {
          throw validationError('User identity not available.');
        }

        const { rows } = await lakebase.query(
          `SELECT id, device_label, first_seen_at, last_seen_at, expires_at, paired_at
           FROM app.paired_sessions
           WHERE user_id = $1 AND revoked_at IS NULL AND device_pubkey IS NOT NULL
           ORDER BY paired_at DESC`,
          [userId],
        );

        const devices = rows.map((r) => ({
          id: r.id,
          label: r.device_label,
          first_seen_at: r.first_seen_at,
          last_seen_at: r.last_seen_at,
          expires_at: r.expires_at,
          paired_at: r.paired_at,
        }));

        res.json({ devices });
      } catch (err) {
        next(err);
      }
    });

    // ── DELETE /api/pairing/devices/:id ─────────────────────────────────────
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
    // Browser SSE endpoint. Holds open connection for real-time pairing events.
    app.get('/api/pairing/events', (req, res) => {
      const userId = req.headers['x-forwarded-user'] as string | undefined;
      if (!userId) {
        res.status(401).json({ error: 'User identity not available.' });
        return;
      }

      // Set SSE headers
      res.setHeader('Content-Type', 'text/event-stream');
      res.setHeader('Cache-Control', 'no-cache');
      res.setHeader('Connection', 'keep-alive');
      res.setHeader('X-Accel-Buffering', 'no'); // Disable nginx buffering
      res.flushHeaders();

      // Send initial keepalive
      res.write(': connected\n\n');

      // Register connection
      addConnection(userId, res);

      // Keepalive every 30s to prevent proxy timeouts
      const keepalive = setInterval(() => {
        res.write(': keepalive\n\n');
      }, 30_000);

      req.on('close', () => {
        clearInterval(keepalive);
      });
    });
  });
}
