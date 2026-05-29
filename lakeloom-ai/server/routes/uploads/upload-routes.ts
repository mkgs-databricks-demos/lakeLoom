/**
 * Binary upload routes — iOS + browser authenticated, App-proxied to UC Volumes.
 *
 * Per ADR-001, all binary uploads route through the App:
 *   iOS → App endpoint (Layer 0+1 auth) → App backend → UC Volume write (App SPN)
 *   Browser → App endpoint (on-behalf-of-user auth) → App backend → UC Volume write (App SPN)
 *
 * Endpoints:
 *   POST /api/captures/:capture_session_id/audio        — Session audio recordings (iOS ONLY)
 *   POST /api/captures/:capture_session_id/screenshots  — Session screen captures (iOS + browser)
 *   POST /api/captures/:capture_session_id/photos       — Camera photos (iOS + browser)
 *   POST /api/projects/:project_id/documents            — Project reference documents (iOS + browser)
 *
 * Path layout (project-anchored, UUIDv7 filenames):
 *   audio:       /Volumes/.../session_audio/{project_id}/{capture_session_id}/{uuidv7}.{ext}
 *   screenshots: /Volumes/.../screenshots/{project_id}/{capture_session_id}/{uuidv7}.{ext}
 *   photos:      /Volumes/.../screenshots/{project_id}/{capture_session_id}/{uuidv7}.{ext}
 *   documents:   /Volumes/.../documents/{project_id}/{uuidv7}.{ext}
 *
 * Upload flow (per Isaac's 9-step spec):
 *   1. Auth middleware resolves user_id (+ paired_session_id for iOS, empty for browser)
 *   2. Validate URL params (capture exists + valid state, or project exists)
 *   3. Generate UUIDv7 → upload_id (also the filename root)
 *   4. Parse multipart body (busboy). Reject if file field missing/empty.
 *   5. Validate MIME against per-endpoint allowlist, derive extension
 *   6. Upload file to UC Volume via AppKit files plugin, compute SHA-256 from buffer or stream
 *   7. If client sent sha256_hex, compare. Mismatch → 400 + delete file.
 *   8. INSERT INTO app.uploads
 *   9. Return 201 { id, kind, volume_path, size_bytes, sha256_hex, uploaded_at }
 *
 * Auth:
 *   - Audio: iosAuth only (recording is iOS-exclusive)
 *   - Screenshots/Photos/Documents: dualAuth (iOS Layer 2 OR browser on-behalf-of-user)
 *   - clientType is server-determined from auth context (x-lakeloom-session-token → ios, else → web)
 *
 * State rules:
 *   - iOS: can only upload to active capture sessions
 *   - Browser: can upload to active OR completed sessions (post-hoc annotation)
 *   - Neither: cancelled sessions reject uploads
 *
 * Volume I/O:
 *   All file operations use the AppKit files() plugin, which manages SDK auth,
 *   directory creation, and upload serialization correctly. Volume keys match
 *   the app.yaml valueFrom identifiers: session-audio, screenshots, documents.
 *
 * Large-file behavior:
 *   - iOS retains the proven buffer-based path (small files, simpler)
 *   - Browser uses a streaming path for 5 GB uploads: Busboy → PassThrough → UC Volume
 *     while SHA-256 is computed incrementally and size is enforced without buffering
 */

import { createHash } from 'node:crypto';
import { Readable, PassThrough } from 'node:stream';
import type { Application, Request, Response, NextFunction } from 'express';
import Busboy from 'busboy';
import { v7 as uuidv7 } from 'uuid';
import { writeFile, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { requiresTranscode, isTranscodeAvailable, transcodeToM4A, cleanupTempFiles } from '../../services/transcode-service';
import { iosAuth } from '../../middleware/ios-auth';
import { dualAuth } from '../../middleware/browser-auth';
import { AppError, ErrorTypes } from '../../lib/errors';

// ── Interfaces ───────────────────────────────────────────────────────────────────

interface LakebaseClient {
  query(text: string, params?: unknown[]): Promise<{ rows: Record<string, unknown>[] }>;
}

/** AppKit files plugin accessor — callable with volume key, returns VolumeHandle */
interface AppKitFiles {
  (volumeKey: string): {
    asUser(req: Request): {
      upload(filePath: string, contents: ReadableStream | Buffer | string, options?: { overwrite?: boolean }): Promise<void>;
      delete(filePath: string): Promise<void>;
      createDirectory(directoryPath: string): Promise<void>;
    };
    upload(filePath: string, contents: ReadableStream | Buffer | string, options?: { overwrite?: boolean }): Promise<void>;
    delete(filePath: string): Promise<void>;
    createDirectory(directoryPath: string): Promise<void>;
  };
}

interface AppKitContext {
  lakebase: LakebaseClient;
  server: { extend(fn: (app: Application) => void): void };
}

// ── MIME allowlist ────────────────────────────────────────────────────────────────

const MIME_TO_EXT: Record<string, string> = {
  'audio/wav': 'wav',
  'audio/m4a': 'm4a',
  'audio/mp4': 'm4a',
  'audio/x-caf': 'caf',
  'audio/x-aiff': 'aiff',
  'audio/aiff': 'aiff',
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'application/pdf': 'pdf',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation': 'pptx',
  'text/markdown': 'md',
};

// ── Client type constants ────────────────────────────────────────────────────────

/** Upload source discriminator — server-determined from auth context */
export type ClientType = 'ios' | 'web';

/** 5 GB maximum upload size for browser uploads. */
const MAX_UPLOAD_BYTES = 5 * 1024 * 1024 * 1024;

/**
 * Detect client type from request auth context.
 * Presence of X-Lakeloom-Session-Token header indicates iOS Layer 2 auth.
 * Absence (with browser identity headers) indicates web/browser.
 */
function detectClientType(req: Request): ClientType {
  return req.headers['x-lakeloom-session-token'] ? 'ios' : 'web';
}

// ── Volume path helpers ──────────────────────────────────────────────────────────

function requireNonEmptyString(value: unknown, context: string): string {
  if (typeof value !== 'string') {
    throw new Error(`${context} must be a string.`);
  }
  const trimmed = value.trim();
  if (trimmed.length === 0) {
    throw new Error(`${context} cannot be empty.`);
  }
  return trimmed;
}

function requireSingleRouteParam(value: string | string[] | undefined, context: string): string {
  if (Array.isArray(value)) {
    if (value.length !== 1) {
      throw buildUploadAppError(
        400,
        'Invalid route parameter',
        `Expected exactly one '${context}' route parameter value.`,
        { error_code: 'UPLOAD_INVALID_ROUTE_PARAM', route_param: context, route_param_count: value.length },
      );
    }
    return requireNonEmptyString(value[0], `Route parameter '${context}'`);
  }
  return requireNonEmptyString(value, `Route parameter '${context}'`);
}

function requirePathComponent(value: unknown, context: string): string {
  const trimmed = requireNonEmptyString(value, `Upload ${context}`);
  const normalized = trimmed.replace(/^\/+|\/+$/g, '');
  if (normalized.length === 0) throw new Error(`Upload ${context} cannot be empty.`);
  if (normalized.includes('/')) throw new Error(`Upload ${context} must not contain '/': ${trimmed}`);
  if (normalized === '.' || normalized === '..') throw new Error(`Upload ${context} must not be '.' or '..'.`);
  return normalized;
}

function requireFileExtension(value: unknown): string {
  const trimmed = requireNonEmptyString(value, 'Upload file extension');
  const normalized = trimmed.replace(/^\.+|\.+$/g, '').toLowerCase();
  if (normalized.length === 0) throw new Error('Upload file extension cannot be empty.');
  if (normalized.includes('/') || normalized.includes('\\')) {
    throw new Error(`Upload file extension must not contain path separators: ${trimmed}`);
  }
  if (normalized.includes('.')) throw new Error(`Upload file extension must not contain '.': ${trimmed}`);
  return normalized;
}

/**
 * Builds the relative path within the volume and the full canonical path.
 * Relative path: {projectId}/{captureSessionId}/{uploadId}.{ext}
 * Canonical path: {volumeBasePath}/{relativePath}
 */
function buildUploadPaths(params: {
  volumeBasePath: string;
  projectId: string;
  captureSessionId?: string | null;
  uploadId: string;
  extension: string;
}): { relativePath: string; canonicalPath: string; fileName: string } {
  const projectId = requirePathComponent(params.projectId, 'project_id');
  const captureSessionId = params.captureSessionId
    ? requirePathComponent(params.captureSessionId, 'capture_session_id')
    : null;
  const uploadId = requirePathComponent(params.uploadId, 'upload_id');
  const extension = requireFileExtension(params.extension);
  const fileName = `${uploadId}.${extension}`;

  const relativePath = captureSessionId
    ? `${projectId}/${captureSessionId}/${fileName}`
    : `${projectId}/${fileName}`;

  const basePath = params.volumeBasePath.replace(/\/+$/, '');
  const canonicalPath = `${basePath}/${relativePath}`;

  return { relativePath, canonicalPath, fileName };
}

/**
 * Resolves the full volume base path from the environment variable.
 * These are injected by the platform from app.yaml valueFrom declarations.
 */
function getVolumeBasePath(volumeEnvVar: string): string {
  const path = process.env[volumeEnvVar];
  if (!path) {
    throw buildUploadAppError(
      500,
      'Upload storage not configured',
      'The upload storage location is not configured for this environment.',
      { error_code: 'UPLOAD_VOLUME_NOT_CONFIGURED', missing_env: volumeEnvVar },
    );
  }
  const trimmed = path.trim().replace(/\/+$/, '');
  if (!trimmed.startsWith('/Volumes/')) {
    throw new Error(`Upload volume path must start with /Volumes/: ${path}`);
  }
  return trimmed;
}

// ── Error helpers ────────────────────────────────────────────────────────────────

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

function normalizeError(error: unknown): Record<string, unknown> {
  if (error instanceof AppError) {
    return { error_name: error.name, error_message: error.message, error_status_code: error.status, error_details: error.extra };
  }
  if (error instanceof Error) {
    return { error_name: error.name, error_message: error.message, error_stack: error.stack };
  }
  return { error_message: String(error) };
}

// ── Diagnostics / logging ────────────────────────────────────────────────────────

type UploadKind = 'audio' | 'screenshot' | 'photo' | 'document';

type UploadDiagnostics = {
  uploadId: string;
  kind: UploadKind;
  clientType: ClientType;
  projectId: string;
  captureSessionId: string | null;
  pairedSessionId: string | null;
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

function buildUploadContext(diagnostics: Partial<UploadDiagnostics>, extra?: Record<string, unknown>): Record<string, unknown> {
  return {
    upload_id: diagnostics.uploadId ?? null,
    upload_kind: diagnostics.kind ?? null,
    client_type: diagnostics.clientType ?? null,
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

function logUploadEvent(message: string, diagnostics: Partial<UploadDiagnostics>, extra?: Record<string, unknown>): void {
  console.log(message, buildUploadContext(diagnostics, extra));
}

function logUploadError(message: string, diagnostics: Partial<UploadDiagnostics>, error: unknown, extra?: Record<string, unknown>): void {
  console.error(message, buildUploadContext(diagnostics, { ...extra, ...normalizeError(error), ...(error instanceof AppError ? error.extra : {}) }));
}

function toUploadAppError(error: unknown, req: Request, diagnostics: Partial<UploadDiagnostics>): AppError {
  if (error instanceof AppError) return error;
  return buildUploadAppError(500, 'Upload failed', 'The upload request could not be completed.',
    buildUploadContext(diagnostics, { error_code: 'UPLOAD_REQUEST_FAILED', request_path: req.path, request_method: req.method, error_message: getErrorMessage(error) }));
}

// ── Timestamp normalization ──────────────────────────────────────────────────────

function normalizeClientTimestamp(rawClientTs?: string): { isoTimestamp: string; source: 'client' | 'server'; fallbackReason?: string } {
  if (!rawClientTs || rawClientTs.trim().length === 0) {
    return { isoTimestamp: new Date().toISOString(), source: 'server', fallbackReason: 'missing_client_ts' };
  }
  const normalized = rawClientTs.trim();
  if (!/^\d+$/.test(normalized)) {
    return { isoTimestamp: new Date().toISOString(), source: 'server', fallbackReason: 'client_ts_not_integer' };
  }
  const asNumber = Number(normalized);
  const millis = normalized.length <= 10 ? asNumber * 1000 : asNumber;
  const parsed = new Date(millis);
  if (Number.isNaN(parsed.getTime())) {
    return { isoTimestamp: new Date().toISOString(), source: 'server', fallbackReason: 'client_ts_invalid' };
  }
  return { isoTimestamp: parsed.toISOString(), source: 'client' };
}

// ── Multipart parsing ────────────────────────────────────────────────────────────

interface ParsedUpload {
  fileBuffer: Buffer;
  fileMimeType: string;
  clientTs?: string;
  clientFilename?: string;
  clientSha256?: string;
  deviceId?: string;
}

interface ParsedStreamingUpload {
  fileMimeType: string;
  clientTs?: string;
  clientFilename?: string;
  clientSha256?: string;
  deviceId?: string;
  sizeBytes: number;
  sha256Hex: string;
  relativePath: string;
  canonicalPath: string;
  fileName: string;
}

function getBufferedRequestBody(req: Request): Buffer | null {
  const rawBody = (req as Request & { _rawBody?: unknown })._rawBody;
  return Buffer.isBuffer(rawBody) ? rawBody : null;
}

function parseMultipart(req: Request): Promise<ParsedUpload> {
  return new Promise((resolve, reject) => {
    const contentType = req.headers['content-type'] ?? '';
    if (!contentType.toLowerCase().includes('multipart/form-data')) {
      reject(buildUploadAppError(400, 'Invalid upload payload', 'Expected a multipart/form-data request body.', { error_code: 'UPLOAD_MULTIPART_REQUIRED' }));
      return;
    }

    const busboy = Busboy({ headers: req.headers });
    const chunks: Buffer[] = [];
    const bufferedBody = getBufferedRequestBody(req);
    let fileMimeType = '';
    let clientTs: string | undefined;
    let clientFilename: string | undefined;
    let clientSha256: string | undefined;
    let deviceId: string | undefined;
    let fileReceived = false;

    busboy.on('file', (_fieldname, stream, info) => {
      fileMimeType = info.mimeType;
      // Capture the filename from Content-Disposition (browser sends this automatically)
      if (info.filename && !clientFilename) clientFilename = info.filename;
      fileReceived = true;
      stream.on('data', (chunk: Buffer) => chunks.push(chunk));
      stream.on('error', (streamErr) => {
        reject(buildUploadAppError(400, 'Invalid upload stream', 'The uploaded file stream could not be read.', { error_code: 'UPLOAD_STREAM_READ_FAILED', error_message: getErrorMessage(streamErr) }));
      });
    });

    busboy.on('field', (fieldname, value) => {
      if (fieldname === 'client_ts') clientTs = value;
      if (fieldname === 'client_filename') clientFilename = value;
      if (fieldname === 'sha256_hex') clientSha256 = value;
      if (fieldname === 'device_id') deviceId = value;
    });

    busboy.on('error', (parseErr) => {
      reject(buildUploadAppError(400, 'Invalid multipart body', 'The multipart request body could not be parsed.', { error_code: 'UPLOAD_MULTIPART_PARSE_FAILED', error_message: getErrorMessage(parseErr) }));
    });

    busboy.on('finish', () => {
      if (!fileReceived || chunks.length === 0) {
        reject(buildUploadAppError(400, 'Missing upload file', 'A non-empty file field is required.', { error_code: 'UPLOAD_FILE_REQUIRED' }));
        return;
      }
      resolve({ fileBuffer: Buffer.concat(chunks), fileMimeType, clientTs, clientFilename, clientSha256, deviceId });
    });

    if (bufferedBody) {
      Readable.from(bufferedBody).pipe(busboy);
      return;
    }
    req.pipe(busboy);
  });
}

async function parseMultipartStreaming(
  req: Request,
  opts: {
    allowedMimes?: string[];
    volumeKey: string;
    volumeBasePath: string;
    projectId: string;
    captureSessionId: string | null;
    uploadId: string;
    appkitFiles: AppKitFiles;
  },
): Promise<ParsedStreamingUpload> {
  return new Promise((resolve, reject) => {
    const contentType = req.headers['content-type'] ?? '';
    if (!contentType.toLowerCase().includes('multipart/form-data')) {
      reject(buildUploadAppError(400, 'Invalid upload payload', 'Expected a multipart/form-data request body.', { error_code: 'UPLOAD_MULTIPART_REQUIRED' }));
      return;
    }

    const busboy = Busboy({ headers: req.headers });
    const bufferedBody = getBufferedRequestBody(req);
    const hash = createHash('sha256');

    let fileMimeType = '';
    let clientTs: string | undefined;
    let clientFilename: string | undefined;
    let clientSha256: string | undefined;
    let deviceId: string | undefined;

    let fileReceived = false;
    let sizeBytes = 0;
    let relativePath: string | undefined;
    let canonicalPath: string | undefined;
    let fileName: string | undefined;
    let uploadPromise: Promise<void> | null = null;
    let uploadStarted = false;
    let settled = false;

    const rejectWithCleanup = (error: AppError) => {
      if (settled) return;
      settled = true;

      void (async () => {
        if (uploadStarted && relativePath) {
          try {
            await opts.appkitFiles(opts.volumeKey).delete(relativePath);
          } catch (deleteErr) {
            console.error('[upload] delete_partial_streaming_upload_failed', {
              relative_path: relativePath,
              volume_key: opts.volumeKey,
              ...normalizeError(deleteErr),
            });
          }
        }
        reject(error);
      })();
    };

    busboy.on('file', (_fieldname, stream, info) => {
      if (fileReceived) {
        stream.resume();
        rejectWithCleanup(buildUploadAppError(
          400,
          'Invalid upload payload',
          'Exactly one file field is required per upload request.',
          { error_code: 'UPLOAD_MULTIPLE_FILES_NOT_SUPPORTED' },
        ));
        return;
      }

      fileReceived = true;
      fileMimeType = info.mimeType;
      // Capture the filename from Content-Disposition (browser sends this automatically)
      if (info.filename && !clientFilename) clientFilename = info.filename;

      if (opts.allowedMimes && !opts.allowedMimes.includes(fileMimeType)) {
        stream.resume();
        rejectWithCleanup(buildUploadAppError(
          415,
          'Unsupported Media Type',
          `MIME type '${fileMimeType}' is not accepted by this endpoint. Allowed: ${opts.allowedMimes.join(', ')}.`,
          { error_code: 'UPLOAD_UNSUPPORTED_MIME', file_mime_type: fileMimeType },
        ));
        return;
      }

      const ext = MIME_TO_EXT[fileMimeType];
      if (!ext) {
        stream.resume();
        rejectWithCleanup(buildUploadAppError(
          415,
          'Unsupported Media Type',
          `MIME type '${fileMimeType}' is not supported.`,
          { error_code: 'UPLOAD_UNSUPPORTED_MIME', file_mime_type: fileMimeType },
        ));
        return;
      }

      const paths = buildUploadPaths({
        volumeBasePath: opts.volumeBasePath,
        projectId: opts.projectId,
        captureSessionId: opts.captureSessionId,
        uploadId: opts.uploadId,
        extension: ext,
      });

      relativePath = paths.relativePath;
      canonicalPath = paths.canonicalPath;
      fileName = paths.fileName;

      const passThrough = new PassThrough();
      uploadStarted = true;
      uploadPromise = opts.appkitFiles(opts.volumeKey).upload(
        relativePath,
        Readable.toWeb(passThrough) as unknown as ReadableStream,
        { overwrite: false },
      );
      void uploadPromise.catch(() => undefined);

      stream.on('data', (chunk: Buffer) => {
        if (settled) return;
        sizeBytes += chunk.length;
        if (sizeBytes > MAX_UPLOAD_BYTES) {
          const tooLargeError = buildUploadAppError(
            413,
            'Upload too large',
            'The uploaded file exceeds the maximum allowed size of 5 GB.',
            {
              error_code: 'UPLOAD_FILE_TOO_LARGE',
              max_size_bytes: MAX_UPLOAD_BYTES,
              observed_size_bytes: sizeBytes,
            },
          );
          stream.unpipe(passThrough);
          passThrough.destroy(tooLargeError);
          stream.destroy(tooLargeError);
          rejectWithCleanup(tooLargeError);
          return;
        }
        hash.update(chunk);
      });

      stream.on('error', (streamErr) => {
        if (settled) return;
        passThrough.destroy(streamErr instanceof Error ? streamErr : new Error(getErrorMessage(streamErr)));
        rejectWithCleanup(buildUploadAppError(
          400,
          'Invalid upload stream',
          'The uploaded file stream could not be read.',
          { error_code: 'UPLOAD_STREAM_READ_FAILED', error_message: getErrorMessage(streamErr) },
        ));
      });

      stream.pipe(passThrough);
    });

    busboy.on('field', (fieldname, value) => {
      if (fieldname === 'client_ts') clientTs = value;
      if (fieldname === 'client_filename') clientFilename = value;
      if (fieldname === 'sha256_hex') clientSha256 = value;
      if (fieldname === 'device_id') deviceId = value;
    });

    busboy.on('error', (parseErr) => {
      if (settled) return;
      rejectWithCleanup(buildUploadAppError(
        400,
        'Invalid multipart body',
        'The multipart request body could not be parsed.',
        { error_code: 'UPLOAD_MULTIPART_PARSE_FAILED', error_message: getErrorMessage(parseErr) },
      ));
    });

    busboy.on('finish', () => {
      if (settled) return;

      void (async () => {
        if (!fileReceived || !uploadPromise || !relativePath || !canonicalPath || !fileName) {
          rejectWithCleanup(buildUploadAppError(
            400,
            'Missing upload file',
            'A non-empty file field is required.',
            { error_code: 'UPLOAD_FILE_REQUIRED' },
          ));
          return;
        }

        if (sizeBytes === 0) {
          rejectWithCleanup(buildUploadAppError(
            400,
            'Missing upload file',
            'A non-empty file field is required.',
            { error_code: 'UPLOAD_FILE_REQUIRED' },
          ));
          return;
        }

        try {
          await uploadPromise;
        } catch (uploadErr) {
          rejectWithCleanup(buildUploadAppError(
            500,
            'Upload storage failed',
            'The uploaded file could not be written to the configured storage volume.',
            {
              error_code: 'UPLOAD_VOLUME_WRITE_FAILED',
              canonical_volume_path: canonicalPath,
              relative_path: relativePath,
              volume_key: opts.volumeKey,
              upload_size_bytes: sizeBytes,
              ...normalizeError(uploadErr),
            },
          ));
          return;
        }

        if (settled) return;
        settled = true;
        resolve({
          fileMimeType,
          clientTs,
          clientFilename,
          clientSha256,
          deviceId,
          sizeBytes,
          sha256Hex: hash.digest('hex'),
          relativePath,
          canonicalPath,
          fileName,
        });
      })();
    });

    if (bufferedBody) {
      Readable.from(bufferedBody).pipe(busboy);
      return;
    }
    req.pipe(busboy);
  });
}

// ── Route context lookups ────────────────────────────────────────────────────────

/**
 * Resolve capture context for iOS uploads — active sessions only.
 */
async function resolveCaptureContextIos(req: Request, lakebase: LakebaseClient): Promise<{ projectId: string; captureSessionId: string }> {
  const captureSessionId = requireSingleRouteParam(req.params.capture_session_id, 'capture_session_id');
  const result = await lakebase.query(
    `SELECT project_id FROM app.capture_sessions WHERE id = $1::uuid AND state = 'active' LIMIT 1`,
    [captureSessionId],
  );
  const row = result.rows[0];
  if (!row) {
    throw buildUploadAppError(404, 'Capture session not found', `No active capture session '${captureSessionId}' was found.`, { error_code: 'UPLOAD_CAPTURE_NOT_FOUND', capture_session_id: captureSessionId });
  }
  return { projectId: String(row.project_id), captureSessionId };
}

/**
 * Resolve capture context for dual-auth uploads — accepts active OR completed sessions.
 * Browser users often upload reference material after ending a session.
 * iOS retains the stricter check via resolveCaptureContextIos.
 * Cancelled sessions still reject uploads from both clients.
 */
async function resolveCaptureContextDual(req: Request, lakebase: LakebaseClient): Promise<{ projectId: string; captureSessionId: string }> {
  const captureSessionId = requireSingleRouteParam(req.params.capture_session_id, 'capture_session_id');
  const clientType = detectClientType(req);

  // iOS: active only. Browser: active or completed.
  const stateClause = clientType === 'ios'
    ? `state = 'active'`
    : `state IN ('active', 'completed')`;

  const result = await lakebase.query(
    `SELECT project_id FROM app.capture_sessions WHERE id = $1::uuid AND ${stateClause} LIMIT 1`,
    [captureSessionId],
  );
  const row = result.rows[0];
  if (!row) {
    const stateHint = clientType === 'ios' ? 'active' : 'active or completed';
    throw buildUploadAppError(404, 'Capture session not found',
      `No ${stateHint} capture session '${captureSessionId}' was found.`,
      { error_code: 'UPLOAD_CAPTURE_NOT_FOUND', capture_session_id: captureSessionId, client_type: clientType, allowed_states: stateHint });
  }
  return { projectId: String(row.project_id), captureSessionId };
}

async function resolveProjectContext(req: Request, lakebase: LakebaseClient): Promise<{ projectId: string; captureSessionId: null }> {
  const projectId = requireSingleRouteParam(req.params.project_id, 'project_id');
  const result = await lakebase.query(`SELECT id FROM app.projects WHERE id = $1::uuid LIMIT 1`, [projectId]);
  const row = result.rows[0];
  if (!row) {
    throw buildUploadAppError(404, 'Project not found', `Project '${projectId}' does not exist.`, { error_code: 'UPLOAD_PROJECT_NOT_FOUND', project_id: projectId });
  }
  return { projectId, captureSessionId: null };
}

// ── Upload handler factory ───────────────────────────────────────────────────────

interface UploadHandlerOpts {
  kind: UploadKind;
  volumeKey: string;
  volumeEnvVar: string;
  allowedMimes?: string[];
  resolveContext: (req: Request, lakebase: LakebaseClient) => Promise<{ projectId: string; captureSessionId: string | null }>;
}

function createUploadHandler(opts: UploadHandlerOpts, lakebase: LakebaseClient, appkitFiles: AppKitFiles) {
  return async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    let volumeFilePath: string | undefined;
    let relativePath: string | undefined;
    const clientType = detectClientType(req);
    let diagnostics: Partial<UploadDiagnostics> = { kind: opts.kind, clientType };

    try {
      // ── Step 1: Auth already resolved by iosAuth or dualAuth middleware ──
      const userId = req.user!.userId;
      // Browser sessions have empty sessionId — normalize to null for DB
      const pairedSessionId = req.user!.sessionId || null;

      // ── Step 2: Resolve context (project + capture) ──────────────────
      const { projectId, captureSessionId } = await opts.resolveContext(req, lakebase);
      diagnostics = { ...diagnostics, projectId, captureSessionId, pairedSessionId, userId };

      logUploadEvent('[upload] request.accepted', diagnostics, {
        request_path: req.path,
        request_method: req.method,
        content_length: req.headers['content-length'] ?? null,
        content_type: req.headers['content-type'] ?? null,
      });

      // ── Step 3: Generate UUIDv7 ──────────────────────────────────
      const uploadId = uuidv7();
      const volumeBasePath = getVolumeBasePath(opts.volumeEnvVar);

      // ── Step 4: Parse multipart body (buffer for iOS, stream for browser) ─────
      let fileMimeType: string;
      let clientFilename: string | undefined;
      let clientSha256: string | undefined;
      let deviceId: string | undefined;
      let clientTs: string | undefined;
      let sizeBytes: number;
      let sha256Hash: string;
      let fileName: string | undefined;
      let rawFileBuffer: Buffer | null = null; // Retained for transcode (iOS buffered path only)

      if (clientType === 'web') {
        const parsed = await parseMultipartStreaming(req, {
          allowedMimes: opts.allowedMimes,
          volumeKey: opts.volumeKey,
          volumeBasePath,
          projectId,
          captureSessionId,
          uploadId,
          appkitFiles,
        });

        fileMimeType = parsed.fileMimeType;
        clientFilename = parsed.clientFilename;
        clientSha256 = parsed.clientSha256;
        deviceId = parsed.deviceId;
        clientTs = parsed.clientTs;
        sizeBytes = parsed.sizeBytes;
        sha256Hash = parsed.sha256Hex;
        relativePath = parsed.relativePath;
        volumeFilePath = parsed.canonicalPath;
        fileName = parsed.fileName;
      } else {
        const parsed = await parseMultipart(req);

        if (opts.allowedMimes && !opts.allowedMimes.includes(parsed.fileMimeType)) {
          throw buildUploadAppError(
            415,
            'Unsupported Media Type',
            `MIME type '${parsed.fileMimeType}' is not accepted by this endpoint. Allowed: ${opts.allowedMimes.join(', ')}.`,
            buildUploadContext(diagnostics, { error_code: 'UPLOAD_UNSUPPORTED_MIME' }),
          );
        }

        const ext = MIME_TO_EXT[parsed.fileMimeType];
        if (!ext) {
          throw buildUploadAppError(
            415,
            'Unsupported Media Type',
            `MIME type '${parsed.fileMimeType}' is not supported.`,
            buildUploadContext(diagnostics, { error_code: 'UPLOAD_UNSUPPORTED_MIME' }),
          );
        }

        const paths = buildUploadPaths({ volumeBasePath, projectId, captureSessionId, uploadId, extension: ext });
        relativePath = paths.relativePath;
        volumeFilePath = paths.canonicalPath;
        fileName = paths.fileName;

        fileMimeType = parsed.fileMimeType;
        clientFilename = parsed.clientFilename;
        clientSha256 = parsed.clientSha256;
        deviceId = parsed.deviceId;
        clientTs = parsed.clientTs;
        sizeBytes = parsed.fileBuffer.length;
        rawFileBuffer = parsed.fileBuffer; // Retain for potential transcode
        sha256Hash = createHash('sha256').update(parsed.fileBuffer).digest('hex');

        logUploadEvent('[upload] volume.write_attempt', diagnostics, {
          canonical_volume_path: volumeFilePath,
          relative_path: relativePath,
          volume_key: opts.volumeKey,
          upload_content_type: 'appkit_files_plugin',
          upload_size_bytes: sizeBytes,
          file_name: fileName,
        });

        try {
          await appkitFiles(opts.volumeKey).upload(relativePath, parsed.fileBuffer, { overwrite: false });
        } catch (volumeErr) {
          throw buildUploadAppError(
            500,
            'Upload storage failed',
            'The uploaded file could not be written to the configured storage volume.',
            buildUploadContext(diagnostics, {
              error_code: 'UPLOAD_VOLUME_WRITE_FAILED',
              canonical_volume_path: volumeFilePath,
              relative_path: relativePath,
              volume_key: opts.volumeKey,
              upload_size_bytes: sizeBytes,
              ...normalizeError(volumeErr),
            }),
          );
        }
      }

      // ── Step 5: Finalize diagnostics after parse/write ────────────────────────
      const normalizedTimestamp = normalizeClientTimestamp(clientTs);
      diagnostics = {
        uploadId,
        kind: opts.kind,
        clientType,
        projectId,
        captureSessionId,
        pairedSessionId,
        userId,
        fileMimeType,
        clientFilename,
        providedClientTs: clientTs,
        normalizedClientTs: normalizedTimestamp.isoTimestamp,
        timestampSource: normalizedTimestamp.source,
        timestampFallbackReason: normalizedTimestamp.fallbackReason,
        sizeBytes,
        volumeFilePath,
        sha256Hex: sha256Hash,
      };

      logUploadEvent('[upload] request.received', diagnostics, {
        request_path: req.path,
        request_method: req.method,
      });

      logUploadEvent('[upload] volume.path_resolved', diagnostics, {
        canonical_volume_path: volumeFilePath,
        relative_path: relativePath,
        volume_key: opts.volumeKey,
        file_name: fileName,
      });

      logUploadEvent('[upload] volume.write_succeeded', diagnostics, {
        canonical_volume_path: volumeFilePath,
        relative_path: relativePath,
        volume_key: opts.volumeKey,
        upload_content_type: 'appkit_files_plugin',
        upload_size_bytes: sizeBytes,
        file_name: fileName,
      });

      // ── Step 6: SHA-256 verification ─────────────────────────────
      if (clientSha256 && clientSha256 !== sha256Hash) {
        try {
          if (relativePath) {
            await appkitFiles(opts.volumeKey).delete(relativePath);
          }
          logUploadEvent('[upload] volume.deleted_after_sha_mismatch', diagnostics, { client_sha256: clientSha256 });
        } catch (delErr) {
          logUploadError('[upload] delete_after_sha_mismatch_failed', diagnostics, delErr, { volumeFilePath });
        }
        throw buildUploadAppError(
          400,
          'SHA-256 Mismatch',
          `Client SHA-256 (${clientSha256}) does not match computed (${sha256Hash}). File deleted.`,
          buildUploadContext(diagnostics, { error_code: 'UPLOAD_SHA256_MISMATCH', client_sha256: clientSha256, computed_sha256: sha256Hash }),
        );
      }

      // ── Step 6b: Server-side transcode (CAF/AIFF → M4A) ───────────────
      let originalVolumePath: string | null = null;
      let originalMimeType: string | null = null;

      if (requiresTranscode(fileMimeType)) {
        if (!isTranscodeAvailable()) {
          logUploadEvent('[upload] transcode.skipped', diagnostics, {
            reason: 'ffmpeg_not_available',
            mime_type: fileMimeType,
          });
        } else if (!rawFileBuffer && clientType === 'web') {
          // Web streaming uploads don't retain the buffer — transcode not supported
          // (CAF uploads are exclusively from iOS, so this shouldn't happen in practice)
          logUploadEvent('[upload] transcode.skipped', diagnostics, {
            reason: 'no_buffer_streaming_upload',
            mime_type: fileMimeType,
          });
        } else if (rawFileBuffer) {
          const inputExt = MIME_TO_EXT[fileMimeType] ?? 'caf';
          const tempInputPath = join('/tmp', `upload-${diagnostics.uploadId}-input.${inputExt}`);
          const tempOutputPath = join('/tmp', `upload-${diagnostics.uploadId}-output.m4a`);

          try {
            // Write raw buffer to temp file for ffmpeg
            await writeFile(tempInputPath, rawFileBuffer);

            logUploadEvent('[upload] transcode.started', diagnostics, {
              from_mime: fileMimeType,
              input_size_bytes: rawFileBuffer.length,
              temp_input: tempInputPath,
            });

            const result = await transcodeToM4A(tempInputPath, tempOutputPath);

            // Upload the transcoded M4A to volume (same directory, .m4a extension)
            const m4aRelativePath = relativePath!.replace(/\.[^.]+$/, '.m4a');
            await appkitFiles(opts.volumeKey).upload(m4aRelativePath, await readFile(tempOutputPath), { overwrite: false });

            // Track originals before overwriting
            originalVolumePath = volumeFilePath!;
            originalMimeType = fileMimeType;

            // Update references to point to transcoded file
            const m4aCanonicalPath = volumeFilePath!.replace(/\.[^.]+$/, '.m4a');
            volumeFilePath = m4aCanonicalPath;
            relativePath = m4aRelativePath;
            fileMimeType = 'audio/mp4';
            sizeBytes = result.outputSizeBytes;
            // Recompute SHA-256 of the transcoded file
            const transcodeBuffer = await readFile(tempOutputPath);
            sha256Hash = createHash('sha256').update(transcodeBuffer).digest('hex');

            logUploadEvent('[upload] transcode.completed', diagnostics, {
              from_mime: originalMimeType,
              to_mime: 'audio/mp4',
              duration_ms: result.durationMs,
              original_size_bytes: rawFileBuffer.length,
              transcoded_size_bytes: result.outputSizeBytes,
              original_volume_path: originalVolumePath,
              transcoded_volume_path: volumeFilePath,
            });
          } catch (transcodeErr) {
            // Transcode failure is non-fatal — raw file already on volume
            logUploadError('[upload] transcode.failed', diagnostics, transcodeErr, {
              from_mime: fileMimeType,
              note: 'raw file preserved on volume; browser playback may be limited',
            });
            // originalVolumePath/originalMimeType stay null — metadata will reflect raw file
          } finally {
            await cleanupTempFiles(tempInputPath, tempOutputPath);
          }
        }
      }

      // ── Step 7: INSERT INTO app.uploads ──────────────────────────
      logUploadEvent('[upload] metadata.insert_attempt', diagnostics, {
        insert_target: 'app.uploads',
        insert_kind: opts.kind,
        insert_volume_path: volumeFilePath,
        insert_size_bytes: sizeBytes,
        insert_client_ts: normalizedTimestamp.isoTimestamp,
      });

      try {
        await lakebase.query(
          `INSERT INTO app.uploads
             (id, kind, project_id, capture_session_id, paired_session_id, user_id,
              volume_path, mime_type, size_bytes, sha256_hex, original_filename, client_ts, device_id, client_type,
              original_volume_path, original_mime_type)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12::timestamptz, $13::uuid, $14, $15, $16)`,
          [
            uploadId,
            opts.kind,
            projectId,
            captureSessionId,
            pairedSessionId,
            userId,
            volumeFilePath,
            fileMimeType,
            sizeBytes,
            sha256Hash,
            clientFilename ?? null,
            normalizedTimestamp.isoTimestamp,
            deviceId ?? null,
            clientType,
            originalVolumePath,
            originalMimeType,
          ],
        );
        logUploadEvent('[upload] metadata.insert_succeeded', diagnostics, { insert_target: 'app.uploads', insert_volume_path: volumeFilePath });
      } catch (insertErr) {
        logUploadError('[upload] metadata.insert_failed', diagnostics, insertErr);
        try {
          if (relativePath) {
            await appkitFiles(opts.volumeKey).delete(relativePath);
          }
          logUploadEvent('[upload] volume.deleted_after_metadata_failure', diagnostics);
        } catch (delErr) {
          logUploadError('[upload] delete_after_metadata_failure_failed', diagnostics, delErr, { volumeFilePath });
        }
        throw buildUploadAppError(
          500,
          'Upload metadata persistence failed',
          'The file was stored, but upload metadata could not be persisted.',
          buildUploadContext(diagnostics, { error_code: 'UPLOAD_METADATA_INSERT_FAILED', error_message: getErrorMessage(insertErr) }),
        );
      }

      // ── Step 8: 201 response ──────────────────────────────────────
      res.status(201).json({
        id: uploadId,
        kind: opts.kind,
        client_type: clientType,
        project_id: projectId,
        capture_session_id: captureSessionId,
        volume_path: volumeFilePath,
        mime_type: fileMimeType,
        size_bytes: sizeBytes,
        sha256_hex: sha256Hash,
        client_ts: normalizedTimestamp.isoTimestamp,
        client_ts_source: normalizedTimestamp.source,
        uploaded_at: new Date().toISOString(),
      });
    } catch (error) {
      const appError = toUploadAppError(error, req, diagnostics);
      logUploadError('[upload] request.failed', diagnostics, appError, { path: req.path });
      next(appError);
    }
  };
}

// ── Public registration entry point ────────────────────────────────────────────

export default function registerUploads(ctx: AppKitContext): void {
  // AppKit files plugin — accessed via dynamic key because PluginMap name typing
  // uses generic `string` rather than literal "files", preventing structural match.
  const appkitFiles = (ctx as unknown as { files: AppKitFiles }).files;
  const { lakebase } = ctx;

  ctx.server.extend((app) => {
    // ── Audio: iOS only (recording is device-exclusive) ─────────────────
    app.post(
      '/api/captures/:capture_session_id/audio',
      iosAuth({ lakebase }),
      createUploadHandler(
        { kind: 'audio', volumeKey: 'session_audio', volumeEnvVar: 'LAKELOOM_AUDIO_VOLUME_PATH', allowedMimes: ['audio/wav', 'audio/m4a', 'audio/mp4', 'audio/x-caf', 'audio/x-aiff', 'audio/aiff'], resolveContext: resolveCaptureContextIos },
        lakebase, appkitFiles,
      ),
    );

    // ── Screenshots: iOS + browser (dualAuth) ───────────────────────────
    app.post(
      '/api/captures/:capture_session_id/screenshots',
      dualAuth({ lakebase }),
      createUploadHandler(
        { kind: 'screenshot', volumeKey: 'screenshots', volumeEnvVar: 'LAKELOOM_SCREENSHOT_VOLUME_PATH', allowedMimes: ['image/png', 'image/jpeg'], resolveContext: resolveCaptureContextDual },
        lakebase, appkitFiles,
      ),
    );

    // ── Photos: iOS + browser (dualAuth) ────────────────────────────────
    app.post(
      '/api/captures/:capture_session_id/photos',
      dualAuth({ lakebase }),
      createUploadHandler(
        { kind: 'photo', volumeKey: 'screenshots', volumeEnvVar: 'LAKELOOM_PHOTO_VOLUME_PATH', allowedMimes: ['image/png', 'image/jpeg'], resolveContext: resolveCaptureContextDual },
        lakebase, appkitFiles,
      ),
    );

    // ── Documents: iOS + browser (dualAuth) ─────────────────────────────
    app.post(
      '/api/projects/:project_id/documents',
      dualAuth({ lakebase }),
      createUploadHandler(
        { kind: 'document', volumeKey: 'documents', volumeEnvVar: 'LAKELOOM_DOCUMENT_VOLUME_PATH', allowedMimes: ['application/pdf', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'application/vnd.openxmlformats-officedocument.presentationml.presentation', 'text/markdown', 'image/png', 'image/jpeg'], resolveContext: resolveProjectContext },
        lakebase, appkitFiles,
      ),
    );
  });
}
