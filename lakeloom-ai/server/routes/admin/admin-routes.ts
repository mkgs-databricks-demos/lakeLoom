/**
 * Admin routes — system health dashboard.
 *
 * Endpoints:
 *   GET /api/admin/health — Browser-authenticated. Returns structured health report.
 */

import type { Application } from 'express';
import { getSecrets, getMissingKeys, isPairingReady, isZerobusReady } from '../../services/secrets-service';
import { zeroBusService } from '../../services/zerobus-service';
import { validationError } from '../../lib/errors';

// ── Interfaces ───────────────────────────────────────────────────────────────────

interface LakebaseClient {
  query(text: string, params?: unknown[]): Promise<{ rows: Record<string, unknown>[] }>;
}

interface AppKitContext {
  lakebase: LakebaseClient;
  server: { extend(fn: (app: Application) => void): void };
}

type CheckStatus = 'ok' | 'warning' | 'error';

// ── Route setup ────────────────────────────────────────────────────────────────

export async function setupAdminRoutes(appkit: AppKitContext): Promise<void> {
  const { lakebase } = appkit;

  appkit.server.extend((app) => {
    // ── GET /api/admin/health ────────────────────────────────────────────────
    app.get('/api/admin/health', async (req, res, next) => {
      try {
        const userId = req.headers['x-forwarded-user'] as string | undefined;
        if (!userId) {
          throw validationError('User identity not available.');
        }

        const checks: Record<string, unknown> = {};
        let overallStatus: 'healthy' | 'degraded' | 'unhealthy' = 'healthy';

        const markDegraded = () => { if (overallStatus === 'healthy') overallStatus = 'degraded'; };
        const markUnhealthy = () => { overallStatus = 'unhealthy'; };

        // ── Secrets check ─────────────────────────────────────────────────
        try {
          const secrets = getSecrets();
          const missing = getMissingKeys();
          const presentCount = Object.values(secrets).filter((v) => v != null && v !== '').length;
          const status: CheckStatus = missing.length === 0 ? 'ok' : 'error';
          if (status === 'error') markUnhealthy();
          checks.secrets = { status, present: presentCount, missing };
        } catch (err) {
          markUnhealthy();
          checks.secrets = { status: 'error', error: (err as Error).message };
        }

        // ── Lakebase check ────────────────────────────────────────────────
        try {
          const startMs = Date.now();
          await lakebase.query('SELECT 1');
          const latencyMs = Date.now() - startMs;

          // Count applied migrations
          const { rows } = await lakebase.query(
            `SELECT COUNT(*) as count FROM app._migrations`,
          );
          const migrationsApplied = Number(rows[0]?.count ?? 0);

          checks.lakebase = { status: 'ok' as CheckStatus, latency_ms: latencyMs, migrations_applied: migrationsApplied };
        } catch (err) {
          markUnhealthy();
          checks.lakebase = { status: 'error', error: (err as Error).message };
        }

        // ── Volumes check ─────────────────────────────────────────────────
        const volumeEnvVars: Record<string, string> = {
          session_audio: 'VOLUME_SESSION_AUDIO_PATH',
          screenshots: 'VOLUME_SCREENSHOTS_PATH',
          documents: 'VOLUME_DOCUMENTS_PATH',
        };
        const volumeChecks: Record<string, { status: CheckStatus; path?: string; error?: string }> = {};

        for (const [name, envVar] of Object.entries(volumeEnvVars)) {
          const path = process.env[envVar];
          if (path && path.startsWith('/Volumes/')) {
            volumeChecks[name] = { status: 'ok', path };
          } else {
            markDegraded();
            volumeChecks[name] = { status: 'error', error: `${envVar} not configured or invalid` };
          }
        }
        checks.volumes = volumeChecks;

        // ── ZeroBus check ─────────────────────────────────────────────────
        try {
          const pool = zeroBusService.poolStatus();
          const metrics = zeroBusService.ingestMetrics();
          const zbStatus: CheckStatus = isZerobusReady() ? 'ok' : 'warning';
          if (zbStatus === 'warning') markDegraded();

          checks.zerobus = {
            status: zbStatus,
            active_streams: pool.active_streams,
            pool_size: pool.pool_size,
            initialized: pool.initialized,
            last_activity_at: pool.last_activity_at,
            records_total: metrics.records_total,
            errors_total: metrics.errors_total,
            throughput_rps: metrics.throughput_rps,
          };
        } catch (err) {
          markDegraded();
          checks.zerobus = { status: 'warning', error: (err as Error).message };
        }

        // ── App info ──────────────────────────────────────────────────────
        checks.app = {
          status: 'ok' as CheckStatus,
          name: process.env.DATABRICKS_APP_NAME ?? 'unknown',
          node_version: process.version,
          uptime_s: Math.round(process.uptime()),
          environment: process.env.NODE_ENV ?? 'production',
        };

        // ── Sweeper check ─────────────────────────────────────────────────
        try {
          const { rows } = await lakebase.query(
            `SELECT id, started_at, completed_at, orphan_count, bytes_reclaimed, files_deleted, status, error_message
             FROM app.sweeper_runs
             ORDER BY started_at DESC
             LIMIT 1`,
          );
          if (rows.length > 0) {
            const run = rows[0];
            const completedAt = run.completed_at ? new Date(run.completed_at as string) : null;
            const isStale = completedAt ? (Date.now() - completedAt.getTime()) > 7 * 24 * 60 * 60 * 1000 : true;
            const swStatus: CheckStatus = run.status === 'completed' && !isStale ? 'ok' : 'warning';
            if (swStatus === 'warning') markDegraded();

            checks.sweeper = {
              status: swStatus,
              last_run_at: run.completed_at ?? run.started_at,
              run_status: run.status,
              orphan_count: run.orphan_count,
              bytes_reclaimed: run.bytes_reclaimed,
              files_deleted: run.files_deleted,
              is_stale: isStale,
              error_message: run.error_message ?? null,
            };
          } else {
            markDegraded();
            checks.sweeper = { status: 'warning', message: 'No sweeper runs recorded yet' };
          }
        } catch {
          // Table might not exist yet (migration 019 not applied)
          checks.sweeper = { status: 'warning', message: 'sweeper_runs table not available' };
        }

        res.json({ status: overallStatus, checks, timestamp: new Date().toISOString() });
      } catch (err) {
        next(err);
      }
    });
  });
}
