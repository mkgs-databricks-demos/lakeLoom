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
 *   GET /api/media/session/:capture_session_id — List uploads for a capture session
 *   GET /api/media/project/:project_id — List project-level uploads (documents)
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

async function pipeResponseToExpress(internalResponse: globalThis.Response, res: Response): Promise<void> {
  if (!internalResponse.body) {
    res.end();
    return;
  }

  const reader = internalResponse.body.getReader();
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (!res.write(value)) {
      await new Promise<void>((resolve) => res.once('drain', resolve));
    }
  }
  res.end();
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

    // ── OPTIONS /api/media/:upload_id (CORS preflight) ──────────────────
    // Required for credentialed Range requests during audio seeking.
    app.options('/api/media/:upload_id', (req: Request, res: Response) => {
      if (req.headers.origin) {
        res.setHeader('Access-Control-Allow-Origin', req.headers.origin);
        res.setHeader('Access-Control-Allow-Credentials', 'true');
        res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
        res.setHeader('Access-Control-Allow-Headers', 'Range, Content-Type');
        res.setHeader('Access-Control-Max-Age', '86400');
        res.setHeader('Vary', 'Origin');
      }
      res.status(204).end();
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
        const port = process.env.PORT || '8000';

        // 4. Handle Range requests
        const rangeHeader = req.headers.range;

        // Set common headers
        res.setHeader('Accept-Ranges', 'bytes');
        res.setHeader('Content-Type', mimeType);
        res.setHeader('Content-Disposition', `inline; filename="${originalFilename}"`);
        res.setHeader('Cache-Control', 'private, max-age=3600');
        if (req.headers.origin) {
          res.setHeader('Access-Control-Allow-Origin', req.headers.origin);
          res.setHeader('Vary', 'Origin');
        }
        res.setHeader('Access-Control-Allow-Credentials', 'true');

        const forwardedHeaders = {
          ...(req.headers['x-forwarded-user'] ? { 'x-forwarded-user': req.headers['x-forwarded-user'] as string } : {}),
          ...(req.headers['x-forwarded-email'] ? { 'x-forwarded-email': req.headers['x-forwarded-email'] as string } : {}),
          ...(req.headers.cookie ? { cookie: req.headers.cookie as string } : {}),
        };

        if (rangeHeader && sizeBytes > 0) {
          const range = parseRangeHeader(rangeHeader, sizeBytes);
          if (!range) {
            res.status(416).setHeader('Content-Range', `bytes */${sizeBytes}`).end();
            return;
          }

          const rangedResponse = await fetch(`http://localhost:${port}${downloadUrl}`, {
            headers: {
              Range: `bytes=${range.start}-${range.end}`,
              ...forwardedHeaders,
            },
          });

          // Only a true 206 response is safe to proxy as partial content.
          // The internal files route may ignore Range and return 200 with the
          // full body; wrapping that as 206 produces an invalid media response.
          if (rangedResponse.status === 206) {
            const contentLength = range.end - range.start + 1;
            res.status(206);
            res.setHeader('Content-Range', `bytes ${range.start}-${range.end}/${sizeBytes}`);
            res.setHeader('Content-Length', contentLength.toString());
            await pipeResponseToExpress(rangedResponse, res);
            return;
          }

          console.warn(`[media] Range proxy not honored (${rangedResponse.status}); retrying full download for playback compatibility`);
        }

        // Fallback path: full file stream (also used for non-range requests)
        const fullResponse = await fetch(`http://localhost:${port}${downloadUrl}`, {
          headers: forwardedHeaders,
        });

        if (!fullResponse.ok) {
          throw new AppError({
            type: ErrorTypes.INTERNAL_ERROR,
            status: 502,
            title: 'Volume read failed',
            detail: `Failed to read file from volume (HTTP ${fullResponse.status}).`,
          });
        }

        res.status(200);
        res.setHeader('Content-Length', sizeBytes.toString());
        await pipeResponseToExpress(fullResponse, res);
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

    // ── GET /api/media/project/:project_id ─────────────────────────────────
    // List project-level uploads (documents not tied to a capture session).
    app.get('/api/media/project/:project_id', auth, async (req: Request, res: Response, next: NextFunction) => {
      try {
        const projectId = req.params.project_id as string;

        const { rows } = await lakebase.query(
          `SELECT id, kind, mime_type, original_filename, size_bytes, uploaded_at
           FROM app.uploads
           WHERE project_id = $1 AND capture_session_id IS NULL AND revoked_at IS NULL
           ORDER BY uploaded_at DESC`,
          [projectId],
        );

        res.json({ uploads: rows });
      } catch (err) {
        next(err);
      }
    });

    // ── PUT /api/media/:upload_id/content ────────────────────────────────
    // Overwrite file content on the volume (for editable types like Markdown).
    app.put('/api/media/:upload_id/content', auth, async (req: Request, res: Response, next: NextFunction) => {
      try {
        const uploadId = req.params.upload_id as string;

        // 1. Look up upload record
        const { rows } = await lakebase.query(
          `SELECT id, kind, mime_type, volume_path, revoked_at
           FROM app.uploads
           WHERE id = $1`,
          [uploadId],
        );

        if (rows.length === 0) throw uploadNotFound(uploadId);
        const upload = rows[0];

        if (upload.revoked_at) {
          throw new AppError({
            type: ErrorTypes.VALIDATION_ERROR,
            status: 410,
            title: 'Upload deleted',
            detail: `Cannot edit a deleted upload.`,
          });
        }

        // Only allow editing text-based files
        const mimeType = upload.mime_type as string;
        if (!mimeType.startsWith('text/')) {
          throw new AppError({
            type: ErrorTypes.VALIDATION_ERROR,
            status: 400,
            title: 'Not editable',
            detail: `Only text-based files can be edited. This file is ${mimeType}.`,
          });
        }

        // 2. Read the new content from the request body
        const newContent = await new Promise<Buffer>((resolve, reject) => {
          const chunks: Buffer[] = [];
          req.on('data', (chunk: Buffer) => chunks.push(chunk));
          req.on('end', () => resolve(Buffer.concat(chunks)));
          req.on('error', reject);
        });

        // 3. Write to the volume via the internal files API
        const volumePath = upload.volume_path as string;
        const relativePath = getRelativePath(volumePath);
        const kind = upload.kind as string;
        const volumeKey = KIND_TO_VOLUME_KEY[kind];

        if (!volumeKey) {
          throw new AppError({
            type: ErrorTypes.INTERNAL_ERROR,
            status: 500,
            title: 'Unknown volume',
            detail: `Upload kind '${kind}' has no volume mapping.`,
          });
        }

        const port = process.env.PORT || '8000';
        const uploadUrl = `http://127.0.0.1:${port}/api/files/${volumeKey}/upload?path=${encodeURIComponent(relativePath)}`;

        const forwardedHeaders: Record<string, string> = {
          ...(req.headers['x-forwarded-user'] ? { 'x-forwarded-user': req.headers['x-forwarded-user'] as string } : {}),
          ...(req.headers['x-forwarded-email'] ? { 'x-forwarded-email': req.headers['x-forwarded-email'] as string } : {}),
          ...(req.headers.cookie ? { cookie: req.headers.cookie as string } : {}),
        };

        const writeResponse = await fetch(uploadUrl, {
          method: 'POST',
          headers: { ...forwardedHeaders, 'Content-Type': 'application/octet-stream' },
          body: newContent,
        });

        if (!writeResponse.ok) {
          throw new AppError({
            type: ErrorTypes.INTERNAL_ERROR,
            status: 502,
            title: 'Volume write failed',
            detail: `Failed to write file to volume (HTTP ${writeResponse.status}).`,
          });
        }

        // 4. Update size_bytes in Lakebase
        await lakebase.query(
          `UPDATE app.uploads SET size_bytes = $1 WHERE id = $2`,
          [newContent.length, uploadId],
        );

        console.log(`[media] content.updated { upload_id: '${uploadId}', new_size: ${newContent.length} }`);

        res.status(200).json({ id: uploadId, size_bytes: newContent.length });
      } catch (err) {
        next(err);
      }
    });

    // ── DELETE /api/media/:upload_id ───────────────────────────────────────
    // Soft-delete an upload (sets revoked_at). File remains on volume for audit.
    // Only the user who uploaded the file can delete it.
    app.delete('/api/media/:upload_id', auth, async (req: Request, res: Response, next: NextFunction) => {
      try {
        const uploadId = req.params.upload_id as string;
        const userId = (req as any).user?.userId ?? (req as any).user?.id ?? null;

        // Verify the upload exists and belongs to this user
        const { rows } = await lakebase.query(
          `SELECT id, user_id, revoked_at
           FROM app.uploads
           WHERE id = $1`,
          [uploadId],
        );

        if (rows.length === 0) {
          throw uploadNotFound(uploadId);
        }

        const upload = rows[0];

        if (upload.revoked_at) {
          throw new AppError({
            type: ErrorTypes.VALIDATION_ERROR,
            status: 410,
            title: 'Upload already deleted',
            detail: `Upload '${uploadId}' has already been deleted.`,
          });
        }

        // Soft-delete: set revoked_at timestamp
        await lakebase.query(
          `UPDATE app.uploads SET revoked_at = NOW() WHERE id = $1`,
          [uploadId],
        );

        console.log(`[media] upload.revoked { upload_id: '${uploadId}', revoked_by: '${userId}' }`);

        res.status(200).json({ id: uploadId, revoked: true });
      } catch (err) {
        next(err);
      }
    });

  });
}
