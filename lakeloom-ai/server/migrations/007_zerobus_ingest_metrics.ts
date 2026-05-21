/**
 * Migration 007 — ZeroBus ingest metrics snapshots.
 *
 * Records periodic ingest throughput, latency, and backpressure metrics
 * for monitoring ZeroBus stream health across deploys. Snapshots are
 * emitted every 30s while the pool is warm.
 *
 * Replicated to Unity Catalog via Lakehouse Sync (REPLICA IDENTITY FULL)
 * for querying alongside OTel tables and pool events.
 */

export const migration007 = {
  name: '007_zerobus_ingest_metrics',
  up: `
    CREATE TABLE IF NOT EXISTS app.zerobus_ingest_metrics (
      id                  BIGSERIAL PRIMARY KEY,
      snapshot_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      records_total       BIGINT NOT NULL DEFAULT 0,
      batches_total       BIGINT NOT NULL DEFAULT 0,
      throughput_rps      REAL NOT NULL DEFAULT 0,
      ack_latency_min_ms  INT NOT NULL DEFAULT 0,
      ack_latency_max_ms  INT NOT NULL DEFAULT 0,
      ack_latency_avg_ms  INT NOT NULL DEFAULT 0,
      ack_latency_p95_ms  INT NOT NULL DEFAULT 0,
      ack_latency_samples INT NOT NULL DEFAULT 0,
      backpressure_events INT NOT NULL DEFAULT 0,
      errors_total        INT NOT NULL DEFAULT 0,
      active_streams      INT NOT NULL DEFAULT 0,
      last_offset         TEXT,
      app_instance_id     TEXT
    );

    ALTER TABLE app.zerobus_ingest_metrics REPLICA IDENTITY FULL;

    CREATE INDEX IF NOT EXISTS idx_zerobus_ingest_metrics_snapshot_at
      ON app.zerobus_ingest_metrics (snapshot_at DESC);

    COMMENT ON TABLE app.zerobus_ingest_metrics IS
      'ZeroBus ingest metrics snapshots (30s interval) — throughput, ack latency, backpressure. Replicated to UC via Lakehouse Sync.';
  `,
};
