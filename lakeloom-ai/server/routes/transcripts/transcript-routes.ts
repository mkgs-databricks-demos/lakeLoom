/**
 * Transcript routes — historical transcript retrieval, live streaming, and search.
 *
 * Endpoints:
 *   GET  /api/captures/:id/transcript        — Historical transcript segments from bronze
 *   GET  /api/captures/:id/transcript/stream  — SSE for live transcripts during active capture
 *   GET  /api/projects/:id/search             — Full-text search across project transcripts
 */

import type { Application, Request, Response } from 'express';
import { executeStatement } from '../../services/sql-service';

// ── Interfaces ─────────────────────────────────────────────────────────────────

interface LakebaseClient {
  query(text: string, params?: unknown[]): Promise<{ rows: Record<string, unknown>[] }>;
}

interface AppKitContext {
  lakebase: LakebaseClient;
  server: { extend(fn: (app: Application) => void): void };
}

// ── In-memory transcript relay ─────────────────────────────────────────────────

type TranscriptListener = (event: TranscriptEvent) => void;

interface TranscriptEvent {
  event_id: string;
  event_time: string;
  text: string;
  language: string;
  confidence: number | null;
  segment_index: number | null;
  duration_ms: number | null;
  model: string | null;
}

const sessionListeners = new Map<string, Set<TranscriptListener>>();

/**
 * Push a transcript event to all connected SSE clients watching this session.
 * Called from the ingest route when a final_transcript event passes through.
 */
export function pushTranscriptEvent(sessionId: string, event: TranscriptEvent): void {
  const listeners = sessionListeners.get(sessionId);
  if (listeners && listeners.size > 0) {
    for (const listener of listeners) {
      try { listener(event); } catch { /* noop */ }
    }
  }
}

function addTranscriptListener(sessionId: string, listener: TranscriptListener): void {
  if (!sessionListeners.has(sessionId)) {
    sessionListeners.set(sessionId, new Set());
  }
  sessionListeners.get(sessionId)!.add(listener);
}

function removeTranscriptListener(sessionId: string, listener: TranscriptListener): void {
  const listeners = sessionListeners.get(sessionId);
  if (listeners) {
    listeners.delete(listener);
    if (listeners.size === 0) {
      sessionListeners.delete(sessionId);
    }
  }
}

// ── Catalog/Schema resolution ──────────────────────────────────────────────────

function getBronzeTable(): string {
  // Resolve from env (same catalog.schema used for OTel tables)
  const catalog = process.env.LAKELOOM_UC_CATALOG ?? 'hls_fde_dev';
  const schema = process.env.LAKELOOM_UC_SCHEMA ?? 'dev_matthew_giglia_lakeloom';
  return `${catalog}.${schema}.transcript_events_raw`;
}

// ── Route setup ────────────────────────────────────────────────────────────────

export async function setupTranscriptRoutes(appkit: AppKitContext): Promise<void> {
  const { lakebase } = appkit;

  appkit.server.extend((app) => {

    // ── GET /api/captures/:id/transcript ──────────────────────────────────
    // Returns all transcript segments for a capture session, ordered by time.
    app.get('/api/captures/:id/transcript', async (req: Request, res: Response, next) => {
      try {
        const captureSessionId = req.params.id;

        // Verify capture session exists and get its paired_session_id
        const { rows: captureRows } = await lakebase.query(
          `SELECT id, created_by_paired_session_id, state, started_at
           FROM app.capture_sessions WHERE id = $1`,
          [captureSessionId],
        );

        if (captureRows.length === 0) {
          res.status(404).json({ error: 'Capture session not found' });
          return;
        }

        const capture = captureRows[0];
        const sessionId = capture.created_by_paired_session_id as string;
        const table = getBronzeTable();

        // Query bronze table via SQL warehouse
        const result = await executeStatement(`
          SELECT
            event_id,
            event_time,
            transcript_text,
            transcript_language,
            body:confidence::double AS confidence,
            body:segment_index::int AS segment_index,
            body:duration_ms::int AS duration_ms,
            body:model::string AS model,
            body:source::string AS source
          FROM ${table}
          WHERE session_id = :session_id
            AND event_type = 'final_transcript'
          ORDER BY event_time ASC, body:segment_index::int ASC
        `, [
          { name: 'session_id', value: sessionId },
        ]);

        // Build response
        const segments = result.rows.map((row) => ({
          event_id: row.event_id,
          event_time: row.event_time,
          text: row.transcript_text,
          language: row.transcript_language ?? 'en-US',
          confidence: row.confidence ? parseFloat(row.confidence) : null,
          segment_index: row.segment_index ? parseInt(row.segment_index) : null,
          duration_ms: row.duration_ms ? parseInt(row.duration_ms) : null,
          model: row.model,
        }));

        // Compute total duration from segments
        const totalDurationMs = segments.reduce((sum, s) => sum + (s.duration_ms ?? 0), 0);

        res.json({
          capture_session_id: captureSessionId,
          session_id: sessionId,
          started_at: capture.started_at,
          state: capture.state,
          segments,
          total_segments: segments.length,
          total_duration_ms: totalDurationMs,
          language: segments[0]?.language ?? 'en-US',
        });
      } catch (err) {
        next(err);
      }
    });

    // ── GET /api/captures/:id/transcript/stream ──────────────────────────
    // SSE endpoint for live transcript events during active capture.
    app.get('/api/captures/:id/transcript/stream', async (req: Request, res: Response) => {
      try {
        const captureSessionId = req.params.id;

        // Verify capture session exists
        const { rows: captureRows } = await lakebase.query(
          `SELECT id, created_by_paired_session_id, state
           FROM app.capture_sessions WHERE id = $1`,
          [captureSessionId],
        );

        if (captureRows.length === 0) {
          res.status(404).json({ error: 'Capture session not found' });
          return;
        }

        const sessionId = captureRows[0].created_by_paired_session_id as string;

        // Set up SSE
        res.setHeader('Content-Type', 'text/event-stream');
        res.setHeader('Cache-Control', 'no-cache');
        res.setHeader('Connection', 'keep-alive');
        res.setHeader('X-Accel-Buffering', 'no');
        res.flushHeaders();

        res.write(': connected\n\n');

        // Subscribe to in-memory relay
        const listener: TranscriptListener = (event) => {
          res.write(`event: transcript\ndata: ${JSON.stringify(event)}\n\n`);
        };

        addTranscriptListener(sessionId, listener);

        // Keepalive
        const keepalive = setInterval(() => {
          res.write(': keepalive\n\n');
        }, 30_000);

        // Cleanup on disconnect
        req.on('close', () => {
          clearInterval(keepalive);
          removeTranscriptListener(sessionId, listener);
        });
      } catch (err) {
        console.error('[transcript/stream] error:', err);
        if (!res.headersSent) {
          res.status(500).json({ error: 'Internal error' });
        }
      }
    });

    // ── GET /api/projects/:id/search ─────────────────────────────────────
    // Full-text search across all transcripts for a project.
    app.get('/api/projects/:id/search', async (req: Request, res: Response, next) => {
      try {
        const projectId = req.params.id;
        const query = (req.query.q as string ?? '').trim();

        if (!query) {
          res.status(400).json({ error: 'Query parameter "q" is required' });
          return;
        }

        const table = getBronzeTable();

        const result = await executeStatement(`
          SELECT
            session_id,
            event_id,
            event_time,
            transcript_text,
            body:segment_index::int AS segment_index
          FROM ${table}
          WHERE project_id = :project_id
            AND event_type = 'final_transcript'
            AND LOWER(transcript_text) LIKE LOWER(CONCAT('%', :search_term, '%'))
          ORDER BY event_time DESC
          LIMIT 50
        `, [
          { name: 'project_id', value: projectId },
          { name: 'search_term', value: query },
        ]);

        // Enrich with capture session info from Lakebase
        const sessionIds = [...new Set(result.rows.map((r) => r.session_id))];
        let sessionMap: Record<string, { id: string; label: string; started_at: string }> = {};

        if (sessionIds.length > 0) {
          const placeholders = sessionIds.map((_, i) => `$${i + 1}`).join(',');
          const { rows: sessions } = await lakebase.query(
            `SELECT id, created_by_paired_session_id, label, started_at
             FROM app.capture_sessions
             WHERE created_by_paired_session_id IN (${placeholders})`,
            sessionIds,
          );
          for (const s of sessions) {
            sessionMap[s.created_by_paired_session_id as string] = {
              id: s.id as string,
              label: (s.label as string) ?? 'Untitled',
              started_at: s.started_at as string,
            };
          }
        }

        const results = result.rows.map((row) => ({
          session_id: row.session_id,
          capture: sessionMap[row.session_id!] ?? null,
          event_id: row.event_id,
          event_time: row.event_time,
          text: row.transcript_text,
          segment_index: row.segment_index ? parseInt(row.segment_index) : null,
        }));

        res.json({
          query,
          project_id: projectId,
          results,
          total_results: results.length,
        });
      } catch (err) {
        next(err);
      }
    });
  });
}
