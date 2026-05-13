/**
 * Error model for lakeLoom API — RFC 9457 Problem Details.
 *
 * All auth and application errors use this format so both the iOS client
 * and browser admin pages can parse structured error responses consistently.
 *
 * @see https://datatracker.ietf.org/doc/html/rfc9457
 */

import type { Request, Response, NextFunction } from 'express';

// ── Error type URIs ──────────────────────────────────────────────────────────
// Stable identifiers for each error class. iOS maps these to typed AppError cases.
const ERROR_BASE = 'https://lakeloom/errors';

export const ErrorTypes = {
  TOKEN_EXPIRED: `${ERROR_BASE}/token_expired`,
  TOKEN_NOT_FOUND: `${ERROR_BASE}/token_not_found`,
  INVALID_SIGNATURE: `${ERROR_BASE}/invalid_signature`,
  TIMESTAMP_SKEW: `${ERROR_BASE}/timestamp_skew`,
  XCODE_SPN_NOT_PROVISIONED: `${ERROR_BASE}/xcode_spn_not_provisioned`,
  APP_SPN_NOT_PROVISIONED: `${ERROR_BASE}/app_spn_not_provisioned`,
  PAIRING_ALREADY_CONFIRMED: `${ERROR_BASE}/pairing_already_confirmed`,
  DEVICE_NOT_FOUND: `${ERROR_BASE}/device_not_found`,
  VALIDATION_ERROR: `${ERROR_BASE}/validation_error`,
  INTERNAL_ERROR: `${ERROR_BASE}/internal_error`,
} as const;

export type ErrorType = (typeof ErrorTypes)[keyof typeof ErrorTypes];

// ── Problem Details shape ────────────────────────────────────────────────────

export interface ProblemDetails {
  type: string;
  title: string;
  status: number;
  detail: string;
  [key: string]: unknown;
}

// ── AppError class ───────────────────────────────────────────────────────────

export class AppError extends Error {
  public readonly type: ErrorType;
  public readonly status: number;
  public readonly title: string;
  public readonly detail: string;
  public readonly extra: Record<string, unknown>;

  constructor(opts: {
    type: ErrorType;
    status: number;
    title: string;
    detail: string;
    extra?: Record<string, unknown>;
  }) {
    super(opts.detail);
    this.name = 'AppError';
    this.type = opts.type;
    this.status = opts.status;
    this.title = opts.title;
    this.detail = opts.detail;
    this.extra = opts.extra ?? {};
  }

  toProblemDetails(): ProblemDetails {
    return {
      type: this.type,
      title: this.title,
      status: this.status,
      detail: this.detail,
      ...this.extra,
    };
  }
}

// ── Pre-built error factories ────────────────────────────────────────────────

export function tokenExpired(): AppError {
  return new AppError({
    type: ErrorTypes.TOKEN_EXPIRED,
    status: 401,
    title: 'Session expired',
    detail: 'Re-pair to continue. Open the lakeLoom Databricks App and scan a fresh QR.',
  });
}

export function tokenNotFound(): AppError {
  return new AppError({
    type: ErrorTypes.TOKEN_NOT_FOUND,
    status: 401,
    title: 'Session not found',
    detail: 'The session token is invalid or has been revoked. Please re-pair.',
  });
}

export function invalidSignature(): AppError {
  return new AppError({
    type: ErrorTypes.INVALID_SIGNATURE,
    status: 401,
    title: 'Invalid signature',
    detail: 'The request signature could not be verified against the bound device key.',
  });
}

export function timestampSkew(): AppError {
  return new AppError({
    type: ErrorTypes.TIMESTAMP_SKEW,
    status: 401,
    title: 'Timestamp out of range',
    detail:
      'The request timestamp is too far from the server clock. Ensure your device clock is accurate.',
  });
}

export function xcodeSPNNotProvisioned(missing: string[]): AppError {
  return new AppError({
    type: ErrorTypes.XCODE_SPN_NOT_PROVISIONED,
    status: 503,
    title: 'lakeLoom is not yet ready for pairing',
    detail:
      'A workspace admin must complete deploy steps 1–4 before iPhones can pair. See the lakeLoom deploy guide.',
    extra: { missing },
  });
}

export function appSPNNotProvisioned(missing: string[]): AppError {
  return new AppError({
    type: ErrorTypes.APP_SPN_NOT_PROVISIONED,
    status: 503,
    title: 'lakeLoom is not yet ready for pairing',
    detail:
      'The App-side SPN credentials are not fully provisioned. A workspace admin must generate the OAuth secret.',
    extra: { missing },
  });
}

export function pairingAlreadyConfirmed(): AppError {
  return new AppError({
    type: ErrorTypes.PAIRING_ALREADY_CONFIRMED,
    status: 409,
    title: 'Pairing already confirmed',
    detail: 'This pairing session has already been bound to a device. Scan a new QR to re-pair.',
  });
}

export function deviceNotFound(): AppError {
  return new AppError({
    type: ErrorTypes.DEVICE_NOT_FOUND,
    status: 404,
    title: 'Device not found',
    detail: 'The specified device could not be found or does not belong to the current user.',
  });
}

export function validationError(detail: string): AppError {
  return new AppError({
    type: ErrorTypes.VALIDATION_ERROR,
    status: 400,
    title: 'Validation error',
    detail,
  });
}

// ── Express error-handling middleware ─────────────────────────────────────────
// Mount LAST in the middleware chain: app.use(problemDetailsHandler)

export function problemDetailsHandler(
  err: unknown,
  _req: Request,
  res: Response,
  _next: NextFunction,
): void {
  if (err instanceof AppError) {
    res.status(err.status).type('application/problem+json').json(err.toProblemDetails());
    return;
  }

  // Unexpected errors — log and return generic 500
  console.error('[error] Unhandled error:', err);
  const fallback: ProblemDetails = {
    type: ErrorTypes.INTERNAL_ERROR,
    title: 'Internal server error',
    status: 500,
    detail: 'An unexpected error occurred. Please try again later.',
  };
  res.status(500).type('application/problem+json').json(fallback);
}
