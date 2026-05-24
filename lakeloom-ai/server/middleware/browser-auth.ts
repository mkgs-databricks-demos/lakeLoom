/**
 * Browser auth middleware for on-behalf-of-user requests.
 *
 * Databricks Apps platform injects user identity headers when a request
 * comes from the authenticated browser session (the auth sidecar validates
 * the session cookie and forwards identity headers to the app):
 *
 *   X-Forwarded-Email: matthew.giglia@databricks.com
 *   X-Forwarded-User: <SCIM user_id>
 *   X-Forwarded-Preferred-Username: matthew.giglia@databricks.com
 *
 * This middleware extracts those headers and attaches req.user for parity
 * with the iOS iosAuth middleware. Browser requests do NOT carry the
 * X-Lakeloom-* headers — that's how the router distinguishes iOS from browser.
 *
 * Identity signal:
 *   The auth sidecar sets X-Forwarded-Email ONLY for human browser sessions.
 *   SPN/M2M tokens only populate X-Forwarded-User (their SCIM ID), never email.
 *   This is the reliable discriminator between a human and an SPN.
 */

import type { Request, Response, NextFunction } from 'express';
import type { AuthenticatedUser } from './ios-auth';

// Re-export the type for consumers that import from this module
export type { AuthenticatedUser };

/**
 * Browser auth middleware.
 *
 * Extracts user identity from Databricks Apps platform headers.
 * REQUIRES X-Forwarded-Email — rejects requests that only have X-Forwarded-User
 * (which indicates an SPN, not a human).
 *
 * Usage:
 *   app.get('/api/v1/projects', browserAuth(), handler);
 */
export function browserAuth() {
  return (req: Request, res: Response, next: NextFunction): void => {
    const email = req.headers['x-forwarded-email'] as string | undefined;
    const userId = req.headers['x-forwarded-user'] as string | undefined;

    if (!email) {
      // No email header means this is NOT a human browser session.
      // Either: (a) no identity at all, or (b) SPN-only (X-Forwarded-User
      // without email). Both are rejected — SPNs cannot use human endpoints.
      res.status(401).json({
        type: 'https://lakeloom/errors/unauthenticated',
        title: 'Unauthenticated',
        status: 401,
        detail: userId
          ? 'Service principal identity detected without Layer 2 auth. iOS must send X-Lakeloom-Session-Token.'
          : 'No user identity found. Please sign in via the Databricks App.',
      });
      return;
    }

    // Human browser session — email present, userId is the SCIM compound ID
    req.user = {
      userId: userId ?? email,
      workspaceId: (req.headers['x-databricks-workspace-id'] as string) ?? '',
      sessionId: '', // Browser requests don't have a paired_session_id
    };

    next();
  };
}

/**
 * Dual-auth middleware: accepts EITHER iOS Layer 2 OR human browser session.
 *
 * Detection logic (strict — no SPN fallthrough):
 *   1. X-Lakeloom-Session-Token present → iOS auth (full Layer 2 verification)
 *   2. X-Forwarded-Email present → human browser session (browserAuth)
 *   3. Neither → 401 Unauthorized
 *
 * An SPN with only X-Forwarded-User and no Layer 2 headers is REJECTED.
 * iOS MUST always send Layer 2 headers to resolve the human identity via
 * paired_sessions. This prevents SPN-attributed writes.
 */
export function dualAuth(opts: { lakebase: { query(text: string, params?: unknown[]): Promise<{ rows: Record<string, unknown>[] }> } }) {
  const { iosAuth } = require('./ios-auth') as typeof import('./ios-auth');
  const iosMiddleware = iosAuth({ lakebase: opts.lakebase });

  return (req: Request, res: Response, next: NextFunction): void => {
    // Path 1: iOS — Layer 2 headers present, full cryptographic verification
    if (req.headers['x-lakeloom-session-token']) {
      iosMiddleware(req, res, next);
      return;
    }

    // Path 2: Human browser — email header confirms human identity
    // Path 3 (implicit): No session token AND no email → browserAuth rejects
    // as SPN-only. This blocks bare M2M from accessing user-attributed endpoints.
    browserAuth()(req, res, next);
  };
}
