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

type DirectoryCreateRequest =
  | string
  | { directoryPath: string }
  | { directory_path: string }
  | { path: string };

type FilesApi = {
  upload(path: string, contents: Readable, options?: { overwrite?: boolean }): Promise<unknown>;
  delete(path: string): Promise<unknown>;
  createDirectory?(request: DirectoryCreateRequest): Promise<unknown>;
  create_directory?(request: DirectoryCreateRequest): Promise<unknown>;
};

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
        {
          error_code: 'UPLOAD_INVALID_ROUTE_PARAM',
          route_param: context,
          route_param_count: value.length,
        },
      );
    }

    return requireNonEmptyString(value[0], `Route parameter '${context}'`);
  }

  return requireNonEmptyString(value, `Route parameter '${context}'`);
}

function toCanonicalVolumePath(path: string): string {
  const withoutDbfsPrefix = path.startsWith('dbfs:/') ? path.slice('dbfs:'.length) : path;
  const normalizedSlashes = withoutDbfsPrefix.replace(/\/{2,}/g, '/');
  return normalizedSlashes.length > 1 ? normalizedSlashes.replace(/\/+$/, '') : normalizedSlashes;
}

function requireCanonicalVolumePath(path: unknown, context: string): string {
  const rawPath = requireNonEmptyString(path, `Upload ${context} path`);
  const canonicalPath = toCanonicalVolumePath(rawPath);

  if (!canonicalPath.startsWith('/Volumes/')) {
    throw new Error(`Upload ${context} path must be rooted under /Volumes: ${rawPath}`);
  }

  return canonicalPath;
}

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
  return requireCanonicalVolumePath(path, `storage volume '${volumeEnv}'`);
}

function requireUploadPathComponent(
  value: unknown,
  context: string,
  options?: { allowDots?: boolean },
): string {
  const trimmed = requireNonEmptyString(value, `Upload ${context}`);
  const normalized = trimmed.replace(/^\/+|\/+$/g, '');

  if (normalized.length === 0) {
    throw new Error(`Upload ${context} cannot be empty after trimming slashes.`);
  }

  if (normalized.includes('/')) {
    throw new Error(`Upload ${context} must not contain '/': ${trimmed}`);
  }

  if (normalized === '.' || normalized === '..') {
    throw new Error(`Upload ${context} must not be '.' or '..'.`);
  }

  if (options?.allowDots === false && normalized.includes('.')) {
    throw new Error(`Upload ${context} must not contain '.': ${trimmed}`);
  }

  return normalized;
}

function requireUploadFileExtension(value: unknown): string {
  const trimmed = requireNonEmptyString(value, 'Upload file extension');
  const normalized = trimmed.replace(/^\.+|\.+$/g, '').toLowerCase();

  if (normalized.length === 0) {
    throw new Error('Upload file extension cannot be empty after trimming dots.');
  }

  if (normalized.includes('/') || normalized.includes('\\')) {
    throw new Error(`Upload file extension must not contain path separators: ${trimmed}`);
  }

  if (normalized.includes('.')) {
    throw new Error(`Upload file extension must not contain '.': ${trimmed}`);
  }

  return normalized;
}

function joinVolumePath(basePath: unknown, ...pathComponents: string[]): string {
  const canonicalBasePath = requireCanonicalVolumePath(basePath, 'base');
  const normalizedComponents = pathComponents.map((component, index) =>
    requireUploadPathComponent(component, `path component ${index + 1}`),
  );

  const joinedPath = [canonicalBasePath, ...normalizedComponents].join('/');
  return requireCanonicalVolumePath(joinedPath, 'path');
}

type ResolvedUploadFilePath = {
  canonicalPath: string;
  volumeBasePath: string;
  projectId: string;
  captureSessionId: string | null;
  uploadId: string;
  extension: string;
  fileName: string;
};

function buildUploadFilePath(params: {
  volumeBasePath: unknown;
  projectId: unknown;
  captureSessionId?: unknown;
  uploadId: unknown;
  extension: unknown;
}): ResolvedUploadFilePath {
  const volumeBasePath = requireCanonicalVolumePath(params.volumeBasePath, 'storage volume');
  const projectId = requireUploadPathComponent(params.projectId, 'project_id');
  const captureSessionId =
    params.captureSessionId == null
      ? null
      : requireUploadPathComponent(params.captureSessionId, 'capture_session_id');
  const uploadId = requireUploadPathComponent(params.uploadId, 'upload_id');
  const extension = requireUploadFileExtension(params.extension);
  const fileName = requireUploadPathComponent(`${uploadId}.${extension}`, 'file name');
  const canonicalPath = captureSessionId
    ? joinVolumePath(volumeBasePath, projectId, captureSessionId, fileName)
    : joinVolumePath(volumeBasePath, projectId, fileName);

  return {
    canonicalPath,
    volumeBasePath,
    projectId,
    captureSessionId,
    uploadId,
    extension,
    fileName,
  };
}

function requireUploadBuffer(fileBuffer: unknown): Buffer {
  if (!Buffer.isBuffer(fileBuffer)) {
    throw new Error('Upload file contents must be provided as a Buffer.');
  }

  if (fileBuffer.length === 0) {
    throw new Error('Upload file contents cannot be empty.');
  }

  return fileBuffer;
}

function createUploadStream(fileBuffer: Buffer): Readable {
  return Readable.from(fileBuffer);
}

function buildVolumePathCandidates(path: unknown, context = 'path'): string[] {
  return [requireCanonicalVolumePath(path, context)];
}

function maybeBuildVolumePathCandidates(path: unknown, context = 'path'): string[] | null {
  try {
    return buildVolumePathCandidates(path, context);
  } catch {
    return null;
  }
}

function getParentDirectory(path: unknown): string {
  const normalizedPath = requireCanonicalVolumePath(path, 'file');
  const lastSlashIdx = normalizedPath.lastIndexOf('/');
  if (lastSlashIdx <= 0) {
    throw new Error(`Unable to determine parent directory for path: ${normalizedPath}`);
  }

  const directoryPath = normalizedPath.slice(0, lastSlashIdx);
  return requireCanonicalVolumePath(directoryPath, 'directory');
}

function getDirectoryChain(directoryPath: unknown): string[] {
  const normalizedDirectoryPath = requireCanonicalVolumePath(directoryPath, 'directory');
  const relativeDirectory = normalizedDirectoryPath.slice('/Volumes/'.length);
  const segments = relativeDirectory.split('/').filter((segment) => segment.length > 0);

  if (segments.length < 3) {
    throw new Error(`Volume directory path must include catalog/schema/volume: ${normalizedDirectoryPath}`);
  }

  const directoryChain: string[] = [];
  for (let idx = 3; idx <= segments.length; idx += 1) {
    directoryChain.push(`/Volumes/${segments.slice(0, idx).join('/')}`);
  }
  return directoryChain;
}

function buildDirectoryCreateRequests(
  directoryPath: string,
  method: 'createDirectory' | 'create_directory',
): DirectoryCreateRequest[] {
  const normalizedDirectoryPath = requireCanonicalVolumePath(directoryPath, 'directory');
  const objectRequests: DirectoryCreateRequest[] = [
    { directoryPath: normalizedDirectoryPath },
    { directory_path: normalizedDirectoryPath },
    { path: normalizedDirectoryPath },
  ];

  return method === 'create_directory'
    ? [...objectRequests, normalizedDirectoryPath]
    : [normalizedDirectoryPath, ...objectRequests];
}

function normalizeSdkError(error: unknown): Record<string, unknown> {
  if (error instanceof AppError) {
    return {
      error_name: error.name,
      error_message: error.message,
      error_status_code: error.status,
      error_details: error.extra,
      ...(error.stack ? { error_stack: error.stack } : {}),
    };
  }

  if (error instanceof Error) {
    return {
      error_name: error.name,
      error_message: error.message,
      error_stack: error.stack,
      ...(('statusCode' in error && typeof error.statusCode !== 'undefined')
        ? { error_status_code: (error as { statusCode?: unknown }).statusCode }
        : {}),
      ...(('errorCode' in error && typeof error.errorCode !== 'undefined')
        ? { error_code_detail: (error as { errorCode?: unknown }).errorCode }
        : {}),
      ...(('details' in error && typeof error.details !== 'undefined')
        ? { error_details: (error as { details?: unknown }).details }
        : {}),
      ...(('cause' in error && typeof error.cause !== 'undefined')
        ? { error_cause: (error as { cause?: unknown }).cause }
        : {}),
    };
  }

  return {
    error_message: String(error),
    error_value: error,
  };
}

function isAlreadyExistsError(error: unknown): boolean {
  const details = normalizeSdkError(error);
  const errorMessage = String(details.error_message ?? '').toLowerCase();
  const statusCode = details.error_status_code;
  const errorCode = String(details.error_code_detail ?? '').toUpperCase();

  return (
    statusCode === 409 ||
    errorCode.includes('ALREADY_EXISTS') ||
    errorMessage.includes('already exists') ||
    errorMessage.includes('resource already exists')
  );
}

async function createVolumeDirectory(filesApi: FilesApi, directoryPath: string): Promise<void> {
  const directoryMethods: Array<{
    method: 'createDirectory' | 'create_directory';
    fn: (request: DirectoryCreateRequest) => Promise<unknown>;
  }> = [];

  if (typeof filesApi.createDirectory === 'function') {
    directoryMethods.push({
      method: 'createDirectory',
      fn: (request: DirectoryCreateRequest) => filesApi.createDirectory!(request),
    });
  }

  if (typeof filesApi.create_directory === 'function') {
    directoryMethods.push({
      method: 'create_directory',
      fn: (request: DirectoryCreateRequest) => filesApi.create_directory!(request),
    });
  }

  if (directoryMethods.length === 0) {
    throw new Error('Workspace Files API does not expose a directory creation method.');
  }

  const candidatePaths = buildVolumePathCandidates(directoryPath, 'directory');
  const attempts: Array<Record<string, unknown>> = [];
  let lastError: unknown;

  for (const candidatePath of candidatePaths) {
    for (const directoryMethod of directoryMethods) {
      for (const requestPayload of buildDirectoryCreateRequests(candidatePath, directoryMethod.method)) {
        try {
          await directoryMethod.fn(requestPayload);
          return;
        } catch (error) {
          lastError = error;
          attempts.push({
            attempted_path: candidatePath,
            attempted_method: directoryMethod.method,
            attempted_request: requestPayload,
            ...normalizeSdkError(error),
          });
        }
      }
    }
  }

  const aggregatedError = new Error(`Workspace Files API directory creation failed for: ${directoryPath}`);
  (aggregatedError as Error & { details?: unknown; cause?: unknown }).details = {
    original_path: directoryPath,
    attempted_paths: candidatePaths,
    attempts,
  };
  (aggregatedError as Error & { details?: unknown; cause?: unknown }).cause = lastError;
  throw aggregatedError;
}

async function uploadVolumeFile(
  filesApi: FilesApi,
  path: unknown,
  fileBuffer: unknown,
  options?: { overwrite?: boolean },
): Promise<void> {
  const candidatePaths = buildVolumePathCandidates(path, 'file');
  const uploadBuffer = requireUploadBuffer(fileBuffer);
  const attempts: Array<Record<string, unknown>> = [];
  let lastError: unknown;

  for (const candidatePath of candidatePaths) {
    try {
      await filesApi.upload(candidatePath, createUploadStream(uploadBuffer), options);
      return;
    } catch (error) {
      lastError = error;
      attempts.push({
        attempted_path: candidatePath,
        upload_content_type: 'readable',
        upload_size_bytes: uploadBuffer.length,
        ...normalizeSdkError(error),
      });
    }
  }

  const aggregatedError = new Error(`Workspace Files API upload failed for: ${String(path)}`);
  (aggregatedError as Error & { details?: unknown; cause?: unknown }).details = {
    original_path: path,
    attempted_paths: candidatePaths,
    upload_content_type: 'readable',
    upload_size_bytes: uploadBuffer.length,
    attempts,
  };
  (aggregatedError as Error & { details?: unknown; cause?: unknown }).cause = lastError;
  throw aggregatedError;
}

async function deleteVolumeFile(filesApi: FilesApi, path: string): Promise<void> {
  const candidatePaths = buildVolumePathCandidates(path, 'file');
  const attempts: Array<Record<string, unknown>> = [];
  let lastError: unknown;

  for (const candidatePath of candidatePaths) {
    try {
      await filesApi.delete(candidatePath);
      return;
    } catch (error) {
      lastError = error;
      attempts.push({
        attempted_path: candidatePath,
        ...normalizeSdkError(error),
      });
    }
  }

  const aggregatedError = new Error(`Workspace Files API delete failed for: ${path}`);
  (aggregatedError as Error & { details?: unknown; cause?: unknown }).details = {
    original_path: path,
    attempted_paths: candidatePaths,
    attempts,
  };
  (aggregatedError as Error & { details?: unknown; cause?: unknown }).cause = lastError;
  throw aggregatedError;
}

async function ensureVolumeDirectory(filesApi: FilesApi, directoryPath: string): Promise<void> {
  const directoryChain = getDirectoryChain(directoryPath);
  for (const currentDirectory of directoryChain) {
    try {
      await createVolumeDirectory(filesApi, currentDirectory);
    } catch (error) {
      if (!isAlreadyExistsError(error)) {
        throw error;
      }
    }
  }
}

// ── Multipart parsing helper ─────────────────────────────────────────────────

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
  if (!/^\d+$/.test(normalized)) {
    return {
      isoTimestamp: new Date().toISOString(),
      source: 'server',
      fallbackReason: 'client_ts_not_integer',
    };
  }

  const asNumber = Number(normalized);
  const millis = normalized.length <= 10 ? asNumber * 1000 : asNumber;
  const parsed = new Date(millis);

  if (Number.isNaN(parsed.getTime())) {
    return {
      isoTimestamp: new Date().toISOString(),
      source: 'server',
      fallbackReason: 'client_ts_invalid',
    };
  }

  return { isoTimestamp: parsed.toISOString(), source: 'client' };
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
      ...normalizeSdkError(error),
      ...(error instanceof AppError ? error.extra : {}),
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

    busboy.on('field', (fieldname, value) => {
      if (fieldname === 'client_ts') {
        clientTs = value;
      }
      if (fieldname === 'client_filename') {
        clientFilename = value;
      }
      if (fieldname === 'sha256_hex') {
        clientSha256 = value;
      }
    });

    busboy.on('error', (parseErr) => {
      reject(
        buildUploadAppError(
          400,
          'Invalid multipart body',
          'The multipart request body could not be parsed.',
          {
            error_code: 'UPLOAD_MULTIPART_PARSE_FAILED',
            error_message: getErrorMessage(parseErr),
          },
        ),
      );
    });

    busboy.on('finish', () => {
      if (!fileReceived || chunks.length === 0) {
        reject(
          buildUploadAppError(
            400,
            'Missing upload file',
            'A non-empty file field is required.',
            { error_code: 'UPLOAD_FILE_REQUIRED' },
          ),
        );
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

    if (bufferedBody) {
      Readable.from(bufferedBody).pipe(busboy);
      return;
    }

    req.pipe(busboy);
  });
}

// ── Route context lookups ────────────────────────────────────────────────────

async function resolveCaptureContext(
  req: Request,
  lakebase: LakebaseClient,
): Promise<{ projectId: string; captureSessionId: string }> {
  const captureSessionId = requireSingleRouteParam(req.params.capture_session_id, 'capture_session_id');
  const result = await lakebase.query(
    `SELECT project_id
       FROM app.capture_sessions
      WHERE id = $1::uuid
        AND status = 'active'
      LIMIT 1`,
    [captureSessionId],
  );

  const row = result.rows[0];
  if (!row) {
    throw buildUploadAppError(
      404,
      'Capture session not found',
      `No active capture session '${captureSessionId}' was found.`,
      { error_code: 'UPLOAD_CAPTURE_NOT_FOUND', capture_session_id: captureSessionId },
    );
  }

  return { projectId: String(row.project_id), captureSessionId };
}

async function resolveProjectContext(
  req: Request,
  lakebase: LakebaseClient,
): Promise<{ projectId: string; captureSessionId: null }> {
  const projectId = requireSingleRouteParam(req.params.project_id, 'project_id');
  const result = await lakebase.query(
    `SELECT id
       FROM app.projects
      WHERE id = $1::uuid
      LIMIT 1`,
    [projectId],
  );

  const row = result.rows[0];
  if (!row) {
    throw buildUploadAppError(
      404,
      'Project not found',
      `Project '${projectId}' does not exist.`,
      { error_code: 'UPLOAD_PROJECT_NOT_FOUND', project_id: projectId },
    );
  }

  return { projectId, captureSessionId: null };
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
    const filesApi = wc.files as unknown as FilesApi;

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
          `MIME type '${parsed.fileMimeType}' is not supported.`,
          buildUploadContext(diagnostics, {
            error_code: 'UPLOAD_UNSUPPORTED_MIME',
          }),
        );
      }

      // Compute SHA-256 now (still uses buffer; write is independent)
      const sha256Hash = createHash('sha256').update(parsed.fileBuffer).digest('hex');
      diagnostics.sha256Hex = sha256Hash;

      // ── Step 6: Build path and write to UC Volume ────────────────────────
      let resolvedUploadPath: ResolvedUploadFilePath | undefined;
      try {
        resolvedUploadPath = buildUploadFilePath({
          volumeBasePath: getVolumePath(opts.volumeEnvVar),
          projectId,
          captureSessionId,
          uploadId,
          extension: ext,
        });
        volumeFilePath = resolvedUploadPath.canonicalPath;
        diagnostics.volumeFilePath = volumeFilePath;
        logUploadEvent('[upload] volume.path_resolved', diagnostics, {
          canonical_volume_path: volumeFilePath,
          volume_base_path: resolvedUploadPath.volumeBasePath,
          file_name: resolvedUploadPath.fileName,
          path_project_id: resolvedUploadPath.projectId,
          path_capture_session_id: resolvedUploadPath.captureSessionId,
          path_upload_id: resolvedUploadPath.uploadId,
          path_extension: resolvedUploadPath.extension,
        });
      } catch (pathErr) {
        throw buildUploadAppError(
          500,
          'Upload storage failed',
          'The upload destination path could not be derived from the request context.',
          buildUploadContext(diagnostics, {
            error_code: 'UPLOAD_VOLUME_PATH_INVALID',
            volume_env_var: opts.volumeEnvVar,
            raw_volume_base_path: process.env[opts.volumeEnvVar] ?? null,
            raw_project_id: projectId ?? null,
            raw_capture_session_id: captureSessionId ?? null,
            raw_upload_id: uploadId,
            raw_extension: ext,
            ...normalizeSdkError(pathErr),
          }),
        );
      }

      const volumeDirectory = getParentDirectory(volumeFilePath);
      try {
        await ensureVolumeDirectory(filesApi, volumeDirectory);
        logUploadEvent('[upload] volume.directory_ready', diagnostics, {
          volume_directory: volumeDirectory,
          volume_directory_candidates: maybeBuildVolumePathCandidates(volumeDirectory, 'directory'),
          canonical_volume_path: volumeFilePath,
          file_name: resolvedUploadPath?.fileName ?? null,
        });
      } catch (directoryErr) {
        throw buildUploadAppError(
          500,
          'Upload storage failed',
          'The upload destination directory could not be prepared on the configured storage volume.',
          buildUploadContext(diagnostics, {
            error_code: 'UPLOAD_VOLUME_DIRECTORY_CREATE_FAILED',
            volume_directory: volumeDirectory,
            volume_directory_candidates: maybeBuildVolumePathCandidates(volumeDirectory, 'directory'),
            canonical_volume_path: volumeFilePath,
            ...normalizeSdkError(directoryErr),
          }),
        );
      }

      logUploadEvent('[upload] volume.write_attempt', diagnostics, {
        canonical_volume_path: volumeFilePath,
        volume_path_candidates: maybeBuildVolumePathCandidates(volumeFilePath, 'file'),
        upload_content_type: 'readable',
        upload_size_bytes: parsed.fileBuffer.length,
        file_name: resolvedUploadPath?.fileName ?? null,
      });

      try {
        await uploadVolumeFile(filesApi, volumeFilePath, parsed.fileBuffer, { overwrite: false });
      } catch (volumeErr) {
        throw buildUploadAppError(
          500,
          'Upload storage failed',
          'The uploaded file could not be written to the configured storage volume.',
          buildUploadContext(diagnostics, {
            error_code: 'UPLOAD_VOLUME_WRITE_FAILED',
            volume_directory: volumeDirectory,
            canonical_volume_path: volumeFilePath,
            volume_path_candidates: maybeBuildVolumePathCandidates(volumeFilePath, 'file'),
            upload_content_type: 'readable',
            upload_size_bytes: parsed.fileBuffer.length,
            file_name: resolvedUploadPath?.fileName ?? null,
            ...normalizeSdkError(volumeErr),
          }),
        );
      }
      logUploadEvent('[upload] volume.write_succeeded', diagnostics, {
        canonical_volume_path: volumeFilePath,
        volume_path_candidates: maybeBuildVolumePathCandidates(volumeFilePath, 'file'),
        upload_content_type: 'readable',
        upload_size_bytes: parsed.fileBuffer.length,
        file_name: resolvedUploadPath?.fileName ?? null,
      });

      // ── Step 7: SHA-256 verification ─────────────────────────────────────
      if (parsed.clientSha256 && parsed.clientSha256 !== sha256Hash) {
        try {
          await deleteVolumeFile(filesApi, volumeFilePath);
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
          await deleteVolumeFile(filesApi, volumeFilePath);
          logUploadEvent('[upload] volume.deleted_after_metadata_failure', diagnostics);
        } catch (delErr) {
          logUploadError('[upload] delete_after_metadata_failure_failed', diagnostics, delErr, { volumeFilePath });
        }

        throw buildUploadAppError(
          500,
          'Upload metadata persistence failed',
          'The file was stored, but upload metadata could not be persisted.',
          buildUploadContext(diagnostics, {
            error_code: 'UPLOAD_METADATA_INSERT_FAILED',
            error_message: getErrorMessage(insertErr),
          }),
        );
      }

      // ── Step 9: 201 response ──────────────────────────────────────────────
      res.status(201).json({
        id: uploadId,
        kind: opts.kind,
        project_id: projectId,
        capture_session_id: captureSessionId,
        volume_path: volumeFilePath,
        mime_type: parsed.fileMimeType,
        size_bytes: parsed.fileBuffer.length,
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

// ── Public registration entry point ──────────────────────────────────────────

export default function registerUploads(ctx: AppKitContext): void {
  ctx.server.extend((app) => {
    // All upload endpoints are protected by iOS device-auth middleware
    app.post(
      '/api/captures/:capture_session_id/audio',
      iosAuth,
      createUploadHandler(
        {
          kind: 'audio',
          volumeEnvVar: 'LAKELOOM_AUDIO_VOLUME',
          allowedMimes: ['audio/wav', 'audio/m4a', 'audio/mp4'],
          resolveContext: resolveCaptureContext,
        },
        ctx.lakebase,
      ),
    );

    app.post(
      '/api/captures/:capture_session_id/screenshots',
      iosAuth,
      createUploadHandler(
        {
          kind: 'screenshot',
          volumeEnvVar: 'LAKELOOM_SCREENSHOT_VOLUME',
          allowedMimes: ['image/png', 'image/jpeg'],
          resolveContext: resolveCaptureContext,
        },
        ctx.lakebase,
      ),
    );

    app.post(
      '/api/captures/:capture_session_id/photos',
      iosAuth,
      createUploadHandler(
        {
          kind: 'photo',
          volumeEnvVar: 'LAKELOOM_SCREENSHOT_VOLUME',
          allowedMimes: ['image/png', 'image/jpeg'],
          resolveContext: resolveCaptureContext,
        },
        ctx.lakebase,
      ),
    );

    app.post(
      '/api/projects/:project_id/documents',
      iosAuth,
      createUploadHandler(
        {
          kind: 'document',
          volumeEnvVar: 'LAKELOOM_DOCUMENT_VOLUME',
          allowedMimes: [
            'application/pdf',
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
          ],
          resolveContext: resolveProjectContext,
        },
        ctx.lakebase,
      ),
    );
  });
}
