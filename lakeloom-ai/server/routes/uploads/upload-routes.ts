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
 *   6. Upload file to UC Volume via AppKit files plugin, compute SHA-256 from buffer
 *   7. If iOS sent sha256_hex, compare. Mismatch → 400 + delete file.
 *   8. INSERT INTO app.uploads
 *   9. Return 201 { id, kind, volume_path, size_bytes, sha256_hex, uploaded_at }
 *
 * Volume I/O:
 *   All file operations use the AppKit files() plugin, which manages SDK auth,
 *   directory creation, and upload serialization correctly. Volume keys match
 *   the app.yaml valueFrom identifiers: session-audio, screenshots, documents.
 */

import { createHash } from 'node:crypto';
import { Readable } from 'node:stream';
import type { Application, Request, Response, NextFunction } from 'express';
import Busboy from 'busboy';
import { v7 as uuidv7 } from 'uuid';
import { iosAuth } from '../../middleware/ios-auth';
import { AppError, ErrorTypes } from '../../lib/errors';

// ── Interfaces ───────────────────────────────────────────────────────────────

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

// ── MIME allowlist ────────────────────────────────────────────────────────────

const MIME_TO_EXT: Record<string, string> = {
  'audio/wav': 'wav',
  'audio/m4a': 'm4a',
  'audio/mp4': 'm4a',
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'application/pdf': 'pdf',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx',
};

// ── Volume path helpers ──────────────────────────────────────────────────────

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

// ── Error helpers ────────────────────────────────────────────────────────────

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

// ── Diagnostics / logging ────────────────────────────────────────────────────

type UploadKind = 'audio' | 'screenshot' | 'photo' | 'document';

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

function buildUploadContext(diagnostics: Partial<UploadDiagnostics>, extra?: Record<string, unknown>): Record<string, unknown> {
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

// ── Timestamp normalization ──────────────────────────────────────────────────

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

// ── Multipart parsing ────────────────────────────────────────────────────────

interface ParsedUpload {
  fileBuffer: Buffer;
  fileMimeType: string;
  clientTs?: string;
  clientFilename?: string;
  clientSha256?: string;
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
    let fileReceived = false;

    busboy.on('file', (_fieldname, stream, info) => {
      fileMimeType = info.mimeType;
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
    });

    busboy.on('error', (parseErr) => {
      reject(buildUploadAppError(400, 'Invalid multipart body', 'The multipart request body could not be parsed.', { error_code: 'UPLOAD_MULTIPART_PARSE_FAILED', error_message: getErrorMessage(parseErr) }));
    });

    busboy.on('finish', () => {
      if (!fileReceived || chunks.length === 0) {
        reject(buildUploadAppError(400, 'Missing upload file', 'A non-empty file field is required.', { error_code: 'UPLOAD_FILE_REQUIRED' }));
        return;
      }
      resolve({ fileBuffer: Buffer.concat(chunks), fileMimeType, clientTs, clientFilename, clientSha256 });
    });

    if (bufferedBody) {
      Readable.from(bufferedBody).pipe(busboy);
      return;
    }
    req.pipe(busboy);
  });
}

// ── Route context lookups ────────────────────────────────────────────────────

async function resolveCaptureContext(req: Request, lakebase: LakebaseClient): Promise<{ projectId: string; captureSessionId: string }> {
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

async function resolveProjectContext(req: Request, lakebase: LakebaseClient): Promise<{ projectId: string; captureSessionId: null }> {
  const projectId = requireSingleRouteParam(req.params.project_id, 'project_id');
  const result = await lakebase.query(`SELECT id FROM app.projects WHERE id = $1::uuid LIMIT 1`, [projectId]);
  const row = result.rows[0];
  if (!row) {
    throw buildUploadAppError(404, 'Project not found', `Project '${projectId}' does not exist.`, { error_code: 'UPLOAD_PROJECT_NOT_FOUND', project_id: projectId });
  }
  return { projectId, captureSessionId: null };
}

// ── Upload handler factory ───────────────────────────────────────────────────

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
    let diagnostics: Partial<UploadDiagnostics> = { kind: opts.kind };

    try {
      // ── Step 1: Auth already resolved by iosAuth middleware ───────────────
      const userId = req.user!.userId;
      const pairedSessionId = req.user!.sessionId;

      // ── Step 2: Resolve context (project + capture) ──────────────────────
      const { projectId, captureSessionId } = await opts.resolveContext(req, lakebase);
      diagnostics = { ...diagnostics, projectId, captureSessionId, pairedSessionId, userId };

      logUploadEvent('[upload] request.accepted', diagnostics, {
        request_path: req.path, request_method: req.method,
        content_length: req.headers['content-length'] ?? null,
        content_type: req.headers['content-type'] ?? null,
      });

      // ── Step 3: Parse multipart body ─────────────────────────────────────
      const parsed = await parseMultipart(req);

      // ── Step 4: Generate UUIDv7 ──────────────────────────────────────────
      const uploadId = uuidv7();
      const normalizedTimestamp = normalizeClientTimestamp(parsed.clientTs);

      diagnostics = {
        uploadId, kind: opts.kind, projectId, captureSessionId, pairedSessionId, userId,
        fileMimeType: parsed.fileMimeType, clientFilename: parsed.clientFilename,
        providedClientTs: parsed.clientTs, normalizedClientTs: normalizedTimestamp.isoTimestamp,
        timestampSource: normalizedTimestamp.source, timestampFallbackReason: normalizedTimestamp.fallbackReason,
        sizeBytes: parsed.fileBuffer.length,
      };

      logUploadEvent('[upload] request.received', diagnostics, { request_path: req.path, request_method: req.method });

      // ── Step 5: Validate MIME + derive extension ─────────────────────────
      if (opts.allowedMimes && !opts.allowedMimes.includes(parsed.fileMimeType)) {
        throw buildUploadAppError(415, 'Unsupported Media Type',
          `MIME type '${parsed.fileMimeType}' is not accepted by this endpoint. Allowed: ${opts.allowedMimes.join(', ')}.`,
          buildUploadContext(diagnostics, { error_code: 'UPLOAD_UNSUPPORTED_MIME' }));
      }

      const ext = MIME_TO_EXT[parsed.fileMimeType];
      if (!ext) {
        throw buildUploadAppError(415, 'Unsupported Media Type', `MIME type '${parsed.fileMimeType}' is not supported.`,
          buildUploadContext(diagnostics, { error_code: 'UPLOAD_UNSUPPORTED_MIME' }));
      }

      // Compute SHA-256
      const sha256Hash = createHash('sha256').update(parsed.fileBuffer).digest('hex');
      diagnostics.sha256Hex = sha256Hash;

      // ── Step 6: Build paths and upload via AppKit files plugin ────────────
      const volumeBasePath = getVolumeBasePath(opts.volumeEnvVar);
      const paths = buildUploadPaths({ volumeBasePath, projectId, captureSessionId, uploadId, extension: ext });
      relativePath = paths.relativePath;
      volumeFilePath = paths.canonicalPath;
      diagnostics.volumeFilePath = volumeFilePath;

      logUploadEvent('[upload] volume.path_resolved', diagnostics, {
        canonical_volume_path: volumeFilePath,
        relative_path: relativePath,
        volume_key: opts.volumeKey,
        file_name: paths.fileName,
      });

      logUploadEvent('[upload] volume.write_attempt', diagnostics, {
        canonical_volume_path: volumeFilePath,
        upload_content_type: 'appkit_files_plugin',
        upload_size_bytes: parsed.fileBuffer.length,
        file_name: paths.fileName,
      });

      try {
        await appkitFiles(opts.volumeKey).upload(relativePath, parsed.fileBuffer, { overwrite: false });
      } catch (volumeErr) {
        throw buildUploadAppError(500, 'Upload storage failed',
          'The uploaded file could not be written to the configured storage volume.',
          buildUploadContext(diagnostics, {
            error_code: 'UPLOAD_VOLUME_WRITE_FAILED',
            canonical_volume_path: volumeFilePath,
            relative_path: relativePath,
            volume_key: opts.volumeKey,
            upload_size_bytes: parsed.fileBuffer.length,
            ...normalizeError(volumeErr),
          }));
      }

      logUploadEvent('[upload] volume.write_succeeded', diagnostics, {
        canonical_volume_path: volumeFilePath,
        upload_content_type: 'appkit_files_plugin',
        upload_size_bytes: parsed.fileBuffer.length,
        file_name: paths.fileName,
      });

      // ── Step 7: SHA-256 verification ─────────────────────────────────────
      if (parsed.clientSha256 && parsed.clientSha256 !== sha256Hash) {
        try {
          await appkitFiles(opts.volumeKey).delete(relativePath);
          logUploadEvent('[upload] volume.deleted_after_sha_mismatch', diagnostics, { client_sha256: parsed.clientSha256 });
        } catch (delErr) {
          logUploadError('[upload] delete_after_sha_mismatch_failed', diagnostics, delErr, { volumeFilePath });
        }
        throw buildUploadAppError(400, 'SHA-256 Mismatch',
          `Client SHA-256 (${parsed.clientSha256}) does not match computed (${sha256Hash}). File deleted.`,
          buildUploadContext(diagnostics, { error_code: 'UPLOAD_SHA256_MISMATCH', client_sha256: parsed.clientSha256, computed_sha256: sha256Hash }));
      }

      // ── Step 8: INSERT INTO app.uploads ──────────────────────────────────
      logUploadEvent('[upload] metadata.insert_attempt', diagnostics, {
        insert_target: 'app.uploads', insert_kind: opts.kind,
        insert_volume_path: volumeFilePath, insert_size_bytes: parsed.fileBuffer.length,
        insert_client_ts: normalizedTimestamp.isoTimestamp,
      });

      try {
        await lakebase.query(
          `INSERT INTO app.uploads
             (id, kind, project_id, capture_session_id, paired_session_id, user_id,
              volume_path, mime_type, size_bytes, sha256_hex, original_filename, client_ts)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12::timestamptz)`,
          [uploadId, opts.kind, projectId, captureSessionId, pairedSessionId, userId,
           volumeFilePath, parsed.fileMimeType, parsed.fileBuffer.length, sha256Hash,
           parsed.clientFilename ?? null, normalizedTimestamp.isoTimestamp],
        );
        logUploadEvent('[upload] metadata.insert_succeeded', diagnostics, { insert_target: 'app.uploads', insert_volume_path: volumeFilePath });
      } catch (insertErr) {
        logUploadError('[upload] metadata.insert_failed', diagnostics, insertErr);
        try {
          await appkitFiles(opts.volumeKey).delete(relativePath);
          logUploadEvent('[upload] volume.deleted_after_metadata_failure', diagnostics);
        } catch (delErr) {
          logUploadError('[upload] delete_after_metadata_failure_failed', diagnostics, delErr, { volumeFilePath });
        }
        throw buildUploadAppError(500, 'Upload metadata persistence failed',
          'The file was stored, but upload metadata could not be persisted.',
          buildUploadContext(diagnostics, { error_code: 'UPLOAD_METADATA_INSERT_FAILED', error_message: getErrorMessage(insertErr) }));
      }

      // ── Step 9: 201 response ──────────────────────────────────────────────
      res.status(201).json({
        id: uploadId, kind: opts.kind, project_id: projectId, capture_session_id: captureSessionId,
        volume_path: volumeFilePath, mime_type: parsed.fileMimeType, size_bytes: parsed.fileBuffer.length,
        sha256_hex: sha256Hash, client_ts: normalizedTimestamp.isoTimestamp,
        client_ts_source: normalizedTimestamp.source, uploaded_at: new Date().toISOString(),
      });
    } catch (error) {
      const appError = toUploadAppError(error, req, diagnostics);
      logUploadError('[upload] request.failed', diagnostics, appError, { path: req.path });
      next(appError);
    }
  };
}

// ── Public registration entry point ──────────────────────────────────────────

export default function registerUploads(ctx: AppKitContext): void {
  // AppKit files plugin — accessed via dynamic key because PluginMap name typing
  // uses generic `string` rather than literal "files", preventing structural match.
  const appkitFiles = (ctx as unknown as { files: AppKitFiles }).files;
  const { lakebase } = ctx;

  ctx.server.extend((app) => {
    app.post(
      '/api/captures/:capture_session_id/audio',
      iosAuth({ lakebase }),
      createUploadHandler(
        { kind: 'audio', volumeKey: 'session_audio', volumeEnvVar: 'LAKELOOM_AUDIO_VOLUME_PATH', allowedMimes: ['audio/wav', 'audio/m4a', 'audio/mp4'], resolveContext: resolveCaptureContext },
        lakebase, appkitFiles,
      ),
    );

    app.post(
      '/api/captures/:capture_session_id/screenshots',
      iosAuth({ lakebase }),
      createUploadHandler(
        { kind: 'screenshot', volumeKey: 'screenshots', volumeEnvVar: 'LAKELOOM_SCREENSHOT_VOLUME_PATH', allowedMimes: ['image/png', 'image/jpeg'], resolveContext: resolveCaptureContext },
        lakebase, appkitFiles,
      ),
    );

    app.post(
      '/api/captures/:capture_session_id/photos',
      iosAuth({ lakebase }),
      createUploadHandler(
        { kind: 'photo', volumeKey: 'screenshots', volumeEnvVar: 'LAKELOOM_PHOTO_VOLUME_PATH', allowedMimes: ['image/png', 'image/jpeg'], resolveContext: resolveCaptureContext },
        lakebase, appkitFiles,
      ),
    );

    app.post(
      '/api/projects/:project_id/documents',
      iosAuth({ lakebase }),
      createUploadHandler(
        { kind: 'document', volumeKey: 'documents', volumeEnvVar: 'LAKELOOM_DOCUMENT_VOLUME_PATH', allowedMimes: ['application/pdf', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'], resolveContext: resolveProjectContext },
        lakebase, appkitFiles,
      ),
    );
  });
}
