/**
 * Binary upload routes — iOS-authenticated, App-proxied to UC Volumes.
 *
 * Per ADR-001, all binary uploads route through the App:
 *   iOS → App endpoint (Layer 0+1 auth) → App backend → UC Volume write (App SPN)
 *
 * Endpoints:
 *   POST /api/captures/:capture_session_id/audio        — Session audio recordings
 *   POST /api/captures/:capture_session_id/screenshots  — Session screen captures
 *   POST /api/captures/:capture_session_id/photos       — Camera photos (whiteboards, artifacts)
 *   POST /api/projects/:project_id/documents            — Project reference documents
 *
 * Path layout (project-anchored, UUIDv7 filenames):
 *   audio:       /Volumes/.../session_audio/{project_id}/{capture_session_id}/{uuidv7}.{ext}
 *   screenshots: /Volumes/.../screenshots/{project_id}/{capture_session_id}/{uuidv7}.{ext}
 *   photos:      /Volumes/.../screenshots/{project_id}/{capture_session_id}/{uuidv7}.{ext}
 *   documents:   /Volumes/.../documents/{project_id}/{uuidv7}.{ext}
 *
 * Upload flow (per Isaac's 9-step spec):
 *   1. iosAuth middleware resolves paired_session_id + user_id
 *   2. Validate URL params (capture exists + state='active', or project exists)
 *   3. Parse multipart body (busboy). Reject if file field missing/empty.
 *   4. Generate UUIDv7 → upload_id (also the filename root)
 *   5. Validate MIME against per-endpoint allowlist, derive extension
 *   6. Stream file to UC Volume, compute SHA-256 during stream
 *   7. If iOS sent sha256_hex, compare. Mismatch → 400 + delete file.
 *   8. INSERT INTO app.uploads
 *   9. Return 201 { id, kind, volume_path, size_bytes, sha256_hex, uploaded_at }
 */

import { createHash } from 'node:crypto';
import { Readable } from 'node:stream';
import type { Application, Request, Response, NextFunction } from 'express';
import Busboy from 'busboy';
import { v7 as uuidv7 } from 'uuid';
import { WorkspaceClient } from '@databricks/sdk-experimental';
import { iosAuth } from '../../middleware/ios-auth';
import { validationError } from '../../lib/errors';

// ── Interfaces ───────────────────────────────────────────────────────────────

interface LakebaseClient {
  query(text: string, params?: unknown[]): Promise<{ rows: Record<string, unknown>[] }>;
}

interface AppKitContext {
  lakebase: LakebaseClient;
  server: { extend(fn: (app: Application) => void): void };
}

// ── MIME allowlist ────────────────────────────────────────────────────────────
// Global map: resolves MIME → file extension. Per-endpoint filtering is handled
// by the `allowedMimes` option on each handler (see UploadHandlerOpts).

const MIME_TO_EXT: Record<string, string> = {
  'audio/wav': 'wav',
  'audio/m4a': 'm4a',
  'audio/mp4': 'm4a',
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'application/pdf': 'pdf',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx',
};

// ── Volume paths from environment ────────────────────────────────────────────

function getVolumePath(volumeEnv: string): string {
  const path = process.env[volumeEnv];
  if (!path) {
    throw new Error(`Environment variable ${volumeEnv} is not set.`);
  }
  return path;
}

// ── Multipart parsing helper ─────────────────────────────────────────────────

interface ParsedUpload {
  fileBuffer: Buffer;
  fileMimeType: string;
  clientTs?: string;
  clientFilename?: string;
  clientSha256?: string;
}

function parseMultipart(req: Request): Promise<ParsedUpload> {
  return new Promise((resolve, reject) => {
    const busboy = Busboy({ headers: req.headers });
    const chunks: Buffer[] = [];
    let fileMimeType = '';
    let clientTs: string | undefined;
    let clientFilename: string | undefined;
    let clientSha256: string | undefined;
    let fileReceived = false;

    busboy.on('file', (_fieldname, stream, info) => {
      fileMimeType = info.mimeType;
      fileReceived = true;
      stream.on('data', (chunk: Buffer) => chunks.push(chunk));
      stream.on('error', reject);
    });

    busboy.on('field', (name, value) => {
      switch (name) {
        case 'client_ts':
          clientTs = value;
          break;
        case 'client_filename':
          clientFilename = value;
          break;
        case 'sha256_hex':
          clientSha256 = value.toLowerCase();
          break;
      }
    });

    busboy.on('finish', () => {
      if (!fileReceived || chunks.length === 0) {
        reject(new Error('No file data received.'));
        return;
      }
      resolve({
        fileBuffer: Buffer.concat(chunks),
        fileMimeType,
        clientTs,
        clientFilename,
        clientSha256,
      });
    });

    busboy.on('error', reject);

    // If iosAuth already buffered the raw body (for signature verification on
    // multipart requests), replay it into busboy via a Readable stream.
    // Otherwise, pipe the live request stream as before.
    const rawBody = (req as any)._rawBody as Buffer | undefined;
    if (rawBody) {
      Readable.from(rawBody).pipe(busboy);
    } else {
      req.pipe(busboy);
    }
  });
}

// ── Upload handler factory ───────────────────────────────────────────────────

type UploadKind = 'audio' | 'screenshot' | 'photo' | 'document';

interface UploadHandlerOpts {
  kind: UploadKind;
  volumeEnvVar: string;
  /**
   * Per-endpoint MIME allowlist. Only these MIME types are accepted for this
   * specific endpoint. If omitted, all MIMEs in MIME_TO_EXT are accepted.
   */
  allowedMimes?: string[];
  /**
   * Resolves the project_id and capture_session_id for path construction.
   * For audio/screenshots/photos: looks up the capture to get project_id.
   * For documents: project_id from URL, no capture_session_id.
   */
  resolveContext: (
    req: Request,
    lakebase: LakebaseClient,
  ) => Promise<{ projectId: string; captureSessionId: string | null }>;
}

function createUploadHandler(opts: UploadHandlerOpts, lakebase: LakebaseClient) {
  return async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    let volumeFilePath: string | undefined;
    const wc = new WorkspaceClient({ host: process.env.DATABRICKS_HOST });

    try {
      // ── Step 1: Auth already resolved by iosAuth middleware ───────────────
      const userId = req.user!.userId;
      const pairedSessionId = req.user!.sessionId;

      // ── Step 2: Resolve context (project + capture) ──────────────────────
      const { projectId, captureSessionId } = await opts.resolveContext(req, lakebase);

      // ── Step 3: Parse multipart body ─────────────────────────────────────
      const parsed = await parseMultipart(req);

      // ── Step 4: Generate UUIDv7 ──────────────────────────────────────────
      const uploadId = uuidv7();

      // ── Step 5: Validate MIME + derive extension ─────────────────────────
      // Per-endpoint allowlist check (if configured)
      if (opts.allowedMimes && !opts.allowedMimes.includes(parsed.fileMimeType)) {
        res.status(415).json({
          type: 'https://lakeloom/errors/unsupported_media_type',
          title: 'Unsupported Media Type',
          status: 415,
          detail: `MIME type '${parsed.fileMimeType}' is not accepted by this endpoint. Allowed: ${opts.allowedMimes.join(', ')}.`,
        });
        return;
      }

      const ext = MIME_TO_EXT[parsed.fileMimeType];
      if (!ext) {
        res.status(415).json({
          type: 'https://lakeloom/errors/unsupported_media_type',
          title: 'Unsupported Media Type',
          status: 415,
          detail: `MIME type '${parsed.fileMimeType}' is not in the allowed list.`,
        });
        return;
      }

      // ── Step 6: Compute SHA-256 + write to UC Volume ─────────────────────
      const sha256Hash = createHash('sha256').update(parsed.fileBuffer).digest('hex');

      // Build volume path
      const volumeBase = getVolumePath(opts.volumeEnvVar);
      if (captureSessionId) {
        volumeFilePath = `${volumeBase}/${projectId}/${captureSessionId}/${uploadId}.${ext}`;
      } else {
        volumeFilePath = `${volumeBase}/${projectId}/${uploadId}.${ext}`;
      }

      // Write to UC Volume
      const stream = Readable.toWeb(Readable.from(parsed.fileBuffer)) as ReadableStream;
      await (wc.files as any).upload(volumeFilePath, stream);

      // ── Step 7: SHA-256 verification ─────────────────────────────────────
      if (parsed.clientSha256 && parsed.clientSha256 !== sha256Hash) {
        // Mismatch — delete the file and return 400
        try {
          await (wc.files as any).delete(volumeFilePath);
        } catch (delErr) {
          console.error('[upload] Failed to delete mismatched file:', volumeFilePath, delErr);
        }
        res.status(400).json({
          type: 'https://lakeloom/errors/sha256_mismatch',
          title: 'SHA-256 Mismatch',
          status: 400,
          detail: `Client SHA-256 (${parsed.clientSha256}) does not match computed (${sha256Hash}). File deleted.`,
        });
        return;
      }

      // ── Step 8: INSERT INTO app.uploads ──────────────────────────────────
      try {
        await lakebase.query(
          `INSERT INTO app.uploads
             (id, kind, project_id, capture_session_id, paired_session_id, user_id,
              volume_path, mime_type, size_bytes, sha256_hex, original_filename, client_ts)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)`,
          [
            uploadId,
            opts.kind,
            projectId,
            captureSessionId,
            pairedSessionId,
            userId,
            volumeFilePath,
            parsed.fileMimeType,
            parsed.fileBuffer.length,
            sha256Hash,
            parsed.clientFilename ?? null,
            parsed.clientTs ? new Date(parsed.clientTs).toISOString() : null,
          ],
        );
      } catch (insertErr) {
        // DB insert failed — attempt to clean up the orphan file on the Volume
        try {
          await (wc.files as any).delete(volumeFilePath);
          console.log('[upload] Orphan file deleted:', volumeFilePath);
        } catch (delErr) {
          // Log for out-of-band sweeper
          console.error('[upload] upload.orphan_detected — failed to delete:', volumeFilePath, delErr);
        }
        throw insertErr;
      }

      // ── Step 9: Return 201 ───────────────────────────────────────────────
      res.status(201).json({
        id: uploadId,
        kind: opts.kind,
        volume_path: volumeFilePath,
        size_bytes: parsed.fileBuffer.length,
        sha256_hex: sha256Hash,
        uploaded_at: new Date().toISOString(),
      });
    } catch (err) {
      next(err);
    }
  };
}

// ── Context resolvers ────────────────────────────────────────────────────────

async function resolveCaptureContext(
  req: Request,
  lakebase: LakebaseClient,
): Promise<{ projectId: string; captureSessionId: string | null }> {
  const captureSessionId = req.params.capture_session_id as string;

  // Look up the capture to get project_id and validate state
  const { rows } = await lakebase.query(
    `SELECT project_id, state FROM app.capture_sessions
     WHERE id = $1 AND revoked_at IS NULL`,
    [captureSessionId],
  );

  if (rows.length === 0) {
    throw validationError('Capture session not found.');
  }

  const capture = rows[0];
  if (capture.state !== 'active') {
    throw Object.assign(
      new Error(`Capture session is '${capture.state}'. Uploads only accepted for 'active' captures.`),
      { statusCode: 409 },
    );
  }

  return { projectId: capture.project_id as string, captureSessionId };
}

async function resolveDocumentContext(
  req: Request,
  _lakebase: LakebaseClient,
): Promise<{ projectId: string; captureSessionId: string | null }> {
  const projectId = req.params.project_id as string;
  if (!projectId) {
    throw validationError('project_id is required.');
  }
  // TODO: Validate project exists and user has access (once app.projects table exists)
  return { projectId, captureSessionId: null };
}

// ── Route setup ──────────────────────────────────────────────────────────────

export async function setupUploadRoutes(appkit: AppKitContext): Promise<void> {
  const { lakebase } = appkit;
  const auth = iosAuth({ lakebase });

  appkit.server.extend((app) => {
    // Audio uploads
    app.post(
      '/api/captures/:capture_session_id/audio',
      auth,
      createUploadHandler(
        {
          kind: 'audio',
          volumeEnvVar: 'DATABRICKS_VOLUME_SESSION_AUDIO',
          allowedMimes: ['audio/wav', 'audio/m4a', 'audio/mp4'],
          resolveContext: resolveCaptureContext,
        },
        lakebase,
      ),
    );

    // Screenshot uploads — PNG primary (UIScreen.snapshot), JPEG fallback
    app.post(
      '/api/captures/:capture_session_id/screenshots',
      auth,
      createUploadHandler(
        {
          kind: 'screenshot',
          volumeEnvVar: 'DATABRICKS_VOLUME_SCREENSHOTS',
          allowedMimes: ['image/png', 'image/jpeg'],
          resolveContext: resolveCaptureContext,
        },
        lakebase,
      ),
    );

    // Photo uploads — camera captures (whiteboards, physical artifacts). JPEG only.
    app.post(
      '/api/captures/:capture_session_id/photos',
      auth,
      createUploadHandler(
        {
          kind: 'photo',
          volumeEnvVar: 'DATABRICKS_VOLUME_SCREENSHOTS',
          allowedMimes: ['image/jpeg'],
          resolveContext: resolveCaptureContext,
        },
        lakebase,
      ),
    );

    // Document uploads (project-level, no capture session)
    app.post(
      '/api/projects/:project_id/documents',
      auth,
      createUploadHandler(
        {
          kind: 'document',
          volumeEnvVar: 'DATABRICKS_VOLUME_DOCUMENTS',
          allowedMimes: ['application/pdf', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'],
          resolveContext: resolveDocumentContext,
        },
        lakebase,
      ),
    );
  });
}
