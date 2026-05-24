/**
 * Media streaming routes — browser-authenticated, App-proxied from UC Volumes.
 *
 * Provides read access to uploaded files for the browser UI (Phase 3: Media Viewer).
 * Files are streamed from UC Volumes via the Databricks Files REST API with full
 * HTTP Range request support (needed for audio seeking).
 *
 * Endpoints:
 *   GET /api/media/:upload_id          — Stream file content (supports Range)
 *   GET /api/media/:upload_id/metadata — Upload metadata from Lakebase
 *
 * Auth: browserAuth (on-behalf-of-user) — these are browser-only endpoints.
 * iOS downloads files via capture session sync, not this endpoint.
 *
 * Volume path resolution:
 *   1. Look up upload record in app.uploads (gets volume_path, mime_type, size_bytes)
 *   2. Strip the /Volumes/{catalog}/{schema}/{volume}/ prefix to get the relative path
 *   3. Use AppKit files plugin download route OR direct SDK Files API
 *
 * Range request handling:
 *   - Supports single-range requests (bytes=START-END)
 *   - Returns 206 Partial Content with Content-Range header
 *   - Essential for audio <audio> element seeking
 */

import type { Application, Request, Response, NextFunction } from 'express';
import { dualAuth } from '../../middleware/browser-auth';
import { AppError, ErrorTypes } from '../../lib/errors';

// ── Interfaces ─────────────────────────────────────────────────────────────────

interface LakebaseClient {
  query(text: string, params?: unknown[]): Promise<{ rows: Record<string, unknown>[] }>;
}

interface AppKitContext {
  lakebase: LakebaseClient;
  server: { extend(fn: (app: Application) => void): void };
}

// ── Volume key mapping ─────────────────────────────────────────────────────────
// Maps upload `kind` to the AppKit files plugin volume key (matches server.ts config)

const KIND_TO_VOLUME_KEY: Record<string, string> = {
  audio: 'session_audio',
  screenshot: 'screenshots',
  photo: 'screenshots',
  document: 'documents',
};

// ── Helpers ────────────────────────────────────────────────────────────────────

function uploadNotFound(uploadId: string): AppError {
  return new AppError({
    type: ErrorTypes.VALIDATION_ERROR,
    status: 404,
    title: 'Upload not found',
    detail: `No upload found with id '${uploadId}'.`,
  });
}

/**
 * Parse a Range header value like "bytes=0-1023" or "bytes=1024-".
 * Returns { start, end } where end may be undefined (open-ended range).
 */
function parseRangeHeader(rangeHeader: string, fileSize: number): { start: number; end: number } | null {
  const match = rangeHeader.match(/^bytes=(\d+)-(\d*)$/);
  if (!match) return null;

  const start = parseInt(match[1], 10);
  const end = match[2] ? parseInt(match[2], 10) : fileSize - 1;

  if (start >= fileSize || start > end) return null;
  return { start, end: Math.min(end, fileSize - 1) };
}

/**
 * Extract the relative path within the volume from the full volume_path.
 * e.g., "/Volumes/hls_fde_dev/dev_matthew_giglia_lakeloom/session_audio/proj/cap/file.m4a"
 *     → "proj/cap/file.m4a"
 *
 * The volume base path is /Volumes/{catalog}/{schema}/{volume}/
 * so we strip the first 4 path segments.
 */
function getRelativePath(volumePath: string): string {
  const parts = volumePath.split('/').filter(Boolean);
  if (parts.length <= 4) {
    throw new Error(`Invalid volume path (too short): ${volumePath}`);
  }
  return parts.slice(4).join('/');
}

// ── Route setup ────────────────────────────────────────────────────────────────

export async function setupMediaRoutes(appkit: AppKitContext): Promise<void> {
  const { lakebase } = appkit;
  const auth = dualAuth({ lakebase });

  appkit.server.extend((app) => {

    // ── GET /api/media/:upload_id/metadata ───────────────────────────────
    // Returns upload metadata (no file content).
    app.get('/api/media/:upload_id/metadata', auth, async (req: Request, res: Response, next: NextFunction) => {
      try {
        const uploadId = req.params.upload_id as string;

        const { rows } = await lakebase.query(
          `SELECT id, capture_session_id, kind, mime_type, original_filename,
                  volume_path, size_bytes, sha256_hex, device_id, client_type,
                  created_by_paired_session_id, created_by_user_id, uploaded_at
           FROM app.uploads
           WHERE id = $1`,
          [uploadId],
        );

        if (rows.length === 0) {
          throw uploadNotFound(uploadId);
        }

        const upload = rows[0];
        res.json({
          id: upload.id,
          capture_session_id: upload.capture_session_id,
          kind: upload.kind,
          mime_type: upload.mime_type,
          original_filename: upload.original_filename,
          size_bytes: upload.size_bytes,
          sha256_hex: upload.sha256_hex,
          device_id: upload.device_id,
          client_type: upload.client_type,
          uploaded_at: upload.uploaded_at,
        });
      } catch (err) {
        next(err);
      }
    });

    // ── GET /api/media/:upload_id ────────────────────────────────────────
    // Stream file content from UC Volume. Supports HTTP Range requests.
    app.get('/api/media/:upload_id', auth, async (req: Request, res: Response, next: NextFunction) => {
      try {
        const uploadId = req.params.upload_id as string;

        // 1. Look up upload record
        const { rows } = await lakebase.query(
          `SELECT id, kind, mime_type, original_filename, volume_path, size_bytes
           FROM app.uploads
           WHERE id = $1`,
          [uploadId],
        );

        if (rows.length === 0) {
          throw uploadNotFound(uploadId);
        }

        const upload = rows[0];
        const volumePath = upload.volume_path as string;
        const mimeType = upload.mime_type as string;
        const sizeBytes = upload.size_bytes as number;
        const originalFilename = (upload.original_filename as string) || String(uploadId);
        const kind = upload.kind as string;
        const volumeKey = KIND_TO_VOLUME_KEY[kind];

        if (!volumeKey) {
          throw new AppError({
            type: ErrorTypes.INTERNAL_ERROR,
            status: 500,
            title: 'Unknown upload kind',
            detail: `Upload kind '${kind}' has no associated volume.`,
          });
        }

        // 2. Determine the relative path within the volume
        const relativePath = getRelativePath(volumePath);

        // 3. Build the internal AppKit files download URL
        const downloadUrl = `/api/files/${volumeKey}/download?path=${encodeURIComponent(relativePath)}`;

        // 4. Handle Range requests
        const rangeHeader = req.headers.range;

        // Set common headers
        res.setHeader('Accept-Ranges', 'bytes');
        res.setHeader('Content-Type', mimeType);
        res.setHeader('Content-Disposition', `inline; filename="${originalFilename}"`);
        res.setHeader('Cache-Control', 'private, max-age=3600');

        if (rangeHeader && sizeBytes > 0) {
          // Parse range
          const range = parseRangeHeader(rangeHeader, sizeBytes);
          if (!range) {
            res.status(416).setHeader('Content-Range', `bytes */${sizeBytes}`).end();
            return;
          }

          const port = process.env.PORT || '8000';
          // For range requests, we proxy via internal fetch with Range header
          const internalResponse = await fetch(`http://localhost:${port}${downloadUrl}`, {
            headers: {
              'Range': `bytes=${range.start}-${range.end}`,
              ...(req.headers['x-forwarded-user'] ? { 'x-forwarded-user': req.headers['x-forwarded-user'] as string } : {}),
              ...(req.headers['x-forwarded-email'] ? { 'x-forwarded-email': req.headers['x-forwarded-email'] as string } : {}),
              ...(req.headers.cookie ? { cookie: req.headers.cookie as string } : {}),
            },
          });

          if (!internalResponse.ok && internalResponse.status !== 206) {
            console.warn('[media] Range proxy failed (' + internalResponse.status + '), falling back to full stream');
          }

          const contentLength = range.end - range.start + 1;
          res.status(206);
          res.setHeader('Content-Range', `bytes ${range.start}-${range.end}/${sizeBytes}`);
          res.setHeader('Content-Length', contentLength.toString());

          if (internalResponse.body) {
            const reader = internalResponse.body.getReader();
            const pump = async () => {
              while (true) {
                const { done, value } = await reader.read();
                if (done) break;
                if (!res.write(value)) {
                  await new Promise<void>((resolve) => res.once('drain', resolve));
                }
              }
              res.end();
            };
            pump().catch((err) => {
              console.error('[media] Stream pump error:', err);
              if (!res.headersSent) res.status(500).end();
              else res.destroy();
            });
          } else {
            res.end();
          }
        } else {
          // Full file — proxy without Range header
          res.setHeader('Content-Length', sizeBytes.toString());

          const port = process.env.PORT || '8000';
          const internalResponse = await fetch(`http://localhost:${port}${downloadUrl}`, {
            headers: {
              ...(req.headers['x-forwarded-user'] ? { 'x-forwarded-user': req.headers['x-forwarded-user'] as string } : {}),
              ...(req.headers['x-forwarded-email'] ? { 'x-forwarded-email': req.headers['x-forwarded-email'] as string } : {}),
              ...(req.headers.cookie ? { cookie: req.headers.cookie as string } : {}),
            },
          });

          if (!internalResponse.ok) {
            throw new AppError({
              type: ErrorTypes.INTERNAL_ERROR,
              status: 502,
              title: 'Volume read failed',
              detail: `Failed to read file from volume (HTTP ${internalResponse.status}).`,
            });
          }

          if (internalResponse.body) {
            const reader = internalResponse.body.getReader();
            const pump = async () => {
              while (true) {
                const { done, value } = await reader.read();
                if (done) break;
                if (!res.write(value)) {
                  await new Promise<void>((resolve) => res.once('drain', resolve));
                }
              }
              res.end();
            };
            pump().catch((err) => {
              console.error('[media] Stream pump error:', err);
              if (!res.headersSent) res.status(500).end();
              else res.destroy();
            });
          } else {
            res.end();
          }
        }
      } catch (err) {
        next(err);
      }
    });

    // ── GET /api/media/session/:capture_session_id ───────────────────────
    // List all uploads for a capture session (used by media panel).
    app.get('/api/media/session/:capture_session_id', auth, async (req: Request, res: Response, next: NextFunction) => {
      try {
        const captureSessionId = req.params.capture_session_id as string;

        const { rows } = await lakebase.query(
          `SELECT id, kind, mime_type, original_filename, size_bytes, uploaded_at
           FROM app.uploads
           WHERE capture_session_id = $1
           ORDER BY uploaded_at ASC`,
          [captureSessionId],
        );

        res.json({ uploads: rows });
      } catch (err) {
        next(err);
      }
    });

  });
}
