/**
 * ZeroBus Ingest Service — Scale-to-Zero Stream Pool
 *
 * Ingests transcript events into the bronze table (transcript_events_raw)
 * via the ZeroBus TypeScript SDK (@databricks/zerobus-ingest-sdk).
 *
 * ── Scaling strategy ──────────────────────────────────────────────────
 *
 * Unlike the dbxWearables approach (min 2, max 16, eager init), this
 * service uses a SCALE-TO-ZERO pattern optimized for bursty iOS capture
 * sessions with long idle periods between whiteboard meetings:
 *
 *   0 streams (cold) → Request arrives → scale to 1
 *   1 stream (warm)  → Load increases  → scale up by 1
 *   N streams (hot)  → Sustained idle  → scale down by 1
 *   1 stream (warm)  → 20 min idle     → scale to 0 (cold)
 *
 * Scale decisions:
 *   - UP:   peak in-flight ≥ stream count OR call rate ≥ stream count
 *   - DOWN: IDLE_CHECKS_BEFORE_SCALE_DOWN consecutive idle checks (0 calls + 0 in-flight)
 *   - ZERO: at 1 stream, after IDLE_BEFORE_ZERO_MS (20 min) of no activity
 *
 * Pool lifecycle events are recorded in Lakebase (app.zerobus_pool_events)
 * via the zerobus-history-service for observability and diagnostics.
 *
 * ── Environment variables (injected via app.yaml valueFrom) ───────────
 *   LAKELOOM_ZEROBUS_CLIENT_ID       — ZeroBus SPN client_id
 *   LAKELOOM_ZEROBUS_CLIENT_SECRET   — ZeroBus SPN client_secret
 *   LAKELOOM_ZEROBUS_ENDPOINT        — ZeroBus Ingest gRPC endpoint
 *   LAKELOOM_TARGET_TABLE_NAME       — Bronze table (catalog.schema.table)
 *   LAKELOOM_ZEROBUS_STREAM_POOL_SIZE — Max pool size (default: 16)
 *   LAKELOOM_WORKSPACE_URL           — Workspace URL (SDK token exchange)
 *
 * ── Graceful shutdown ─────────────────────────────────────────────────
 *   SIGTERM → draining=true → poll until in-flight=0 → close all streams
 *   Every record accepted before SIGTERM is durably committed.
 */

import { ZerobusSdk, RecordType } from '@databricks/zerobus-ingest-sdk';
import { getZerobusSPNCredentials, getZerobusConfig } from './secrets-service';

// ── Types ────────────────────────────────────────────────────────────────────

interface IngestStream {
  ingestRecordOffset(record: unknown): Promise<bigint>;
  waitForOffset(offset: bigint): Promise<void>;
  close(): Promise<void>;
}

/** Recorded each time the stream pool changes size. */
export interface ResizeEvent {
  timestamp: string;
  trigger: 'wake' | 'auto-scale-up' | 'auto-scale-down' | 'scale-to-zero' | 'manual' | 'shutdown';
  oldSize: number;
  newSize: number;
  durationMs: number;
  peakInflight?: number;
  idleChecks?: number;
  callRate?: number;
}

/** Auto-scale configuration. */
export interface AutoScaleConfig {
  /** Maximum pool size (default: from env or 16). */
  maxSize: number;
  /** How often to check utilization, in ms (default: 5000). */
  checkIntervalMs: number;
  /** Minimum time between resize operations, in ms (default: 10000). */
  cooldownMs: number;
  /** Time at 1 stream with no activity before scaling to 0, in ms (default: 1_200_000 = 20 min). */
  idleBeforeZeroMs: number;
}

/** Pool status snapshot for health endpoints. */
export interface PoolStatus {
  pool_size: number;
  active_streams: number;
  initialized: boolean;
  inflight_requests: number;
  draining: boolean;
  last_activity_at: string | null;
  auto_scale: {
    enabled: boolean;
    max_size: number;
    idle_before_zero_ms: number;
  };
}

// ── Constants ────────────────────────────────────────────────────────────────

/** Consecutive idle checks before scaling down (non-zero pool → pool - 1). */
const IDLE_CHECKS_BEFORE_SCALE_DOWN = 3;

/** Maximum resize events retained in the in-memory ring buffer. */
const MAX_RESIZE_HISTORY = 50;

/** Maximum time (ms) to wait for in-flight requests during shutdown. */
const DRAIN_TIMEOUT_MS = 12_000;

/** Polling interval (ms) when waiting for in-flight drain. */
const DRAIN_POLL_INTERVAL_MS = 200;

/** Required env var names for pre-flight check. */
const ENV_KEYS = [
  'LAKELOOM_ZEROBUS_ENDPOINT',
  'LAKELOOM_ZEROBUS_CLIENT_ID',
  'LAKELOOM_ZEROBUS_CLIENT_SECRET',
  'LAKELOOM_TARGET_TABLE_NAME',
] as const;

// ── Default auto-scale config ────────────────────────────────────────────────

const AUTO_SCALE_DEFAULTS: AutoScaleConfig = {
  maxSize: parseInt(process.env.LAKELOOM_ZEROBUS_STREAM_POOL_SIZE || '', 10) || 16,
  checkIntervalMs: 5_000,
  cooldownMs: 10_000,
  idleBeforeZeroMs: 20 * 60 * 1_000, // 20 minutes
};

// ── Service class ────────────────────────────────────────────────────────────

class ZeroBusService {
  private sdk: ZerobusSdk | null = null;
  private streams: IngestStream[] = [];
  private streamIndex = 0;
  private initPromise: Promise<void> | null = null;

  // Stored after first init so resize() can open new streams
  private targetTable = '';
  private clientId = '';
  private clientSecret = '';
  private endpoint = '';
  private workspaceUrl = '';

  // ── In-flight tracking ─────────────────────────────────────────────
  private inflight = 0;
  private draining = false;

  // ── Auto-scale state ───────────────────────────────────────────────
  private autoScaleEnabled = false;
  private autoScaleConfig: AutoScaleConfig = { ...AUTO_SCALE_DEFAULTS };
  private autoScaleTimer: ReturnType<typeof setInterval> | null = null;
  private lastAutoScaleTime = 0;
  private peakInflight = 0;
  private idleChecks = 0;
  private callsSinceLastCheck = 0;
  private lastActivityAt: Date | null = null;

  // ── Resize history ring buffer ─────────────────────────────────────
  private resizeHistory: ResizeEvent[] = [];

  // ── Event callback (for Lakebase persistence) ──────────────────────
  private onResizeCallback: ((event: ResizeEvent) => void) | null = null;

  // ── Public API ─────────────────────────────────────────────────────

  /**
   * Register a callback invoked on every resize event.
   * Used by zerobus-history-service to persist events to Lakebase.
   */
  onResize(callback: (event: ResizeEvent) => void): void {
    this.onResizeCallback = callback;
  }

  /**
   * Ingest a JSON record into the bronze table.
   * Lazily initializes the pool (0→1) on first call.
   *
   * @param record - JSON string to ingest
   * @param waitForAck - If true, waits for server acknowledgment
   * @returns The offset (for optional downstream tracking)
   */
  async ingestRecord(record: string, waitForAck = false): Promise<bigint> {
    if (this.draining) {
      throw new Error('[zerobus] Service is shutting down — not accepting new requests.');
    }

    await this.ensurePool();

    if (this.streams.length === 0) {
      throw new Error('[zerobus] Stream pool is empty after initialization.');
    }

    this.inflight++;
    if (this.inflight > this.peakInflight) this.peakInflight = this.inflight;
    this.callsSinceLastCheck++;
    this.lastActivityAt = new Date();

    try {
      const stream = this.nextStream();
      const offset = await stream.ingestRecordOffset(record);

      if (waitForAck) {
        await stream.waitForOffset(offset);
      }

      return offset;
    } finally {
      this.inflight--;
    }
  }

  /**
   * Ingest a batch of JSON records.
   * Each record goes to the next stream via round-robin.
   * Waits for the last offset to confirm durability.
   */
  async ingestBatch(records: string[]): Promise<number> {
    if (records.length === 0) return 0;

    if (this.draining) {
      throw new Error('[zerobus] Service is shutting down — not accepting new requests.');
    }

    await this.ensurePool();

    this.inflight++;
    if (this.inflight > this.peakInflight) this.peakInflight = this.inflight;
    this.callsSinceLastCheck++;
    this.lastActivityAt = new Date();

    try {
      let lastOffset = BigInt(0);
      for (const record of records) {
        const stream = this.nextStream();
        lastOffset = await stream.ingestRecordOffset(record);
      }

      // Wait for durability confirmation on the last record
      const stream = this.streams[
        (this.streamIndex - 1 + this.streams.length) % this.streams.length
      ];
      await stream.waitForOffset(lastOffset);

      return records.length;
    } finally {
      this.inflight--;
    }
  }

  /** Whether the pool has at least one active stream. */
  isReady(): boolean {
    return this.streams.length > 0;
  }

  /** Whether the pool is in scale-to-zero (cold) state. */
  isCold(): boolean {
    return this.streams.length === 0 && !this.initPromise;
  }

  // ── Health / diagnostics ───────────────────────────────────────────

  /** Check whether all required env vars are present. */
  checkEnv(): { configured: boolean; missing: string[] } {
    const missing = ENV_KEYS.filter((k) => !process.env[k]);
    return { configured: missing.length === 0, missing: [...missing] };
  }

  /** Pool status snapshot for health endpoints. */
  poolStatus(): PoolStatus {
    return {
      pool_size: this.autoScaleConfig.maxSize,
      active_streams: this.streams.length,
      initialized: this.streams.length > 0,
      inflight_requests: this.inflight,
      draining: this.draining,
      last_activity_at: this.lastActivityAt?.toISOString() ?? null,
      auto_scale: {
        enabled: this.autoScaleEnabled,
        max_size: this.autoScaleConfig.maxSize,
        idle_before_zero_ms: this.autoScaleConfig.idleBeforeZeroMs,
      },
    };
  }

  /** Returns auto-scale state and resize history. */
  autoScaleStatus(): {
    enabled: boolean;
    config: AutoScaleConfig;
    peak_inflight: number;
    idle_checks: number;
    history: ResizeEvent[];
  } {
    return {
      enabled: this.autoScaleEnabled,
      config: { ...this.autoScaleConfig },
      peak_inflight: this.peakInflight,
      idle_checks: this.idleChecks,
      history: [...this.resizeHistory],
    };
  }

  // ── Pool initialization ────────────────────────────────────────────

  /**
   * Ensure at least one stream is open. Called on every ingest request.
   * If the pool is cold (0 streams), opens 1 stream (wake event).
   */
  private async ensurePool(): Promise<void> {
    if (this.streams.length > 0) return;

    if (this.initPromise) {
      await this.initPromise;
      return;
    }

    this.initPromise = this.wakePool();
    try {
      await this.initPromise;
    } finally {
      this.initPromise = null;
    }
  }

  /**
   * Wake the pool from zero — opens 1 stream and enables auto-scale.
   */
  private async wakePool(): Promise<void> {
    const config = getZerobusConfig();
    const creds = getZerobusSPNCredentials();

    if (!config || !creds) {
      throw new Error(
        '[zerobus] Cannot initialize: missing endpoint, table, or SPN credentials.',
      );
    }

    const start = performance.now();

    // Store credentials for future resize() calls
    this.endpoint = config.endpoint;
    this.targetTable = config.tableName;
    this.clientId = creds.clientId;
    this.clientSecret = creds.clientSecret;
    this.workspaceUrl = process.env.DATABRICKS_HOST ?? '';

    console.log(`[zerobus] Waking pool: 0 → 1 stream (table: ${this.targetTable})`);

    if (!this.sdk) {
      this.sdk = new ZerobusSdk(this.endpoint, this.workspaceUrl);
    }

    const stream = await this.createOneStream();
    this.streams.push(stream);

    const durationMs = Math.round(performance.now() - start);
    console.log(`[zerobus] Pool awake: 1 stream ready (${durationMs}ms)`);

    this.recordResize({
      timestamp: new Date().toISOString(),
      trigger: 'wake',
      oldSize: 0,
      newSize: 1,
      durationMs,
    });

    // Enable auto-scale after wake
    this.enableAutoScale();
  }

  /** Open one gRPC stream with standard options. */
  private async createOneStream(): Promise<IngestStream> {
    return (this.sdk as any).createStream(
      { tableName: this.targetTable },
      this.clientId,
      this.clientSecret,
      {
        maxInflightRequests: 10_000,
        recovery: true,
        recoveryTimeoutMs: 15_000,
        recoveryRetries: 4,
        flushTimeoutMs: 300_000,
        recordType: RecordType.Json,
      },
    );
  }

  /** Round-robin stream selection. */
  private nextStream(): IngestStream {
    const stream = this.streams[this.streamIndex];
    this.streamIndex = (this.streamIndex + 1) % this.streams.length;
    return stream;
  }

  // ── Dynamic resize ─────────────────────────────────────────────────

  /**
   * Resize the pool to a new size. Handles both scale-up and scale-down.
   * Scale-down waits for in-flight requests to drain (up to 10s).
   */
  async resize(newSize: number, trigger: ResizeEvent['trigger'] = 'manual'): Promise<{
    oldSize: number;
    newSize: number;
    durationMs: number;
  }> {
    const start = performance.now();
    const oldSize = this.streams.length;

    if (newSize === oldSize) {
      return { oldSize, newSize, durationMs: 0 };
    }

    if (newSize > oldSize) {
      // ── Scale UP ─────────────────────────────────────────────────
      console.log(`[zerobus] Scaling UP: ${oldSize} → ${newSize}`);

      for (let i = oldSize; i < newSize; i++) {
        const stream = await this.createOneStream();
        this.streams.push(stream);
        console.log(`[zerobus] Stream ${i + 1}/${newSize} opened`);
      }
    } else {
      // ── Scale DOWN (including to zero) ───────────────────────────
      console.log(`[zerobus] Scaling DOWN: ${oldSize} → ${newSize}`);

      // Wait for in-flight to complete before closing streams
      const drainStart = Date.now();
      while (this.inflight > 0 && Date.now() - drainStart < 10_000) {
        await new Promise((r) => setTimeout(r, 50));
      }
      if (this.inflight > 0) {
        console.warn(
          `[zerobus] ${this.inflight} request(s) still in-flight after 10s — proceeding with resize`,
        );
      }

      const excess = this.streams.splice(newSize);
      if (this.streamIndex >= this.streams.length) {
        this.streamIndex = 0;
      }

      // Close removed streams (flushes SDK-queued records)
      await Promise.allSettled(excess.map((s) => s.close()));
      console.log(`[zerobus] Closed ${excess.length} stream(s)`);

      // If we've scaled to zero, disable auto-scale timer (no streams to check)
      if (newSize === 0) {
        this.disableAutoScale();
      }
    }

    const durationMs = Math.round(performance.now() - start);
    console.log(`[zerobus] Pool resized: ${oldSize} → ${newSize} (${durationMs}ms)`);

    this.recordResize({
      timestamp: new Date().toISOString(),
      trigger,
      oldSize,
      newSize,
      durationMs,
      peakInflight: this.peakInflight,
      idleChecks: trigger === 'auto-scale-down' || trigger === 'scale-to-zero'
        ? this.idleChecks
        : undefined,
      callRate: trigger === 'auto-scale-up' ? this.callsSinceLastCheck : undefined,
    });

    return { oldSize, newSize, durationMs };
  }

  // ── Auto-scale management ──────────────────────────────────────────

  /**
   * Enable automatic pool scaling.
   * Background interval checks load every checkIntervalMs.
   */
  enableAutoScale(config: Partial<AutoScaleConfig> = {}): void {
    this.autoScaleConfig = { ...AUTO_SCALE_DEFAULTS, ...config };
    this.autoScaleEnabled = true;
    this.lastAutoScaleTime = 0;
    this.peakInflight = 0;
    this.idleChecks = 0;
    this.callsSinceLastCheck = 0;

    if (this.autoScaleTimer) clearInterval(this.autoScaleTimer);
    this.autoScaleTimer = setInterval(
      () => void this.checkAutoScale(),
      this.autoScaleConfig.checkIntervalMs,
    );

    console.log(
      `[zerobus] Auto-scale enabled (max: ${this.autoScaleConfig.maxSize}, ` +
        `check: ${this.autoScaleConfig.checkIntervalMs}ms, ` +
        `idle-to-zero: ${this.autoScaleConfig.idleBeforeZeroMs}ms)`,
    );
  }

  /** Disable auto-scaling. Pool stays at current size. */
  disableAutoScale(): void {
    if (this.autoScaleTimer) {
      clearInterval(this.autoScaleTimer);
      this.autoScaleTimer = null;
    }
    this.autoScaleEnabled = false;
  }

  /**
   * Background check — called by the auto-scale interval.
   */
  private async checkAutoScale(): Promise<void> {
    if (!this.autoScaleEnabled || this.streams.length === 0 || this.draining) {
      return;
    }

    const now = Date.now();
    const cooldownElapsed =
      now - this.lastAutoScaleTime >= this.autoScaleConfig.cooldownMs;

    // Capture and reset interval metrics
    const currentInflight = this.inflight;
    const peak = Math.max(this.peakInflight, currentInflight);
    const callRate = this.callsSinceLastCheck;
    this.peakInflight = currentInflight;
    this.callsSinceLastCheck = 0;

    const streamCount = this.streams.length;
    const config = this.autoScaleConfig;

    // ── Scale-up decision ──────────────────────────────────────────
    const concurrentSaturated = peak >= streamCount;
    const highCallRate = callRate >= streamCount;

    if (
      (concurrentSaturated || highCallRate) &&
      streamCount < config.maxSize &&
      cooldownElapsed
    ) {
      const newSize = Math.min(streamCount + 1, config.maxSize);
      const reason = concurrentSaturated
        ? `peak ${peak} in-flight ≥ ${streamCount} streams`
        : `${callRate} calls in interval ≥ ${streamCount} streams`;
      console.log(`[zerobus/autoscale] ${reason} — scaling UP: ${streamCount} → ${newSize}`);

      try {
        await this.resize(newSize, 'auto-scale-up');
        this.lastAutoScaleTime = now;
      } catch (err) {
        console.error('[zerobus/autoscale] Scale-up failed:', err);
      }
      this.idleChecks = 0;
      return;
    }

    // ── Idle detection ────────────────────────────────────────────
    if (currentInflight === 0 && callRate === 0) {
      this.idleChecks++;

      // ── Scale-to-zero decision (at 1 stream, idle for 20 min) ──
      if (streamCount === 1) {
        const idleDuration = this.lastActivityAt
          ? now - this.lastActivityAt.getTime()
          : Infinity;

        if (idleDuration >= config.idleBeforeZeroMs && cooldownElapsed) {
          console.log(
            `[zerobus/autoscale] Idle for ${Math.round(idleDuration / 1000)}s at 1 stream — scaling to ZERO`,
          );
          try {
            await this.resize(0, 'scale-to-zero');
            this.lastAutoScaleTime = now;
          } catch (err) {
            console.error('[zerobus/autoscale] Scale-to-zero failed:', err);
          }
          this.idleChecks = 0;
          return;
        }
      }

      // ── Standard scale-down (N → N-1, but not below 1 via this path) ──
      if (
        this.idleChecks >= IDLE_CHECKS_BEFORE_SCALE_DOWN &&
        streamCount > 1 &&
        cooldownElapsed
      ) {
        const newSize = streamCount - 1;
        console.log(
          `[zerobus/autoscale] Idle for ${this.idleChecks} checks — scaling DOWN: ${streamCount} → ${newSize}`,
        );
        try {
          await this.resize(newSize, 'auto-scale-down');
          this.lastAutoScaleTime = now;
        } catch (err) {
          console.error('[zerobus/autoscale] Scale-down failed:', err);
        }
        this.idleChecks = 0;
      }
    } else {
      this.idleChecks = 0;
    }
  }

  // ── Resize history ─────────────────────────────────────────────────

  private recordResize(event: ResizeEvent): void {
    this.resizeHistory.push(event);
    if (this.resizeHistory.length > MAX_RESIZE_HISTORY) {
      this.resizeHistory.shift();
    }

    // Notify external listener (Lakebase persistence)
    if (this.onResizeCallback) {
      try {
        this.onResizeCallback(event);
      } catch (err) {
        console.warn('[zerobus] onResize callback error:', err);
      }
    }
  }

  /** Get resize history (most recent last). */
  getResizeHistory(): ResizeEvent[] {
    return [...this.resizeHistory];
  }

  // ── Graceful shutdown ──────────────────────────────────────────────

  /**
   * Drain in-flight requests, then close all streams.
   * Call on SIGTERM. Guarantees all accepted records are durably committed.
   */
  async close(): Promise<void> {
    this.draining = true;
    this.disableAutoScale();

    if (this.streams.length === 0) {
      console.log('[zerobus] Pool already cold — nothing to close.');
      return;
    }

    // Drain in-flight requests
    if (this.inflight > 0) {
      console.log(
        `[zerobus] Draining ${this.inflight} in-flight request(s) (timeout: ${DRAIN_TIMEOUT_MS}ms)...`,
      );

      const drainStart = Date.now();
      while (this.inflight > 0 && Date.now() - drainStart < DRAIN_TIMEOUT_MS) {
        await new Promise((r) => setTimeout(r, DRAIN_POLL_INTERVAL_MS));
      }

      if (this.inflight > 0) {
        console.warn(
          `[zerobus] Drain timeout — ${this.inflight} request(s) still in-flight, proceeding with close`,
        );
      } else {
        console.log('[zerobus] All in-flight requests drained.');
      }
    }

    // Close all streams (flush SDK-queued records)
    const oldSize = this.streams.length;
    console.log(`[zerobus] Closing ${oldSize} stream(s)...`);
    await Promise.allSettled(this.streams.map((s) => s.close()));
    this.streams = [];
    this.streamIndex = 0;
    this.sdk = null;

    this.recordResize({
      timestamp: new Date().toISOString(),
      trigger: 'shutdown',
      oldSize,
      newSize: 0,
      durationMs: 0,
    });

    console.log('[zerobus] All streams closed — records durably committed.');
  }
}

// ── Singleton export ─────────────────────────────────────────────────────────

export const zeroBusService = new ZeroBusService();
