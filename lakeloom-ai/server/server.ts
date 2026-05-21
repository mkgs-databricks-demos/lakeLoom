import { createApp, analytics, lakebase, server, files } from '@databricks/appkit';
import { setupPairingRoutes } from './routes/pairing/pairing-routes';
import { setupCaptureRoutes } from './routes/captures/capture-routes';
import registerUploads from './routes/uploads/upload-routes';
import { setupEventRoutes } from './routes/events/event-routes';
import { setupProjectRoutes } from './routes/projects/project-routes';
import { setupZerobusRoutes } from './routes/zerobus/zerobus-routes';
import { runMigrations } from './migrations/migrate';
import { initSecrets } from './services/secrets-service';
import { zeroBusService } from './services/zerobus-service';
import { setLakebaseClient, recordPoolEvent } from './services/zerobus-history-service';
import { problemDetailsHandler } from './lib/errors';

function classifyUploadIngressPath(path: string): 'audio' | 'screenshot' | 'photo' | 'document' | null {
  if (/^\/api\/captures\/[^/]+\/audio$/.test(path)) {
    return 'audio';
  }
  if (/^\/api\/captures\/[^/]+\/screenshots$/.test(path)) {
    return 'screenshot';
  }
  if (/^\/api\/captures\/[^/]+\/photos$/.test(path)) {
    return 'photo';
  }
  if (/^\/api\/projects\/[^/]+\/documents$/.test(path)) {
    return 'document';
  }
  return null;
}

createApp({
  plugins: [
    server(),
    analytics(),
    lakebase(),
    files({
      volumes: {
        'session_audio': { policy: files.policy.allowAll() },
        'screenshots': { policy: files.policy.allowAll() },
        'documents': { policy: files.policy.allowAll() },
      },
    }),
  ],

  async onPluginsReady(appkit) {
    await initSecrets().catch((err) => {
      console.warn('[startup] Secrets initialization failed (pairing will be gated):', err);
    });

    try {
      await runMigrations(appkit.lakebase);
    } catch (err) {
      console.error('[startup] Migration failed:', err);
    }

    // ── Initialize ZeroBus history service (Lakebase persistence) ──────────
    setLakebaseClient(appkit.lakebase);
    zeroBusService.onResize(recordPoolEvent);

    // ── Upload ingress diagnostics ────────────────────────────────────────
    appkit.server.extend((app) => {
      app.use((req, res, next) => {
        if (req.method !== 'POST') { next(); return; }
        const uploadKind = classifyUploadIngressPath(req.path);
        if (!uploadKind) { next(); return; }
        const startedAtMs = Date.now();
        console.log('[upload] ingress.request', {
          upload_kind: uploadKind,
          request_path: req.path,
          content_type: req.headers['content-type'] ?? null,
          content_length: req.headers['content-length'] ?? null,
          has_authorization: Boolean(req.headers.authorization),
          has_session_token: Boolean(req.headers['x-lakeloom-session-token']),
          has_signature: Boolean(req.headers['x-lakeloom-signature']),
        });
        res.on('finish', () => {
          console.log('[upload] ingress.response', {
            upload_kind: uploadKind,
            request_path: req.path,
            status_code: res.statusCode,
            duration_ms: Date.now() - startedAtMs,
          });
        });
        next();
      });
    });

    // ── Health check ──────────────────────────────────────────────────────
    appkit.server.extend((app) => {
      app.get('/healthz', (_req, res) => {
        res.status(200).json({ status: 'ok', timestamp: new Date().toISOString() });
      });
    });

    // ── User identity ─────────────────────────────────────────────────────
    appkit.server.extend((app) => {
      app.get('/api/me', (req, res) => {
        const email = req.headers['x-forwarded-email'] as string | undefined;
        const preferredUsername = req.headers['x-forwarded-preferred-username'] as string | undefined;
        const scimId = req.headers['x-forwarded-user'] as string | undefined;
        if (!email && !scimId) {
          res.status(401).json({
            type: 'https://lakeloom/errors/unauthenticated',
            title: 'Unauthenticated',
            status: 401,
            detail: 'No user identity headers present.',
          });
          return;
        }
        const displayName = preferredUsername ?? email?.split('@')[0] ?? 'Unknown';
        res.status(200).json({ email: email ?? null, display_name: displayName, scim_id: scimId ?? null });
      });
    });

    // ── Register routes ───────────────────────────────────────────────────
    await setupPairingRoutes(appkit);
    await setupCaptureRoutes(appkit);
    registerUploads(appkit);
    await setupEventRoutes(appkit);
    await setupProjectRoutes(appkit);
    await setupZerobusRoutes(appkit);

    // ── Error handler (must be last) ──────────────────────────────────────
    appkit.server.extend((app) => {
      app.use(problemDetailsHandler);
    });

    // ── Graceful shutdown ─────────────────────────────────────────────────
    let shuttingDown = false;
    const shutdown = async (signal: string) => {
      if (shuttingDown) return;
      shuttingDown = true;
      console.log(`[shutdown] Received ${signal}, shutting down gracefully...`);
      const forceExitTimer = setTimeout(() => {
        console.error('[shutdown] Forced exit after 12s timeout.');
        process.exit(1);
      }, 12_000);
      forceExitTimer.unref();

      try {
        await zeroBusService.close();
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

      console.log('[shutdown] Clean exit.');
      process.exit(0);
    };

    process.on('SIGTERM', () => shutdown('SIGTERM'));
    process.on('SIGINT', () => shutdown('SIGINT'));
  },
}).catch(console.error);
