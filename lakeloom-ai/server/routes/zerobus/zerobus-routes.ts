/**
 * ZeroBus health and diagnostics routes.
 *
 * GET /api/zerobus/health  — Lightweight health check (env, pool, auto-scale, ingest metrics)
 * GET /api/zerobus/history — Pool event history from Lakebase
 * GET /api/zerobus/stats   — Aggregate pool statistics
 *
 * All endpoints are browser-accessible (no auth required — diagnostic only,
 * no sensitive data exposed). For production, wrap with browserAuth if needed.
 */

import type { Application } from 'express';
import { zeroBusService } from '../../services/zerobus-service';
import { getRecentEvents, getPoolStats } from '../../services/zerobus-history-service';

// ── AppKit interface ────────────────────────────────────────────────────────

interface AppKitContext {
  server: { extend(fn: (app: Application) => void): void };
}

// ── Route registration ──────────────────────────────────────────────────────

export async function setupZerobusRoutes(appkit: AppKitContext): Promise<void> {
  appkit.server.extend((app) => {
    // ── GET /api/zerobus/health ───────────────────────────────────────
    //
    // Returns environment readiness, current pool state, auto-scale
    // configuration, and real-time ingest metrics (throughput, latency,
    // backpressure). Use for operational monitoring and deploy validation.
    //
    // Response shape:
    //   { status, service, env_configured, target_table, pool, auto_scale,
    //     ingest_metrics, missing_env_vars? }

    app.get('/api/zerobus/health', (_req, res) => {
      const envCheck = zeroBusService.checkEnv();
      const pool = zeroBusService.poolStatus();
      const autoScale = zeroBusService.autoScaleStatus();
      const metrics = zeroBusService.ingestMetrics();

      const status = envCheck.configured
        ? pool.draining
          ? 'draining'
          : 'ok'
        : 'misconfigured';

      res.json({
        status,
        service: 'zerobus-transcript-ingest',
        env_configured: envCheck.configured,
        target_table: process.env.LAKELOOM_TARGET_TABLE_NAME ?? '(not set)',
        pool: {
          active_streams: pool.active_streams,
          max_size: pool.auto_scale.max_size,
          inflight_requests: pool.inflight_requests,
          draining: pool.draining,
          cold: zeroBusService.isCold(),
          last_activity_at: pool.last_activity_at,
        },
        auto_scale: {
          enabled: autoScale.enabled,
          max_size: autoScale.config.maxSize,
          idle_before_zero_ms: autoScale.config.idleBeforeZeroMs,
          check_interval_ms: autoScale.config.checkIntervalMs,
          cooldown_ms: autoScale.config.cooldownMs,
          peak_inflight: autoScale.peak_inflight,
          idle_checks: autoScale.idle_checks,
        },
        ingest_metrics: {
          records_total: metrics.records_total,
          batches_total: metrics.batches_total,
          last_offset: metrics.last_offset,
          throughput_rps: metrics.throughput_rps,
          backpressure_events: metrics.backpressure_events,
          errors_total: metrics.errors_total,
          ack_latency: metrics.ack_latency,
          stream_config: metrics.stream_config,
        },
        resize_history_count: autoScale.history.length,
        recent_resizes: autoScale.history.slice(-5),
        ...(envCheck.missing.length > 0 && {
          missing_env_vars: envCheck.missing,
        }),
      });
    });

    // ── GET /api/zerobus/history ──────────────────────────────────────
    //
    // Returns pool lifecycle events from Lakebase (persisted across restarts).
    // Query param: ?limit=N (default: 50, max: 200)

    app.get('/api/zerobus/history', async (req, res) => {
      try {
        const limit = Math.min(
          Math.max(parseInt(req.query.limit as string, 10) || 50, 1),
          200,
        );

        const events = await getRecentEvents(limit);
        res.json({
          status: 'ok',
          count: events.length,
          events,
        });
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        console.error('[zerobus/history] Query failed:', message);
        res.status(500).json({
          status: 'error',
          message: `Failed to retrieve pool history: ${message}`,
        });
      }
    });

    // ── GET /api/zerobus/stats ────────────────────────────────────────
    //
    // Aggregate statistics from the full pool event history in Lakebase.

    app.get('/api/zerobus/stats', async (_req, res) => {
      try {
        const stats = await getPoolStats();

        if (!stats) {
          res.json({
            status: 'ok',
            message: 'No pool events recorded yet (Lakebase not initialized).',
            stats: null,
          });
          return;
        }

        res.json({
          status: 'ok',
          stats,
        });
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        console.error('[zerobus/stats] Query failed:', message);
        res.status(500).json({
          status: 'error',
          message: `Failed to retrieve pool stats: ${message}`,
        });
      }
    });
  });
}
