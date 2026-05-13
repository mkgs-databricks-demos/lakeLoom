/**
 * Secrets service — reads Databricks Secrets at startup.
 *
 * Loads SPN credentials and infra metadata from the `lakeloom_credentials`
 * secret scope. Exposes typed getters and a readiness check for gating
 * pairing endpoints (503 if critical secrets are missing).
 *
 * Key names are schema-qualified per target and passed via environment
 * variables (from app.yaml valueFrom bindings or bundle variables).
 *
 * Uses the Databricks SDK WorkspaceClient (auto-authenticated in Apps).
 */

import { WorkspaceClient } from '@databricks/sdk-experimental';

// ── Configuration from environment ───────────────────────────────────────────

interface SecretsConfig {
  scopeName: string;
  clientIdKey: string;
  clientSecretKey: string;
  xcodeClientIdKey: string;
  xcodeClientSecretKey: string;
}

function loadConfig(): SecretsConfig {
  const env = process.env;
  return {
    scopeName: env.LAKELOOM_SECRET_SCOPE ?? 'lakeloom_credentials',
    clientIdKey: env.LAKELOOM_CLIENT_ID_KEY ?? 'client_id',
    clientSecretKey: env.LAKELOOM_CLIENT_SECRET_KEY ?? 'client_secret',
    xcodeClientIdKey: env.LAKELOOM_XCODE_CLIENT_ID_KEY ?? 'xcode_client_id',
    xcodeClientSecretKey: env.LAKELOOM_XCODE_CLIENT_SECRET_KEY ?? 'xcode_client_secret',
  };
}

// ── Secret values (populated at init) ────────────────────────────────────────

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

let state: SecretsState = {
  zerobusClientId: null,
  zerobusClientSecret: null,
  xcodeClientId: null,
  xcodeClientSecret: null,
  workspaceUrl: null,
  zerobusEndpoint: null,
  targetTableName: null,
  zerobusStreamPoolSize: 16,
};

let initialized = false;

// ── Initialization ───────────────────────────────────────────────────────────

/**
 * Initialize the secrets service by reading all required keys from the scope.
 * Non-fatal: missing secrets are logged as warnings; readiness checks gate endpoints.
 */
export async function initSecrets(): Promise<void> {
  if (initialized) return;

  const config = loadConfig();
  const wc = new WorkspaceClient({ host: process.env.DATABRICKS_HOST });

  console.log(`[secrets] Reading from scope: ${config.scopeName}`);

  const read = async (key: string): Promise<string | null> => {
    try {
      const resp = await (wc.secrets as any).getSecret(config.scopeName, key);
      // SDK returns base64-encoded value
      if (resp?.value) {
        return Buffer.from(resp.value, 'base64').toString('utf-8');
      }
      return null;
    } catch (err) {
      console.warn(`[secrets] Key "${key}" not found or inaccessible:`, (err as Error).message);
      return null;
    }
  };

  // Read all keys in parallel
  const [
    zerobusClientId,
    zerobusClientSecret,
    xcodeClientId,
    xcodeClientSecret,
    workspaceUrl,
    zerobusEndpoint,
    targetTableName,
    poolSizeStr,
  ] = await Promise.all([
    read(config.clientIdKey),
    read(config.clientSecretKey),
    read(config.xcodeClientIdKey),
    read(config.xcodeClientSecretKey),
    read('workspace_url'),
    read('zerobus_endpoint'),
    read('target_table_name'),
    read('zerobus_stream_pool_size'),
  ]);

  state = {
    zerobusClientId,
    zerobusClientSecret,
    xcodeClientId,
    xcodeClientSecret,
    workspaceUrl,
    zerobusEndpoint,
    targetTableName,
    zerobusStreamPoolSize: poolSizeStr ? (parseInt(poolSizeStr, 10) || 16) : 16,
  };

  initialized = true;

  const missing = getMissingKeys();
  if (missing.length > 0) {
    console.warn(`[secrets] Missing keys (pairing will be gated): ${missing.join(', ')}`);
  } else {
    console.log('[secrets] All keys loaded successfully.');
  }
}

// ── Readiness checks ─────────────────────────────────────────────────────────

/**
 * Returns the list of critical keys that are missing.
 * When non-empty, pairing endpoints should return 503.
 */
export function getMissingKeys(): string[] {
  const missing: string[] = [];
  if (!state.xcodeClientId) missing.push('xcode_spn_client_id');
  if (!state.xcodeClientSecret) missing.push('xcode_spn_client_secret');
  if (!state.zerobusClientId) missing.push('zerobus_spn_client_id');
  if (!state.zerobusClientSecret) missing.push('zerobus_spn_client_secret');
  if (!state.workspaceUrl) missing.push('workspace_url');
  return missing;
}

/**
 * Whether the pairing system has all required secrets.
 */
export function isPairingReady(): boolean {
  return getMissingKeys().length === 0;
}

/**
 * Whether ZeroBus streaming is ready (has SPN creds + endpoint + table).
 */
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
