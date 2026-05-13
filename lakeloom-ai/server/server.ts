import { createApp, analytics, lakebase, server } from '@databricks/appkit';
import { setupSampleLakebaseRoutes } from './routes/lakebase/todo-routes';
import { setupPairingRoutes } from './routes/pairing/pairing-routes';
import { setupUploadRoutes } from './routes/uploads/upload-routes';
import { setupEventRoutes } from './routes/events/event-routes';
import { runMigrations } from './migrations/migrate';
import { initSecrets } from './services/secrets-service';
import { shutdown as shutdownZerobus } from './services/zerobus-service';
import { problemDetailsHandler } from './lib/errors';

createApp({
  plugins: [
    server({ autoStart: false }),
    analytics(),
    lakebase(),
  ],
})
  .then(async (appkit) => {
    // ── Initialize secrets from Databricks secret scope ────────────────────
    // Non-fatal: missing secrets are logged; pairing endpoints return 503.
    await initSecrets().catch((err) => {
      console.warn('[startup] Secrets initialization failed (pairing will be gated):', err);
    });

    // ── Run Lakebase migrations ───────────────────────────────────────────
    // Creates app schema + paired_sessions table if not present.
    try {
      await runMigrations(appkit.lakebase);
    } catch (err) {
      console.error('[startup] Migration failed:', err);
      // Continue startup — existing tables may still work
    }

    // ── Health check endpoint ─────────────────────────────────────────────
    appkit.server.extend((app) => {
      app.get('/healthz', (_req, res) => {
        res.status(200).json({ status: 'ok', timestamp: new Date().toISOString() });
      });
    });

    // ── Register routes ───────────────────────────────────────────────────
    await setupSampleLakebaseRoutes(appkit);
    await setupPairingRoutes(appkit);
    await setupUploadRoutes(appkit);
    await setupEventRoutes(appkit);

    // ── Error handler (must be last) ──────────────────────────────────────
    appkit.server.extend((app) => {
      app.use(problemDetailsHandler);
    });

    await appkit.server.start();

    // ── Graceful shutdown ─────────────────────────────────────────────────
    // The platform sends SIGTERM on redeploy/stop. Drain in-flight requests,
    // close ZeroBus streams, close the Lakebase PG pool, and exit cleanly.
    const shutdown = async (signal: string) => {
      console.log(`[shutdown] Received ${signal}, shutting down gracefully...`);
      try {
        await shutdownZerobus();
        console.log('[shutdown] ZeroBus streams closed.');
      } catch (err) {
        console.error('[shutdown] ZeroBus shutdown error:', err);
      }
      try {
        await appkit.lakebase.pool.end();
        console.log('[shutdown] Lakebase pool closed.');
      } catch (err) {
        console.error('[shutdown] Lakebase shutdown error:', err);
      }
      process.exit(0);
    };

    process.on('SIGTERM', () => shutdown('SIGTERM'));
    process.on('SIGINT', () => shutdown('SIGINT'));
  })
  .catch(console.error);
