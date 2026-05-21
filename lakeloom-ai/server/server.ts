import { createApp, analytics, lakebase, server, files } from '@databricks/appkit';
import { setupPairingRoutes } from './routes/pairing/pairing-routes';
import { setupCaptureRoutes } from './routes/captures/capture-routes';
import registerUploads from './routes/uploads/upload-routes';
import { setupEventRoutes } from './routes/events/event-routes';
import { setupProjectRoutes } from './routes/projects/project-routes';
import { runMigrations } from './migrations/migrate';
import { initSecrets } from './services/secrets-service';
import { shutdown as shutdownZerobus } from './services/zerobus-service';
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

    // ── Early upload ingress diagnostics ───────────────────────────────────
    // Logs before route-specific middleware so we can distinguish:
    //   1. request never reached Express
    //   2. request reached Express but stalled before/inside iOS auth
    //   3. request reached the upload handler but failed downstream
    appkit.server.extend((app) => {
      app.use((req, res, next) => {
        if (req.method !== 'POST') {
          next();
          return;
        }

        const uploadKind = classifyUploadIngressPath(req.path);
        if (!uploadKind) {
          next();
          return;
        }

        const startedAtMs = Date.now();
        console.log('[upload] ingress.request', {
          upload_kind: uploadKind,
          request_method: req.method,
          request_path: req.path,
          request_original_url: req.originalUrl,
          host: req.headers.host ?? null,
          x_forwarded_host: req.headers['x-forwarded-host'] ?? null,
          x_forwarded_proto: req.headers['x-forwarded-proto'] ?? null,
          x_forwarded_for: req.headers['x-forwarded-for'] ?? null,
          content_type: req.headers['content-type'] ?? null,
          content_length: req.headers['content-length'] ?? null,
          transfer_encoding: req.headers['transfer-encoding'] ?? null,
          user_agent: req.headers['user-agent'] ?? null,
          has_authorization: Boolean(req.headers.authorization),
          has_session_token: Boolean(req.headers['x-lakeloom-session-token']),
          has_signature: Boolean(req.headers['x-lakeloom-signature']),
          has_timestamp: Boolean(req.headers['x-lakeloom-timestamp']),
        });

        res.on('finish', () => {
          console.log('[upload] ingress.response', {
            upload_kind: uploadKind,
            request_method: req.method,
            request_path: req.path,
            status_code: res.statusCode,
            duration_ms: Date.now() - startedAtMs,
          });
        });

        next();
      });
    });

    // ── Health check endpoint ─────────────────────────────────────────────
    appkit.server.extend((app) => {
      app.get('/healthz', (_req, res) => {
        res.status(200).json({ status: 'ok', timestamp: new Date().toISOString() });
      });
    });

    // ── User identity endpoint ────────────────────────────────────────────
    // Returns the current user's identity from the auth sidecar headers.
    // Browser requests always have these headers after passing through the
    // Databricks Apps platform auth proxy.
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

        // Derive display_name from email (before @) if no explicit name header
        const displayName = preferredUsername ?? email?.split('@')[0] ?? 'Unknown';

        res.status(200).json({
          email: email ?? null,
          display_name: displayName,
          scim_id: scimId ?? null,
        });
      });
    });

    // ── Register routes ───────────────────────────────────────────────────
    await setupPairingRoutes(appkit);
    await setupCaptureRoutes(appkit);
    registerUploads(appkit);
    await setupEventRoutes(appkit);
    await setupProjectRoutes(appkit);

    // ── Error handler (must be last) ──────────────────────────────────────
    appkit.server.extend((app) => {
      app.use(problemDetailsHandler);
    });


    // ── Graceful shutdown ─────────────────────────────────────────────────
    // The platform sends SIGTERM on redeploy/stop. We have 15s before a
    // force-kill. Drain ZeroBus streams and the Lakebase pool before exiting.
    // HTTP connections are cleaned up by process.exit — AppKit's server type
    // (Application) doesn't expose .close(), so we skip explicit HTTP close.
    // A 12s safety timeout ensures we exit before the platform kills at 15s.
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

      // 1. Close ZeroBus streams (drain in-flight events)
      try {
        await shutdownZerobus();
        console.log('[shutdown] ZeroBus streams closed.');
      } catch (err) {
        console.error('[shutdown] ZeroBus shutdown error:', err);
      }

      // 2. Close Lakebase pool (drain in-flight queries)
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
