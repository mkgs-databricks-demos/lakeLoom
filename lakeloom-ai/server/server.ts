import { createApp, analytics, files, lakebase, server } from '@databricks/appkit';
import { setupSampleLakebaseRoutes } from './routes/lakebase/todo-routes';

createApp({
  plugins: [
    server({ autoStart: false }),
    analytics(),
    files(),
    lakebase(),
  ],
})
  .then(async (appkit) => {
    // ── Health check endpoint ────────────────────────────────────────────────
    // Gives the platform an explicit liveness signal during cold-start.
    // Registered before custom routes so it's always reachable.
    appkit.server.extend((app) => {
      app.get('/healthz', (_req, res) => {
        res.status(200).json({ status: 'ok', timestamp: new Date().toISOString() });
      });
    });

    await setupSampleLakebaseRoutes(appkit);
    await appkit.server.start();

    // ── Graceful shutdown ──────────────────────────────────────────────────
    // The platform sends SIGTERM on redeploy/stop. Drain in-flight requests,
    // close the Lakebase PG pool, and exit cleanly so OTel spans flush.
    const shutdown = async (signal: string) => {
      console.log(`[shutdown] Received ${signal}, shutting down gracefully...`);
      try {
        // Close the Lakebase PG connection pool (pg.Pool.end())
        await appkit.lakebase.pool.end();
        console.log('[shutdown] Lakebase pool closed.');
      } catch (err) {
        console.error('[shutdown] Error during cleanup:', err);
      }
      process.exit(0);
    };

    process.on('SIGTERM', () => shutdown('SIGTERM'));
    process.on('SIGINT', () => shutdown('SIGINT'));
  })
  .catch(console.error);
