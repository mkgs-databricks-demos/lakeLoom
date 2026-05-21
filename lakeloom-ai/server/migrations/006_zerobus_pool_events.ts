/**
 * Migration 006 — ZeroBus pool event tracking.
 *
 * Records every stream pool lifecycle event (wake, scale-up, scale-down,
 * scale-to-zero, shutdown) for observability. Replicated to Unity Catalog
 * via Lakehouse Sync (REPLICA IDENTITY FULL).
 */

export const migration006 = {
  name: '006_zerobus_pool_events',
  up: `
    CREATE TABLE IF NOT EXISTS app.zerobus_pool_events (
      id              BIGSERIAL PRIMARY KEY,
      event_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      trigger         TEXT NOT NULL,
      old_size        INT NOT NULL,
      new_size        INT NOT NULL,
      duration_ms     INT NOT NULL DEFAULT 0,
      peak_inflight   INT,
      idle_checks     INT,
      call_rate       INT,
      app_instance_id TEXT
    );

    ALTER TABLE app.zerobus_pool_events REPLICA IDENTITY FULL;

    CREATE INDEX IF NOT EXISTS idx_zerobus_pool_events_trigger
      ON app.zerobus_pool_events (trigger);

    CREATE INDEX IF NOT EXISTS idx_zerobus_pool_events_event_at
      ON app.zerobus_pool_events (event_at DESC);

    COMMENT ON TABLE app.zerobus_pool_events IS
      'ZeroBus stream pool lifecycle events — wake, scale-up/down, scale-to-zero, shutdown. Replicated to UC via Lakehouse Sync.';
  `,
};
