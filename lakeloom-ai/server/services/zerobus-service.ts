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
 * ── Flush & throughput tuning ─────────────────────────────────────────
 *
 *   maxInflightRequests: 200  — capacity per stream; creates backpressure
 *                               signal for auto-scale AND triggers batch
 *                               commits when buffer fills.
 *   flushTimeoutMs: 1000      — sub-second guarantee; even at low volume
 *                               (1 user), commits within 1s.
 *
 *   Together: whichever fires first (buffer full OR 1s timeout) triggers
 *   a server-side commit. Handles 1 user to 500+ users uniformly.
 *
 * Pool lifecycle events are recorded in Lakebase (app.zerobus_pool_events)
 * via the zerobus-history-service for observability and diagnostics.
 *
 * Ingest metrics are tracked in-memory and periodically snapshotted to
 * Lakebase (app.zerobus_ingest_metrics) for monitoring throughput, latency,
 * and backpressure across deploys.
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
import { getZerobusSPNCredentials, getZerobusConfig, getSecrets } from './secrets-service';

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

/** Ingest metrics snapshot (exposed via health endpoint + persisted to Lakebase). */
export interface IngestMetrics {
  /** Total records ingested since this instance started. */
  records_total: number;
  /** Total ingest calls (single + batch). */
  batches_total: number;
  /** Most recent offset returned by the SDK. */
  last_offset: string;
  /** Ack latency stats (ms) from waitForOffset() calls. */
  ack_latency: {
    min_ms: number;
    max_ms: number;
    avg_ms: number;
    p95_ms: number;
    samples: number;
  };
  /** Times ingestRecordOffset() took > 50ms (backpressure indicator). */
  backpressure_events: number;
  /** Total ingest errors (stream failures, timeouts). */
  errors_total: number;
  /** Records per second (rolling 60s window). */
  throughput_rps: number;
  /** Stream config for reference. */
  stream_config: {
    max_inflight_requests: number;
    flush_timeout_ms: number;
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

/** Threshold (ms) above which ingestRecordOffset is considered backpressure. */
const BACKPRESSURE_THRESHOLD_MS = 50;

/** Rolling window size for throughput calculation. */
const THROUGHPUT_WINDOW_MS = 60_000;

/** Max ack latency samples retained for percentile calculation. */
const MAX_LATENCY_SAMPLES = 1000;

// ── Stream tuning ────────────────────────────────────────────────────────────
// These values work together for sub-second write latency at any scale:
//   - maxInflightRequests (200): capacity per stream. When full, creates
//     backpressure → longer HTTP handler hold → inflight rises → scale-up.
//     Also triggers batch commit when buffer fills (high throughput path).
//   - flushTimeoutMs (1000): guarantees commit within 1s even at low volume
//     when buffer never fills (low throughput path).

const STREAM_MAX_INFLIGHT = 200;
const STREAM_FLUSH_TIMEOUT_MS = 1_000;

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

  // ── Ingest metrics ─────────────────────────────────────────────────
  private recordsTotal = 0;
  private batchesTotal = 0;
  private lastOffset = BigInt(0);
  private ackLatencySamples: number[] = [];
  private backpressureEvents = 0;
  private errorsTotal = 0;
  private throughputWindow: number[] = []; // timestamps of recent ingests
  private metricsSnapshotTimer: ReturnType<typeof setInterval> | null = null;
  private onMetricsCallback: ((metrics: IngestMetrics) => void) | null = null;

  // ── Public API ─────────────────────────────────────────────────────

  /**
   * Register a callback invoked on every resize event.
   * Used by zerobus-history-service to persist events to Lakebase.
   */
  onResize(callback: (event: ResizeEvent) => void): void {
    this.onResizeCallback = callback;
  }

  /**
   * Register a callback invoked periodically with ingest metrics snapshot.
   * Used by zerobus-history-service to persist metrics to Lakebase.
   */
  onMetricsSnapshot(callback: (metrics: IngestMetrics) => void): void {
    this.onMetricsCallback = callback;
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
    this.batchesTotal++;

    try {
      const stream = this.nextStream();

      // Track ingest latency for backpressure detection
      const ingestStart = performance.now();
      const offset = await stream.ingestRecordOffset(record);
      const ingestMs = performance.now() - ingestStart;

      if (ingestMs > BACKPRESSURE_THRESHOLD_MS) {
        this.backpressureEvents++;
      }

      this.lastOffset = offset;
      this.recordsTotal++;
      this.throughputWindow.push(Date.now());

      if (waitForAck) {
        const ackStart = performance.now();
        await stream.waitForOffset(offset);
        this.recordAckLatency(performance.now() - ackStart);
      }

      return offset;
    } catch (err) {
      this.errorsTotal++;
      throw err;
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
    this.batchesTotal++;

    try {
      let lastOffset = BigInt(0);
      for (const record of records) {
        const stream = this.nextStream();

        const ingestStart = performance.now();
        lastOffset = await stream.ingestRecordOffset(record);
        const ingestMs = performance.now() - ingestStart;

        if (ingestMs > BACKPRESSURE_THRESHOLD_MS) {
          this.backpressureEvents++;
        }

        this.recordsTotal++;
        this.throughputWindow.push(Date.now());
      }

      this.lastOffset = lastOffset;

      // Wait for durability confirmation on the last record
      const stream = this.streams[
        (this.streamIndex - 1 + this.streams.length) % this.streams.length
      ];
      const ackStart = performance.now();
      await stream.waitForOffset(lastOffset);
      this.recordAckLatency(performance.now() - ackStart);

      return records.length;
    } catch (err) {
      this.errorsTotal++;
      throw err;
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

  /** Returns current ingest metrics snapshot. */
  ingestMetrics(): IngestMetrics {
    this.pruneThoughputWindow();
    const latencyStats = this.computeLatencyStats();

    return {
      records_total: this.recordsTotal,
      batches_total: this.batchesTotal,
      last_offset: this.lastOffset.toString(),
      ack_latency: latencyStats,
      backpressure_events: this.backpressureEvents,
      errors_total: this.errorsTotal,
      throughput_rps: this.computeThroughput(),
      stream_config: {
        max_inflight_requests: STREAM_MAX_INFLIGHT,
        flush_timeout_ms: STREAM_FLUSH_TIMEOUT_MS,
      },
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

    // Use LAKELOOM_WORKSPACE_URL (public workspace URL from secret scope) for token exchange.
    // DATABRICKS_HOST is platform-internal and may not be routable for UC token exchange.
    this.workspaceUrl = getSecrets().workspaceUrl || process.env.DATABRICKS_HOST || '';

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

    // Start periodic metrics snapshot (every 30s while pool is alive)
    this.startMetricsSnapshot();
  }

  /** Open one gRPC stream with standard options. */
  private async createOneStream(): Promise<IngestStream> {
    return (this.sdk as any).createStream(
      { tableName: this.targetTable },
      this.clientId,
      this.clientSecret,
      {
        maxInflightRequests: STREAM_MAX_INFLIGHT,
        recovery: true,
        recoveryTimeoutMs: 15_000,
        recoveryRetries: 4,
        flushTimeoutMs: STREAM_FLUSH_TIMEOUT_MS,
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

  // ── Ingest metrics helpers ─────────────────────────────────────────

  /** Record an ack latency sample. */
  private recordAckLatency(ms: number): void {
    this.ackLatencySamples.push(ms);
    if (this.ackLatencySamples.length > MAX_LATENCY_SAMPLES) {
      // Keep the most recent half when we exceed the limit
      this.ackLatencySamples = this.ackLatencySamples.slice(-MAX_LATENCY_SAMPLES / 2);
    }
  }

  /** Compute latency percentile stats. */
  private computeLatencyStats(): IngestMetrics['ack_latency'] {
    const samples = this.ackLatencySamples;
    if (samples.length === 0) {
      return { min_ms: 0, max_ms: 0, avg_ms: 0, p95_ms: 0, samples: 0 };
    }

    const sorted = [...samples].sort((a, b) => a - b);
    const sum = sorted.reduce((acc, v) => acc + v, 0);
    const p95Index = Math.floor(sorted.length * 0.95);

    return {
      min_ms: Math.round(sorted[0]),
      max_ms: Math.round(sorted[sorted.length - 1]),
      avg_ms: Math.round(sum / sorted.length),
      p95_ms: Math.round(sorted[p95Index]),
      samples: sorted.length,
    };
  }

  /** Prune old entries from the throughput window. */
  private pruneThoughputWindow(): void {
    const cutoff = Date.now() - THROUGHPUT_WINDOW_MS;
    while (this.throughputWindow.length > 0 && this.throughputWindow[0] < cutoff) {
      this.throughputWindow.shift();
    }
  }

  /** Compute current records/sec from the rolling window. */
  private computeThroughput(): number {
    this.pruneThoughputWindow();
    if (this.throughputWindow.length === 0) return 0;
    return Math.round((this.throughputWindow.length / THROUGHPUT_WINDOW_MS) * 1000 * 10) / 10;
  }

  /** Start periodic metrics snapshot emission. */
  private startMetricsSnapshot(): void {
    if (this.metricsSnapshotTimer) return;

    // Emit a metrics snapshot every 30 seconds while the pool is alive
    this.metricsSnapshotTimer = setInterval(() => {
      if (this.onMetricsCallback && this.recordsTotal > 0) {
        try {
          this.onMetricsCallback(this.ingestMetrics());
        } catch (err) {
          console.warn('[zerobus] Metrics snapshot callback error:', err);
        }
      }
    }, 30_000);
  }

  /** Stop periodic metrics snapshot. */
  private stopMetricsSnapshot(): void {
    if (this.metricsSnapshotTimer) {
      clearInterval(this.metricsSnapshotTimer);
      this.metricsSnapshotTimer = null;
    }
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

      // If we've scaled to zero, disable auto-scale timer and metrics snapshot
      if (newSize === 0) {
        this.disableAutoScale();
        this.stopMetricsSnapshot();
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
    this.stopMetricsSnapshot();

    // Emit final metrics snapshot before shutdown
    if (this.onMetricsCallback && this.recordsTotal > 0) {
      try {
        this.onMetricsCallback(this.ingestMetrics());
      } catch { /* non-fatal */ }
    }

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
