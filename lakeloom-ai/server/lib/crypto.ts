/**
 * Cryptographic utilities for lakeLoom auth.
 *
 * All functions use Node.js built-in `crypto` — no external dependencies.
 * Covers: SHA-256 hashing, ECDSA P-256 signature verification,
 * session token generation, and canonical request message construction.
 */

import { createHash, randomBytes, verify, createPublicKey } from 'node:crypto';

// ── SHA-256 ──────────────────────────────────────────────────────────────────

/**
 * Compute SHA-256 hash of the input.
 * Accepts string (UTF-8) or Buffer.
 */
export function sha256(input: string | Buffer): Buffer {
  return createHash('sha256').update(input).digest();
}

/**
 * Compute SHA-256 hash and return as lowercase hex string.
 */
export function sha256Hex(input: string | Buffer): string {
  return createHash('sha256').update(input).digest('hex');
}

// ── ECDSA P-256 signature verification ───────────────────────────────────────

/**
 * Verify an ECDSA P-256 (SHA-256) signature.
 *
 * @param publicKeyDer - DER-encoded SubjectPublicKeyInfo (from device_pubkey column)
 * @param message      - The canonical message bytes that were signed
 * @param signatureDer - DER-encoded ECDSA signature (from X-Lakeloom-Signature, base64url-decoded)
 * @returns true if the signature is valid
 */
export function verifyEcdsaP256(
  publicKeyDer: Buffer,
  message: Buffer,
  signatureDer: Buffer,
): boolean {
  try {
    const key = createPublicKey({
      key: publicKeyDer,
      format: 'der',
      type: 'spki',
    });
    return verify('SHA256', message, key, signatureDer);
  } catch {
    // Malformed key or signature → treat as verification failure
    return false;
  }
}

// ── Session token generation ─────────────────────────────────────────────────

/**
 * Generate a cryptographically secure session token.
 *
 * @returns { token, hash } where:
 *   - token: 32 random bytes, base64url-encoded (delivered to iOS via QR)
 *   - hash:  SHA-256 of the raw token bytes (stored in DB as token_hash)
 *
 * We store the hash, never the raw token — even a DB compromise doesn't
 * expose usable session tokens.
 */
export function generateSessionToken(): { token: string; hash: Buffer } {
  const raw = randomBytes(32);
  const token = raw.toString('base64url');
  const hash = sha256(raw);
  return { token, hash };
}

// ── Canonical request message ────────────────────────────────────────────────

/**
 * Build the canonical message for request signing verification.
 *
 * Format (newline-joined):
 *   <HTTP method, uppercase>
 *   <URL path including query string>
 *   <X-Lakeloom-Timestamp value>
 *   <lowercase hex SHA-256 of request body, or empty string if no body>
 *
 * @param method    - HTTP method (GET, POST, etc.)
 * @param path      - URL path including query string (e.g., /api/projects?include=defaults)
 * @param timestamp - Unix seconds string from X-Lakeloom-Timestamp header
 * @param bodyHash  - Lowercase hex SHA-256 of the request body, or "" for no body
 */
export function buildCanonicalMessage(
  method: string,
  path: string,
  timestamp: string,
  bodyHash: string,
): Buffer {
  const canonical = `${method.toUpperCase()}\n${path}\n${timestamp}\n${bodyHash}`;
  return Buffer.from(canonical, 'utf-8');
}
