import { createApp, analytics, lakebase, server } from '@databricks/appkit';
import { setupPairingRoutes } from './routes/pairing/pairing-routes';
import { setupCaptureRoutes } from './routes/captures/capture-routes';
import { setupUploadRoutes } from './routes/uploads/upload-routes';
import { setupEventRoutes } from './routes/events/event-routes';
import { setupProjectRoutes } from './routes/projects/project-routes';
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
    // Creates app schema + paired_sessions + capture_sessions + uploads + projects tables.
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
    await setupPairingRoutes(appkit);
    await setupCaptureRoutes(appkit);
    await setupUploadRoutes(appkit);
    await setupEventRoutes(appkit);
    await setupProjectRoutes(appkit);

    // ── Error handler (must be last) ──────────────────────────────────────
    appkit.server.extend((app) => {
      app.use(problemDetailsHandler);
    });

    const httpServer = await appkit.server.start();

    // ── Graceful shutdown ─────────────────────────────────────────────────
    // The platform sends SIGTERM on redeploy/stop. We have 15s before a
    // force-kill. Close the HTTP server first (stop accepting new connections),
    // then drain ZeroBus streams and the Lakebase pool. A 12s safety timeout
    // ensures we exit before the platform force-kills at 15s.
    let shuttingDown = false;

    const shutdown = async (signal: string) => {
      if (shuttingDown) return; // Prevent double-shutdown
      shuttingDown = true;

      console.log(`[shutdown] Received ${signal}, shutting down gracefully...`);

      // Safety net: force exit after 12s (platform kills at 15s)
      const forceExitTimer = setTimeout(() => {
        console.error('[shutdown] Forced exit after 12s timeout.');
        process.exit(1);
      }, 12_000);
      forceExitTimer.unref(); // Don't keep event loop alive

      // 1. Stop accepting new connections
      try {
        await new Promise<void>((resolve, reject) => {
          httpServer.close((err) => (err ? reject(err) : resolve()));
        });
        console.log('[shutdown] HTTP server closed.');
      } catch (err) {
        console.error('[shutdown] HTTP server close error:', err);
      }

      // 2. Close ZeroBus streams
      try {
        await shutdownZerobus();
        console.log('[shutdown] ZeroBus streams closed.');
      } catch (err) {
        console.error('[shutdown] ZeroBus shutdown error:', err);
      }

      // 3. Close Lakebase pool
      try {
        await appkit.lakebase.pool.end();
        console.log('[shutdown] Lakebase pool closed.');
      } catch (err) {
        console.error('[shutdown] Lakebase shutdown error:', err);
      }

      console.log('[shutdown] Clean exit.');
      process.exit(0);
    };

    process.on('SIGTERM', () => shutdown('SIGTERM'));
    process.on('SIGINT', () => shutdown('SIGINT'));
  })
  .catch(console.error);
