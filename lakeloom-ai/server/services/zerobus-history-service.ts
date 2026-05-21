/**
 * ZeroBus History Service — Lakebase persistence for pool lifecycle events.
 *
 * Writes every resize event (wake, scale-up, scale-down, scale-to-zero,
 * shutdown) to app.zerobus_pool_events. Table is replicated to Unity Catalog
 * via Lakehouse Sync → queryable alongside OTel tables for full observability.
 *
 * Modeled after dbxW's load-test-history-service:
 *   - Lazy Lakebase client binding (set after AppKit plugins ready)
 *   - Non-fatal writes (pool operations never blocked by Lakebase failures)
 *   - app_instance_id for distinguishing events across app redeploys
 */

import crypto from 'node:crypto';
import type { ResizeEvent } from './zerobus-service';

// ── Lakebase query interface ──────────────────────────────────────────────

interface LakebaseClient {
  query(text: string, params?: unknown[]): Promise<{ rows: Record<string, unknown>[] }>;
}

// ── State ─────────────────────────────────────────────────────────────────

let lakebaseClient: LakebaseClient | null = null;

/**
 * Unique ID for this app instance (survives within a single container lifetime).
 * Allows correlating events across restarts in the Lakebase history table.
 */
const APP_INSTANCE_ID = crypto.randomUUID().slice(0, 8);

// ── Public API ────────────────────────────────────────────────────────────

/**
 * Set the Lakebase client. Called once from server.ts after AppKit plugins ready.
 */
export function setLakebaseClient(client: LakebaseClient): void {
  lakebaseClient = client;
}

/**
 * Record a pool resize event in Lakebase.
 * Non-fatal — logs a warning on failure but never throws.
 * Intended to be passed to zeroBusService.onResize().
 */
export function recordPoolEvent(event: ResizeEvent): void {
  if (!lakebaseClient) {
    // Lakebase not ready yet (can happen during initial wake before migrations)
    return;
  }

  // Fire-and-forget — don't block the pool operation
  writeEvent(event).catch((err) => {
    console.warn('[zerobus-history] Failed to persist event:', (err as Error).message);
  });
}

/**
 * Query recent pool events from Lakebase.
 * Returns most recent events first.
 */
export async function getRecentEvents(limit = 50): Promise<Record<string, unknown>[]> {
  if (!lakebaseClient) return [];

  const { rows } = await lakebaseClient.query(
    `SELECT * FROM app.zerobus_pool_events
     ORDER BY event_at DESC
     LIMIT $1`,
    [limit],
  );

  return rows;
}

/**
 * Get aggregate stats from pool event history.
 */
export async function getPoolStats(): Promise<Record<string, unknown> | null> {
  if (!lakebaseClient) return null;

  const { rows } = await lakebaseClient.query(`
    SELECT
      COUNT(*) AS total_events,
      COUNT(*) FILTER (WHERE trigger = 'wake') AS wake_count,
      COUNT(*) FILTER (WHERE trigger = 'auto-scale-up') AS scale_up_count,
      COUNT(*) FILTER (WHERE trigger = 'auto-scale-down') AS scale_down_count,
      COUNT(*) FILTER (WHERE trigger = 'scale-to-zero') AS scale_to_zero_count,
      COUNT(*) FILTER (WHERE trigger = 'shutdown') AS shutdown_count,
      MAX(new_size) AS peak_pool_size,
      AVG(duration_ms) FILTER (WHERE trigger = 'wake') AS avg_wake_duration_ms,
      MIN(event_at) AS first_event_at,
      MAX(event_at) AS last_event_at
    FROM app.zerobus_pool_events
  `);

  return rows[0] ?? null;
}

// ── Internal ──────────────────────────────────────────────────────────────

async function writeEvent(event: ResizeEvent): Promise<void> {
  await lakebaseClient!.query(
    `INSERT INTO app.zerobus_pool_events
       (event_at, trigger, old_size, new_size, duration_ms, peak_inflight, idle_checks, call_rate, app_instance_id)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
    [
      event.timestamp,
      event.trigger,
      event.oldSize,
      event.newSize,
      event.durationMs,
      event.peakInflight ?? null,
      event.idleChecks ?? null,
      event.callRate ?? null,
      APP_INSTANCE_ID,
    ],
  );
}
