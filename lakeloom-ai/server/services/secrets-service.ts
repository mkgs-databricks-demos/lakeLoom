/**
 * Secrets service — reads secret values from environment variables.
 *
 * The platform injects actual secret values at container start via
 * app.yaml valueFrom bindings → Databricks Apps secret resources.
 * No SDK calls or secret scope reads needed at runtime.
 *
 * Env vars (set by platform from secret resources):
 *   LAKELOOM_ZEROBUS_CLIENT_ID       — ZeroBus SPN client_id
 *   LAKELOOM_ZEROBUS_CLIENT_SECRET   — ZeroBus SPN client_secret
 *   LAKELOOM_XCODE_CLIENT_ID         — Xcode SPN client_id
 *   LAKELOOM_XCODE_CLIENT_SECRET     — Xcode SPN client_secret
 *   LAKELOOM_WORKSPACE_URL           — Workspace URL
 *   LAKELOOM_ZEROBUS_ENDPOINT        — ZeroBus endpoint
 *   LAKELOOM_TARGET_TABLE_NAME       — Bronze table name
 *   LAKELOOM_ZEROBUS_STREAM_POOL_SIZE — Stream pool size (default: 16)
 *   LAKELOOM_SECRET_SCOPE            — Scope name (diagnostics only)
 */

// ── Secret values (read once from env) ───────────────────────────────────────

export interface SecretsState {
  // ZeroBus SPN (server-side streaming + volume writes)
  zerobusClientId: string | null;
  zerobusClientSecret: string | null;

  // Xcode SPN (included in QR payload for iOS auth sidecar)
  xcodeClientId: string | null;
  xcodeClientSecret: string | null;

  // Infra metadata (auto-provisioned by platform bootstrap)
  workspaceUrl: string | null;
  zerobusEndpoint: string | null;
  targetTableName: string | null;
  zerobusStreamPoolSize: number;
}

function readEnv(): SecretsState {
  const env = process.env;
  const poolStr = env.LAKELOOM_ZEROBUS_STREAM_POOL_SIZE;
  return {
    zerobusClientId: env.LAKELOOM_ZEROBUS_CLIENT_ID || null,
    zerobusClientSecret: env.LAKELOOM_ZEROBUS_CLIENT_SECRET || null,
    xcodeClientId: env.LAKELOOM_XCODE_CLIENT_ID || null,
    xcodeClientSecret: env.LAKELOOM_XCODE_CLIENT_SECRET || null,
    workspaceUrl: env.LAKELOOM_WORKSPACE_URL || null,
    zerobusEndpoint: env.LAKELOOM_ZEROBUS_ENDPOINT || null,
    targetTableName: env.LAKELOOM_TARGET_TABLE_NAME || null,
    zerobusStreamPoolSize: poolStr ? (parseInt(poolStr, 10) || 16) : 16,
  };
}

const state: SecretsState = readEnv();

// ── Initialization (synchronous — no async needed) ───────────────────────────

/**
 * Initialize the secrets service. Now synchronous (env vars are already present).
 * Kept as async for backward-compatible call signature in server.ts.
 */
export async function initSecrets(): Promise<void> {
  const missing = getMissingKeys();
  if (missing.length > 0) {
    console.warn(`[secrets] Missing env vars (pairing will be gated): ${missing.join(', ')}`);
  } else {
    console.log('[secrets] All secret env vars present.');
  }
}

// ── Readiness checks ─────────────────────────────────────────────────────────

/**
 * Returns the list of critical keys that are missing.
 * When non-empty, pairing endpoints should return 503.
 */
export function getMissingKeys(): string[] {
  const missing: string[] = [];
  if (!state.xcodeClientId) missing.push('LAKELOOM_XCODE_CLIENT_ID');
  if (!state.xcodeClientSecret) missing.push('LAKELOOM_XCODE_CLIENT_SECRET');
  if (!state.zerobusClientId) missing.push('LAKELOOM_ZEROBUS_CLIENT_ID');
  if (!state.zerobusClientSecret) missing.push('LAKELOOM_ZEROBUS_CLIENT_SECRET');
  if (!state.workspaceUrl) missing.push('LAKELOOM_WORKSPACE_URL');
  return missing;
}

/** Whether the pairing system has all required secrets. */
export function isPairingReady(): boolean {
  return getMissingKeys().length === 0;
}

/** Whether ZeroBus streaming is ready (has SPN creds + endpoint + table). */
export function isZerobusReady(): boolean {
  return !!(
    state.zerobusClientId &&
    state.zerobusClientSecret &&
    state.zerobusEndpoint &&
    state.targetTableName
  );
}

// ── Typed getters ────────────────────────────────────────────────────────────

export function getSecrets(): Readonly<SecretsState> {
  return state;
}

export function getXcodeSPNCredentials(): { clientId: string; clientSecret: string } | null {
  if (!state.xcodeClientId || !state.xcodeClientSecret) return null;
  return { clientId: state.xcodeClientId, clientSecret: state.xcodeClientSecret };
}

export function getZerobusSPNCredentials(): { clientId: string; clientSecret: string } | null {
  if (!state.zerobusClientId || !state.zerobusClientSecret) return null;
  return { clientId: state.zerobusClientId, clientSecret: state.zerobusClientSecret };
}

export function getZerobusConfig(): {
  endpoint: string;
  tableName: string;
  poolSize: number;
} | null {
  if (!state.zerobusEndpoint || !state.targetTableName) return null;
  return {
    endpoint: state.zerobusEndpoint,
    tableName: state.targetTableName,
    poolSize: state.zerobusStreamPoolSize,
  };
}
