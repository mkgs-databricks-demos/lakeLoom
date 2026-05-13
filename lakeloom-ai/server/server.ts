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
    await setupSampleLakebaseRoutes(appkit);
    await appkit.server.start();

    // ── Graceful shutdown ──────────────────────────────────────────────────
    // The platform sends SIGTERM on redeploy/stop. Drain in-flight requests,
    // close the Lakebase connection pool, and exit cleanly so OTel spans flush.
    const shutdown = async (signal: string) => {
      console.log(`[shutdown] Received ${signal}, shutting down gracefully...`);
      try {
        // AppKit exposes a destroy/close method to tear down plugins cleanly.
        // This closes the Lakebase PG pool, stops the HTTP server, and flushes
        // any buffered analytics/telemetry.
        if (typeof appkit.destroy === 'function') {
          await appkit.destroy();
        } else if (typeof appkit.close === 'function') {
          await appkit.close();
        } else {
          // Fallback: close Lakebase pool directly if available
          if (appkit.lakebase && typeof appkit.lakebase.close === 'function') {
            await appkit.lakebase.close();
          }
        }
        console.log('[shutdown] Cleanup complete, exiting.');
      } catch (err) {
        console.error('[shutdown] Error during cleanup:', err);
      }
      process.exit(0);
    };

    process.on('SIGTERM', () => shutdown('SIGTERM'));
    process.on('SIGINT', () => shutdown('SIGINT'));
  })
  .catch(console.error);
