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
import { AppError, ErrorTypes } from '../../lib/errors';

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
    throw buildUploadAppError(
      500,
      'Upload storage not configured',
      'The upload storage location is not configured for this environment.',
      {
        error_code: 'UPLOAD_VOLUME_NOT_CONFIGURED',
        missing_env: volumeEnv,
      },
    );
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

type UploadDiagnostics = {
  uploadId: string;
  kind: UploadKind;
  projectId: string;
  captureSessionId: string | null;
  pairedSessionId: string;
  userId: string;
  fileMimeType: string;
  clientFilename?: string;
  providedClientTs?: string;
  normalizedClientTs: string;
  timestampSource: 'client' | 'server';
  timestampFallbackReason?: string;
  sizeBytes: number;
  volumeFilePath?: string;
  sha256Hex?: string;
};

function normalizeClientTimestamp(rawClientTs?: string): {
  isoTimestamp: string;
  source: 'client' | 'server';
  fallbackReason?: string;
} {
  if (!rawClientTs || rawClientTs.trim().length === 0) {
    return {
      isoTimestamp: new Date().toISOString(),
      source: 'server',
      fallbackReason: 'missing_client_ts',
    };
  }

  const normalized = rawClientTs.trim();
  if (!/^\d{10,}$/.test(normalized)) {
    return {
      isoTimestamp: new Date().toISOString(),
      source: 'server',
      fallbackReason: 'invalid_unix_seconds',
    };
  }

  const unixSeconds = Number.parseInt(normalized.slice(0, 10), 10);
  if (!Number.isFinite(unixSeconds) || unixSeconds <= 0) {
    return {
      isoTimestamp: new Date().toISOString(),
      source: 'server',
      fallbackReason: 'invalid_unix_seconds',
    };
  }

  const isoTimestamp = new Date(unixSeconds * 1000).toISOString();
  if (Number.isNaN(Date.parse(isoTimestamp))) {
    return {
      isoTimestamp: new Date().toISOString(),
      source: 'server',
      fallbackReason: 'invalid_unix_seconds',
    };
  }

  return {
    isoTimestamp,
    source: 'client',
  };
}

function buildUploadAppError(
  status: number,
  title: string,
  detail: string,
  extra?: Record<string, unknown>,
): AppError {
  return new AppError({
    type: status >= 500 ? ErrorTypes.INTERNAL_ERROR : ErrorTypes.VALIDATION_ERROR,
    status,
    title,
    detail,
    extra,
  });
}

function getErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function buildUploadContext(
  diagnostics: Partial<UploadDiagnostics>,
  extra?: Record<string, unknown>,
): Record<string, unknown> {
  return {
    upload_id: diagnostics.uploadId ?? null,
    upload_kind: diagnostics.kind ?? null,
    project_id: diagnostics.projectId ?? null,
    capture_session_id: diagnostics.captureSessionId ?? null,
    paired_session_id: diagnostics.pairedSessionId ?? null,
    user_id: diagnostics.userId ?? null,
    file_mime_type: diagnostics.fileMimeType ?? null,
    client_filename: diagnostics.clientFilename ?? null,
    provided_client_ts: diagnostics.providedClientTs ?? null,
    normalized_client_ts: diagnostics.normalizedClientTs ?? null,
    timestamp_source: diagnostics.timestampSource ?? null,
    timestamp_fallback_reason: diagnostics.timestampFallbackReason ?? null,
    size_bytes: diagnostics.sizeBytes ?? null,
    volume_path: diagnostics.volumeFilePath ?? null,
    sha256_hex: diagnostics.sha256Hex ?? null,
    ...extra,
  };
}

function logUploadEvent(
  message: string,
  diagnostics: Partial<UploadDiagnostics>,
  extra?: Record<string, unknown>,
): void {
  console.log(message, buildUploadContext(diagnostics, extra));
}

function logUploadError(
  message: string,
  diagnostics: Partial<UploadDiagnostics>,
  error: unknown,
  extra?: Record<string, unknown>,
): void {
  console.error(
    message,
    buildUploadContext(diagnostics, {
      ...extra,
      errorName: error instanceof Error ? error.name : 'UnknownError',
      errorMessage: getErrorMessage(error),
      errorStack: error instanceof Error ? error.stack : undefined,
    }),
  );
}

function toUploadAppError(
  error: unknown,
  req: Request,
  diagnostics: Partial<UploadDiagnostics>,
): AppError {
  if (error instanceof AppError) {
    return error;
  }

  return buildUploadAppError(
    500,
    'Upload failed',
    'The upload request could not be completed.',
    buildUploadContext(diagnostics, {
      error_code: 'UPLOAD_REQUEST_FAILED',
      request_path: req.path,
      request_method: req.method,
      error_message: getErrorMessage(error),
    }),
  );
}

function parseMultipart(req: Request): Promise<ParsedUpload> {
  return new Promise((resolve, reject) => {
    const contentType = req.headers['content-type'] ?? '';
    if (!contentType.toLowerCase().includes('multipart/form-data')) {
      reject(
        buildUploadAppError(
          400,
          'Invalid upload payload',
          'Expected a multipart/form-data request body.',
          { error_code: 'UPLOAD_MULTIPART_REQUIRED' },
        ),
      );
      return;
    }

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
      stream.on('error', (streamErr) => {
        reject(
          buildUploadAppError(
            400,
            'Invalid upload stream',
            'The uploaded file stream could not be read.',
            {
              error_code: 'UPLOAD_STREAM_READ_FAILED',
              error_message: getErrorMessage(streamErr),
            },
          ),
        );
      });
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
          clientSha256 = value.trim().toLowerCase();
          break;
      }
    });

    busboy.on('finish', () => {
      if (!fileReceived || chunks.length === 0) {
        reject(
          buildUploadAppError(
            400,
            'Missing upload file',
            'No file data was received in the multipart request.',
            { error_code: 'UPLOAD_FILE_MISSING' },
          ),
        );
        return;
      }

      if (!fileMimeType) {
        reject(
          buildUploadAppError(
            400,
            'Missing file MIME type',
            'The uploaded file did not include a MIME type.',
            { error_code: 'UPLOAD_MIME_MISSING' },
          ),
        );
        return;
      }

      resolve({
        fileBuffer: Buffer.concat(chunks),
        fileMimeType,
        clientTs,
        clientFilename,
        clientSha256: clientSha256 || undefined,
      });
    });

    busboy.on('error', (busboyErr) => {
      reject(
        buildUploadAppError(
          400,
          'Invalid multipart payload',
          'The upload body could not be parsed as multipart/form-data.',
          {
            error_code: 'UPLOAD_MULTIPART_PARSE_FAILED',
            error_message: getErrorMessage(busboyErr),
          },
        ),
      );
    });

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
    let diagnostics: Partial<UploadDiagnostics> = { kind: opts.kind };
    const wc = new WorkspaceClient({ host: process.env.DATABRICKS_HOST });

    try {
      // ── Step 1: Auth already resolved by iosAuth middleware ───────────────
      const userId = req.user!.userId;
      const pairedSessionId = req.user!.sessionId;

      // ── Step 2: Resolve context (project + capture) ──────────────────────
      const { projectId, captureSessionId } = await opts.resolveContext(req, lakebase);
      diagnostics = {
        ...diagnostics,
        projectId,
        captureSessionId,
        pairedSessionId,
        userId,
      };

      logUploadEvent('[upload] request.accepted', diagnostics, {
        request_path: req.path,
        request_method: req.method,
        content_length: req.headers['content-length'] ?? null,
        content_type: req.headers['content-type'] ?? null,
      });

      // ── Step 3: Parse multipart body ─────────────────────────────────────
      const parsed = await parseMultipart(req);

      // ── Step 4: Generate UUIDv7 ──────────────────────────────────────────
      const uploadId = uuidv7();
      const normalizedTimestamp = normalizeClientTimestamp(parsed.clientTs);

      diagnostics = {
        uploadId,
        kind: opts.kind,
        projectId,
        captureSessionId,
        pairedSessionId,
        userId,
        fileMimeType: parsed.fileMimeType,
        clientFilename: parsed.clientFilename,
        providedClientTs: parsed.clientTs,
        normalizedClientTs: normalizedTimestamp.isoTimestamp,
        timestampSource: normalizedTimestamp.source,
        timestampFallbackReason: normalizedTimestamp.fallbackReason,
        sizeBytes: parsed.fileBuffer.length,
      };

      logUploadEvent('[upload] request.received', diagnostics, {
        request_path: req.path,
        request_method: req.method,
      });

      // ── Step 5: Validate MIME + derive extension ─────────────────────────
      if (opts.allowedMimes && !opts.allowedMimes.includes(parsed.fileMimeType)) {
        throw buildUploadAppError(
          415,
          'Unsupported Media Type',
          `MIME type '${parsed.fileMimeType}' is not accepted by this endpoint. Allowed: ${opts.allowedMimes.join(', ')}.`,
          buildUploadContext(diagnostics, {
            error_code: 'UPLOAD_UNSUPPORTED_MIME',
          }),
        );
      }

      const ext = MIME_TO_EXT[parsed.fileMimeType];
      if (!ext) {
        throw buildUploadAppError(
          415,
          'Unsupported Media Type',
          `MIME type '${parsed.fileMimeType}' is not in the allowed list.`,
          buildUploadContext(diagnostics, {
            error_code: 'UPLOAD_UNSUPPORTED_MIME',
          }),
        );
      }

      // ── Step 6: Compute SHA-256 + write to UC Volume ─────────────────────
      const sha256Hash = createHash('sha256').update(parsed.fileBuffer).digest('hex');
      diagnostics.sha256Hex = sha256Hash;

      const volumeBase = getVolumePath(opts.volumeEnvVar);
      if (captureSessionId) {
        volumeFilePath = `${volumeBase}/${projectId}/${captureSessionId}/${uploadId}.${ext}`;
      } else {
        volumeFilePath = `${volumeBase}/${projectId}/${uploadId}.${ext}`;
      }
      diagnostics.volumeFilePath = volumeFilePath;

      const stream = Readable.toWeb(Readable.from(parsed.fileBuffer)) as ReadableStream;
      try {
        await (wc.files as any).upload(volumeFilePath, stream);
      } catch (volumeErr) {
        throw buildUploadAppError(
          500,
          'Upload storage failed',
          'The uploaded file could not be written to the configured storage volume.',
          buildUploadContext(diagnostics, {
            error_code: 'UPLOAD_VOLUME_WRITE_FAILED',
            error_message: getErrorMessage(volumeErr),
          }),
        );
      }
      logUploadEvent('[upload] volume.write_succeeded', diagnostics);

      // ── Step 7: SHA-256 verification ─────────────────────────────────────
      if (parsed.clientSha256 && parsed.clientSha256 !== sha256Hash) {
        try {
          await (wc.files as any).delete(volumeFilePath);
          logUploadEvent('[upload] volume.deleted_after_sha_mismatch', diagnostics, {
            client_sha256: parsed.clientSha256,
          });
        } catch (delErr) {
          logUploadError('[upload] delete_after_sha_mismatch_failed', diagnostics, delErr, { volumeFilePath });
        }
        throw buildUploadAppError(
          400,
          'SHA-256 Mismatch',
          `Client SHA-256 (${parsed.clientSha256}) does not match computed (${sha256Hash}). File deleted.`,
          buildUploadContext(diagnostics, {
            error_code: 'UPLOAD_SHA256_MISMATCH',
            client_sha256: parsed.clientSha256,
            computed_sha256: sha256Hash,
          }),
        );
      }

      // ── Step 8: INSERT INTO app.uploads ──────────────────────────────────
      try {
        await lakebase.query(
          `INSERT INTO app.uploads
             (id, kind, project_id, capture_session_id, paired_session_id, user_id,
              volume_path, mime_type, size_bytes, sha256_hex, original_filename, client_ts)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12::timestamptz)`,
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
            normalizedTimestamp.isoTimestamp,
          ],
        );
        logUploadEvent('[upload] metadata.insert_succeeded', diagnostics);
      } catch (insertErr) {
        try {
          await (wc.files as any).delete(volumeFilePath);
          logUploadEvent('[upload] orphan_file_deleted', diagnostics);
        } catch (delErr) {
          logUploadError('[upload] orphan_file_delete_failed', diagnostics, delErr, { volumeFilePath });
        }
        throw buildUploadAppError(
          500,
          'Upload metadata persistence failed',
          'The uploaded file was stored but its metadata could not be recorded.',
          buildUploadContext(diagnostics, {
            error_code: 'UPLOAD_METADATA_INSERT_FAILED',
            error_message: getErrorMessage(insertErr),
          }),
        );
      }

      // ── Step 9: Return 201 ───────────────────────────────────────────────
      res.status(201).json({
        id: uploadId,
        kind: opts.kind,
        volume_path: volumeFilePath,
        size_bytes: parsed.fileBuffer.length,
        sha256_hex: sha256Hash,
        uploaded_at: new Date().toISOString(),
        client_ts: normalizedTimestamp.isoTimestamp,
        client_ts_source: normalizedTimestamp.source,
      });
    } catch (err) {
      const appError = toUploadAppError(err, req, diagnostics);
      logUploadError('[upload] request.failed', diagnostics, appError, { path: req.path });
      next(appError);
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
    throw buildUploadAppError(
      404,
      'Capture session not found',
      'The requested capture session does not exist or has been revoked.',
      {
        error_code: 'CAPTURE_SESSION_NOT_FOUND',
        capture_session_id: captureSessionId,
      },
    );
  }

  const capture = rows[0];
  if (capture.state !== 'active') {
    throw buildUploadAppError(
      409,
      'Capture session not active',
      `Capture session is '${capture.state}'. Uploads only accepted for 'active' captures.`,
      { error_code: 'CAPTURE_SESSION_NOT_ACTIVE', capture_session_id: captureSessionId, capture_state: capture.state },
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
    throw buildUploadAppError(400, 'Validation error', 'project_id is required.', {
      error_code: 'PROJECT_ID_REQUIRED',
    });
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

export const __testables = {
  normalizeClientTimestamp,
};
