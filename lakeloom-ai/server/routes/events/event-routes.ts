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
 *   device_id, event_type, event_time, transcript_text,
 *   transcript_language, source_platform, workspace_id, headers, body
 *
 * CRITICAL: Pass plain objects to ingestRecordOffset(), NOT JSON strings.
 * The SDK serializes internally. Passing JSON.stringify()'d strings causes
 * double-encoding and schema validation failures on the server side.
 *
 * Key conventions (from dbxW reference):
 *   - record_id: crypto.randomUUID() -- app-generated, NOT NULL PK
 *   - ingested_at: Date.now() * 1000 -- epoch MICROSECONDS (not ISO string)
 *   - event_time: epoch MICROSECONDS (converted from ISO 8601 client timestamp)
 *   - body: JSON.stringify(event) -- VARIANT column (string-encoded JSON)
 *
 * Endpoint:
 *   POST /api/sessions/:session_id/events -- iOS-authenticated (Layer 0+1)
 */

import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import type { Application } from 'express';
import { iosAuth } from '../../middleware/ios-auth';
import { validationError } from '../../lib/errors';
import { zeroBusService } from '../../services/zerobus-service';
import { pushTranscriptEvent } from '../transcripts/transcript-routes';
import { isZerobusReady } from '../../services/secrets-service';

// -- Interfaces ---------------------------------------------------------------

interface LakebaseClient {
  query(text: string, params?: unknown[]): Promise<{ rows: Record<string, unknown>[] }>;
}

interface AppKitContext {
  lakebase: LakebaseClient;
  server: { extend(fn: (app: Application) => void): void };
}

// -- Event schema -------------------------------------------------------------
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

// -- Helpers ------------------------------------------------------------------

/**
 * Convert an ISO 8601 timestamp string to epoch microseconds.
 * Returns null if the input is falsy or unparseable.
 * Matches the ingested_at convention (Date.now() * 1000).
 */
function isoToEpochMicros(iso: unknown): number | null {
  if (!iso || typeof iso !== 'string') return null;
  const ms = new Date(iso).getTime();
  if (Number.isNaN(ms)) return null;
  return ms * 1000;
}

// -- Route setup --------------------------------------------------------------

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

        // Build records as PLAIN OBJECTS -- the SDK serializes internally.
        // Passing JSON.stringify()'d strings causes double-encoding and
        // server-side schema validation failures (data never materializes).
        const records = events.map((event) => {
          const { event_type, text, language, ...rest } = event as Record<string, unknown>;

          return {
            // -- ZeroBus PK + timestamp (matching dbxW pattern) -----------
            record_id: randomUUID(),
            ingested_at: Date.now() * 1000, // epoch microseconds

            // -- App-level event identifier -------------------------------
            event_id: randomUUID(),
            event_type: event_type as string,

            // -- Enrichment from auth context -----------------------------
            session_id: sessionId,
            user_id: userId,
            workspace_id: workspaceId || null,
            source_platform: 'ios',

            // -- Transcript-specific columns ------------------------------
            transcript_text: (text as string) || null,
            transcript_language: (language as string) || null,

            // -- iOS-enriched columns (populated when iOS sends them) -----
            // project_id: active project UUID from coordinator state
            // device_id:  stable keychain-persisted UUID (physical device)
            //             device_label lives in paired_sessions only (single
            //             source of truth); join on device_id to resolve.
            // event_time: client-side STT segment timestamp (epoch us)
            project_id: (rest.project_id as string) || null,
            device_id: (rest.device_id as string) || null,
            event_time: isoToEpochMicros(rest.event_time),

            // -- Request metadata (for diagnostics and observability) -----
            headers: JSON.stringify({
              content_type: req.headers['content-type'] || null,
              user_agent: req.headers['user-agent'] || null,
              x_lakeloom_timestamp: req.headers['x-lakeloom-timestamp'] || null,
            }),

            // -- Full raw payload as VARIANT (string-encoded JSON) ---------
            body: JSON.stringify(event),
          };
        });

        // Use batch ingest for multiple events, single for one.
        // Pass the object directly -- the service's ingestRecord() passes it
        // through to stream.ingestRecordOffset() which handles serialization.
        if (records.length === 1) {
          await zeroBusService.ingestRecord(records[0]);
        } else {
          await zeroBusService.ingestBatch(records);
        }

        // ── Relay transcript events to connected SSE clients ──────────────
        for (const record of records) {
          if (record.event_type === 'final_transcript' && record.session_id) {
            const rawBody = typeof record.body === 'string' ? JSON.parse(record.body) : record.body;
            pushTranscriptEvent(record.session_id as string, {
              event_id: record.event_id,
              event_time: record.event_time ? new Date(record.event_time / 1000).toISOString() : new Date().toISOString(),
              text: record.transcript_text || '',
              language: record.transcript_language || 'en-US',
              confidence: rawBody?.confidence ?? null,
              segment_index: rawBody?.segment_index ?? null,
              duration_ms: rawBody?.duration_ms ?? null,
              model: rawBody?.model ?? null,
            });
          }
        }

        res.status(202).json({ accepted: events.length });
      } catch (err) {
        next(err);
      }
    });
  });
}
