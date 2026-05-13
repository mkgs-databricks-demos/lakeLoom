/**
 * Transcript event forwarding routes.
 *
 * iOS sends real-time transcript events during a session.
 * The App enriches with user_id, session metadata, and server timestamp,
 * then forwards to the bronze table (transcript_events_raw) via ZeroBus SDK.
 *
 * Endpoint:
 *   POST /api/sessions/:session_id/events — iOS-authenticated (Layer 0+1)
 */

import { z } from 'zod';
import type { Application } from 'express';
import { iosAuth } from '../../middleware/ios-auth';
import { validationError } from '../../lib/errors';
import { ingestRecord } from '../../services/zerobus-service';
import { isZerobusReady } from '../../services/secrets-service';

// ── Interfaces ───────────────────────────────────────────────────────────────

interface LakebaseClient {
  query(text: string, params?: unknown[]): Promise<{ rows: Record<string, unknown>[] }>;
}

interface AppKitContext {
  lakebase: LakebaseClient;
  server: { extend(fn: (app: Application) => void): void };
}

// ── Event schema ─────────────────────────────────────────────────────────────
// Flexible: accept any JSON payload from iOS with at minimum an event_type.
// The bronze table stores raw events; enrichment happens downstream.

const EventBody = z.object({
  event_type: z.string().min(1),
  // Allow any additional fields
}).passthrough();

const EventBatch = z.union([
  EventBody,
  z.array(EventBody).min(1).max(100),
]);

// ── Route setup ──────────────────────────────────────────────────────────────

export async function setupEventRoutes(appkit: AppKitContext): Promise<void> {
  const { lakebase } = appkit;
  const auth = iosAuth({ lakebase });

  appkit.server.extend((app) => {
    app.post('/api/sessions/:session_id/events', auth, async (req, res, next) => {
      try {
        if (!isZerobusReady()) {
          res.status(503).json({
            type: 'https://lakeloom/errors/zerobus_not_ready',
            title: 'Event ingestion not available',
            status: 503,
            detail: 'ZeroBus streaming is not configured. Contact a workspace admin.',
          });
          return;
        }

        const parsed = EventBatch.safeParse(req.body);
        if (!parsed.success) {
          throw validationError('Invalid event payload: ' + parsed.error.issues[0].message);
        }

        const events = Array.isArray(parsed.data) ? parsed.data : [parsed.data];
        const sessionId = req.params.session_id;
        const { userId } = req.user!;
        const serverTs = new Date().toISOString();

        // Enrich and ingest each event
        for (const event of events) {
          const enriched = JSON.stringify({
            ...event,
            _user_id: userId,
            _session_id: sessionId,
            _server_received_at: serverTs,
          });
          await ingestRecord(enriched);
        }

        res.status(202).json({ accepted: events.length });
      } catch (err) {
        next(err);
      }
    });
  });
}
