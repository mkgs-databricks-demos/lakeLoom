/**
 * Layer 1 auth middleware for iOS-originating requests.
 *
 * Validates the three X-Lakeloom-* headers on every iOS → App request:
 *   - X-Lakeloom-Session-Token: opaque session token from QR pairing
 *   - X-Lakeloom-Timestamp: unix seconds (replay defense)
 *   - X-Lakeloom-Signature: base64url-encoded ECDSA P-256 DER signature
 *
 * Layer 0 (Authorization: Bearer <M2M>) is already validated by the
 * Databricks Apps platform sidecar before requests reach this code.
 *
 * Verification order (per Isaac's spec):
 *   1. Token lookup by sha256(token) in paired_sessions
 *   2. Revocation check (revoked_at IS NULL)
 *   3. Expiry check (expires_at > now)
 *   4. Timestamp skew (90s past, 30s future)
 *   5. ECDSA signature verification against bound device_pubkey
 *   6. Success: update last_seen_at, attach req.user
 */

import type { Request, Response, NextFunction } from 'express';
import { sha256, sha256Hex, verifyEcdsaP256, buildCanonicalMessage } from '../lib/crypto';
import {
  tokenNotFound,
  tokenExpired,
  timestampSkew,
  invalidSignature,
  AppError,
} from '../lib/errors';

// ── Augment Express Request ──────────────────────────────────────────────────

export interface AuthenticatedUser {
  userId: string;
  workspaceId: string;
  sessionId: string;
}

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      user?: AuthenticatedUser;
    }
  }
}

// ── Lakebase query interface ─────────────────────────────────────────────────

interface LakebaseClient {
  query(text: string, params?: unknown[]): Promise<{ rows: Record<string, unknown>[] }>;
}

// ── Timestamp skew constants ─────────────────────────────────────────────────
const MAX_PAST_SKEW_SECONDS = 90;
const MAX_FUTURE_SKEW_SECONDS = 30;

// ── Middleware factory ───────────────────────────────────────────────────────

export interface IosAuthOptions {
  lakebase: LakebaseClient;
  /** If true, allow sessions without device_pubkey (for /pairing/confirm only) */
  allowUnboundSession?: boolean;
}

/**
 * Create the iOS auth middleware.
 *
 * Usage:
 *   app.use('/api/sessions', iosAuth({ lakebase }));
 *   app.post('/api/pairing/confirm', iosAuth({ lakebase, allowUnboundSession: true }), handler);
 */
export function iosAuth(opts: IosAuthOptions) {
  const { lakebase, allowUnboundSession = false } = opts;

  return async (req: Request, _res: Response, next: NextFunction): Promise<void> => {
    try {
      // ── Extract headers ──────────────────────────────────────────────────
      const sessionToken = req.headers['x-lakeloom-session-token'] as string | undefined;
      const timestampStr = req.headers['x-lakeloom-timestamp'] as string | undefined;
      const signatureB64 = req.headers['x-lakeloom-signature'] as string | undefined;

      if (!sessionToken || !timestampStr || !signatureB64) {
        throw tokenNotFound();
      }

      // ── 1. Token lookup ──────────────────────────────────────────────────
      const tokenHash = sha256(sessionToken);
      const { rows } = await lakebase.query(
        `SELECT id, user_id, workspace_id, device_pubkey, expires_at, revoked_at
         FROM app.paired_sessions
         WHERE token_hash = $1`,
        [tokenHash],
      );

      if (rows.length === 0) {
        throw tokenNotFound();
      }

      const session = rows[0];

      // ── 2. Revocation check ──────────────────────────────────────────────
      if (session.revoked_at != null) {
        throw tokenNotFound();
      }

      // ── 3. Expiry check ──────────────────────────────────────────────────
      const expiresAt = new Date(session.expires_at as string);
      if (expiresAt < new Date()) {
        throw tokenExpired();
      }

      // ── 4. Timestamp skew ────────────────────────────────────────────────
      const timestamp = parseInt(timestampStr, 10);
      if (isNaN(timestamp)) {
        throw timestampSkew();
      }
      const now = Math.floor(Date.now() / 1000);
      if (now - timestamp > MAX_PAST_SKEW_SECONDS || timestamp - now > MAX_FUTURE_SKEW_SECONDS) {
        throw timestampSkew();
      }

      // ── 5. Signature verification ────────────────────────────────────────
      const devicePubkey = session.device_pubkey as Buffer | null;

      if (!devicePubkey && !allowUnboundSession) {
        // Session exists but no device key bound yet — reject unless this is /pairing/confirm
        throw tokenNotFound();
      }

      if (devicePubkey) {
        // Compute body hash
        const bodyHash = req.body ? sha256Hex(JSON.stringify(req.body)) : '';
        const canonical = buildCanonicalMessage(req.method, req.originalUrl, timestampStr, bodyHash);
        const signature = Buffer.from(signatureB64, 'base64url');

        if (!verifyEcdsaP256(devicePubkey, canonical, signature)) {
          throw invalidSignature();
        }
      }

      // ── 6. Success ───────────────────────────────────────────────────────
      // Update last_seen_at (non-blocking — don't await, fire and forget)
      lakebase
        .query(`UPDATE app.paired_sessions SET last_seen_at = now() WHERE id = $1`, [session.id])
        .catch((err) => console.warn('[ios-auth] Failed to update last_seen_at:', err));

      // Attach user context
      req.user = {
        userId: session.user_id as string,
        workspaceId: session.workspace_id as string,
        sessionId: session.id as string,
      };

      next();
    } catch (err) {
      if (err instanceof AppError) {
        next(err);
      } else {
        console.error('[ios-auth] Unexpected error:', err);
        next(err);
      }
    }
  };
}
