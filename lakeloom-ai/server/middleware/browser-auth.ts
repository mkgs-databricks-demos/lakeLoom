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
 * Detection logic:
 *   - If X-Lakeloom-Session-Token is present → iOS (use iosAuth instead)
 *   - If X-Forwarded-Email is present → browser (this middleware)
 *   - If neither → 401 Unauthorized
 */

import type { Request, Response, NextFunction } from 'express';
import type { AuthenticatedUser } from './ios-auth';

// Re-export the type for consumers that import from this module
export type { AuthenticatedUser };

/**
 * Browser auth middleware.
 *
 * Extracts user identity from Databricks Apps platform headers.
 * Attach to any route that should accept browser (on-behalf-of-user) requests.
 *
 * Usage:
 *   app.get('/api/v1/projects', browserAuth(), handler);
 */
export function browserAuth() {
  return (req: Request, res: Response, next: NextFunction): void => {
    const email = req.headers['x-forwarded-email'] as string | undefined;
    const userId = req.headers['x-forwarded-user'] as string | undefined;

    if (!email && !userId) {
      // No identity headers — the platform sidecar should have rejected this
      // request before it reached us, but guard anyway
      res.status(401).json({
        type: 'https://lakeloom/errors/unauthenticated',
        title: 'Unauthenticated',
        status: 401,
        detail: 'No user identity found. Please sign in via the Databricks App.',
      });
      return;
    }

    // Attach user context (same shape as iosAuth for handler compatibility)
    req.user = {
      userId: userId ?? email ?? 'unknown',
      workspaceId: (req.headers['x-databricks-workspace-id'] as string) ?? '',
      sessionId: '', // Browser requests don't have a paired_session_id
    };

    next();
  };
}

/**
 * Dual-auth middleware: accepts EITHER iOS Layer 2 OR browser on-behalf-of-user.
 *
 * Detects which auth method is present and delegates accordingly.
 * Use on endpoints that both iOS and browser clients call (e.g., project CRUD).
 */
export function dualAuth(opts: { lakebase: { query(text: string, params?: unknown[]): Promise<{ rows: Record<string, unknown>[] }> } }) {
  const { iosAuth } = require('./ios-auth') as typeof import('./ios-auth');
  const iosMiddleware = iosAuth({ lakebase: opts.lakebase });

  return (req: Request, res: Response, next: NextFunction): void => {
    // If iOS-specific headers are present, use iOS auth
    if (req.headers['x-lakeloom-session-token']) {
      iosMiddleware(req, res, next);
      return;
    }

    // Otherwise, use browser auth
    browserAuth()(req, res, next);
  };
}
