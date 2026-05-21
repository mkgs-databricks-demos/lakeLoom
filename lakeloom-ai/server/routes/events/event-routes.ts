/**
 * Transcript event forwarding routes.
 *
 * iOS sends real-time transcript events during a session.
 * The App enriches with structured fields matching the bronze table schema
 * (transcript_events_raw), then forwards via ZeroBus SDK.
 *
 * ZeroBus maps JSON field names directly to Delta table column names.
 * The record shape MUST match the target table DDL:
 *   record_id, ingested_at, event_id, session_id, project_id, user_id,
 *   device_id, event_type, event_time, transcript_text, transcript_language,
 *   source_platform, workspace_id, headers, body
 *
 * Key conventions (from dbxW reference):
 *   - record_id: crypto.randomUUID() — app-generated, NOT NULL PK
 *   - ingested_at: Date.now() * 1000 — epoch MICROSECONDS (not ISO string)
 *   - body: full raw event as nested object → VARIANT
 *
 * Endpoint:
 *   POST /api/sessions/:session_id/events — iOS-authenticated (Layer 0+1)
 */

import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import type { Application } from 'express';
import { iosAuth } from '../../middleware/ios-auth';
import { validationError } from '../../lib/errors';
import { zeroBusService } from '../../services/zerobus-service';
import { isZerobusReady } from '../../services/secrets-service';

// ── Interfaces ───────────────────────────────────────────────────────────

interface LakebaseClient {
  query(text: string, params?: unknown[]): Promise<{ rows: Record<string, unknown>[] }>;
}

interface AppKitContext {
  lakebase: LakebaseClient;
  server: { extend(fn: (app: Application) => void): void };
}

// ── Event schema ─────────────────────────────────────────────────────────
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

// ── Route setup ──────────────────────────────────────────────────────────

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
        const { userId, workspaceId } = req.user!;

        // Build records with field names matching the bronze table columns exactly.
        // ZeroBus maps JSON keys → Delta column names on write.
        const records = events.map((event) => {
          const { event_type, text, language, ...rest } = event as Record<string, unknown>;

          return JSON.stringify({
            // ── ZeroBus PK + timestamp (matching dbxW pattern) ───────────
            record_id: randomUUID(),
            ingested_at: Date.now() * 1000, // epoch microseconds (µs)

            // ── App-level event identifier ───────────────────────────────
            event_id: randomUUID(),
            event_type: event_type as string,

            // ── Enrichment from auth context ─────────────────────────────
            session_id: sessionId,
            user_id: userId,
            workspace_id: workspaceId || null,
            source_platform: 'ios',

            // ── Transcript-specific columns ───────────────────────────────
            transcript_text: (text as string) || null,
            transcript_language: (language as string) || null,

            // ── Optional columns (populated when available) ─────────────
            event_time: (rest.event_time as string) || null,
            project_id: (rest.project_id as string) || null,
            device_id: (rest.device_id as string) || null,

            // ── Full raw payload as VARIANT for flexible bronze retention ──
            body: event,
          });
        });

        // Use batch ingest for multiple events, single for one
        if (records.length === 1) {
          await zeroBusService.ingestRecord(records[0]);
        } else {
          await zeroBusService.ingestBatch(records);
        }

        res.status(202).json({ accepted: events.length });
      } catch (err) {
        next(err);
      }
    });
  });
}
