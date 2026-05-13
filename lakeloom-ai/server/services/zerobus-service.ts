/**
 * ZeroBus event forwarding service.
 *
 * Manages a pool of ZeroBus SDK streams for high-throughput event ingestion.
 * iOS sends transcript events to POST /api/sessions/:session_id/events
 * (Layer 1 authenticated). The App enriches with user_id, session_id,
 * timestamps and forwards via ZeroBus SDK to the bronze table
 * (transcript_events_raw).
 *
 * Stream pool pattern:
 *   - Lazy init on first request (avoids slow cold-start)
 *   - Round-robin stream selection
 *   - Graceful shutdown: drain in-flight → close all streams
 *
 * Pool size is configured via the secret scope (default: 16).
 */

import { ZerobusSdk } from '@databricks/zerobus-ingest-sdk';
import { getZerobusSPNCredentials, getZerobusConfig } from './secrets-service';

// ── Types ────────────────────────────────────────────────────────────────────

interface ZerobusStream {
  ingestRecordOffset(record: string): Promise<bigint>;
  waitForOffset(offset: bigint): Promise<void>;
  close(): Promise<void>;
}

// ── State ────────────────────────────────────────────────────────────────────

let sdk: InstanceType<typeof ZerobusSdk> | null = null;
let streams: ZerobusStream[] = [];
let roundRobinIndex = 0;
let initializing = false;
let initPromise: Promise<void> | null = null;

// ── Initialization ───────────────────────────────────────────────────────────

async function initPool(): Promise<void> {
  const config = getZerobusConfig();
  const creds = getZerobusSPNCredentials();

  if (!config || !creds) {
    throw new Error(
      '[zerobus] Cannot initialize: missing endpoint, table, or SPN credentials.',
    );
  }

  console.log(
    `[zerobus] Initializing stream pool: ${config.poolSize} streams → ${config.tableName}`,
  );

  // SDK expects the workspace URL for UC token exchange
  const workspaceUrl = process.env.DATABRICKS_HOST ?? '';
  sdk = new ZerobusSdk(config.endpoint, workspaceUrl);

  const streamOptions = {
    maxInflightRequests: 10000,
    recovery: true,
    recoveryTimeoutMs: 15000,
    recoveryRetries: 4,
    flushTimeoutMs: 300000,
    recordType: 0, // JSON
  };

  streams = [];
  for (let i = 0; i < config.poolSize; i++) {
    const stream = await (sdk as any).createStream(
      { tableName: config.tableName },
      creds.clientId,
      creds.clientSecret,
      streamOptions,
    );
    streams.push(stream);
  }

  console.log(`[zerobus] Pool ready: ${streams.length} streams.`);
}

/**
 * Ensure the stream pool is initialized (lazy, thread-safe via single promise).
 */
async function ensurePool(): Promise<void> {
  if (streams.length > 0) return;
  if (initPromise) return initPromise;

  initializing = true;
  initPromise = initPool().finally(() => {
    initializing = false;
  });
  return initPromise;
}

// ── Public API ───────────────────────────────────────────────────────────────

/**
 * Ingest a JSON record into the bronze table via ZeroBus.
 * Lazily initializes the stream pool on first call.
 *
 * @param record - JSON string to ingest
 * @param waitForAck - If true, waits for server acknowledgment before returning
 * @returns The offset (for optional downstream tracking)
 */
export async function ingestRecord(record: string, waitForAck = false): Promise<bigint> {
  await ensurePool();

  if (streams.length === 0) {
    throw new Error('[zerobus] Stream pool is empty after initialization.');
  }

  // Round-robin stream selection
  const stream = streams[roundRobinIndex];
  roundRobinIndex = (roundRobinIndex + 1) % streams.length;

  const offset = await stream.ingestRecordOffset(record);

  if (waitForAck) {
    await stream.waitForOffset(offset);
  }

  return offset;
}

/**
 * Whether the ZeroBus service is ready to accept events.
 */
export function isReady(): boolean {
  return streams.length > 0;
}

/**
 * Graceful shutdown — flush and close all streams.
 * Call during SIGTERM handling.
 */
export async function shutdown(): Promise<void> {
  if (streams.length === 0) return;

  console.log(`[zerobus] Shutting down ${streams.length} streams...`);
  const closePromises = streams.map((s) => s.close().catch((err) => {
    console.warn('[zerobus] Error closing stream:', err);
  }));
  await Promise.all(closePromises);
  streams = [];
  sdk = null;
  console.log('[zerobus] All streams closed.');
}
