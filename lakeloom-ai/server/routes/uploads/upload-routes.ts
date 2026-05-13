/**
 * Binary upload routes — iOS-authenticated, App-proxied to UC Volumes.
 *
 * Per ADR-001, all binary uploads route through the App:
 *   iOS → App endpoint (Layer 0+1 auth) → App backend → UC Volume write (App SPN)
 *
 * Endpoints:
 *   POST /api/sessions/:session_id/audio        — Session audio recordings
 *   POST /api/sessions/:session_id/screenshots  — Session screen captures
 *   POST /api/projects/:project_id/documents    — Project reference documents
 *
 * Filename convention: TBD — using crypto.randomUUID() + ext as provisional placeholder.
 * Will be finalized with Isaac after auth is working end-to-end.
 */

import { randomUUID } from 'node:crypto';
import { Readable } from 'node:stream';
import type { Application, Request, Response, NextFunction } from 'express';
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

// ── Volume paths from environment ────────────────────────────────────────────

function getVolumePath(volumeEnv: string): string {
  const path = process.env[volumeEnv];
  if (!path) {
    throw new Error(`Environment variable ${volumeEnv} is not set.`);
  }
  return path;
}

// ── Upload handler factory ───────────────────────────────────────────────────

function createUploadHandler(opts: {
  volumeEnvVar: string;
  pathBuilder: (req: Request, filename: string) => string;
}) {
  return async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      // For now, expect raw binary body with Content-Type and X-Filename headers.
      // TODO: Switch to multipart (busboy) once filename convention is finalized.
      const contentType = req.headers['content-type'] ?? 'application/octet-stream';
      const originalName = req.headers['x-lakeloom-filename'] as string | undefined;
      const ext = originalName?.split('.').pop() ?? 'bin';

      // Provisional filename: random UUID + original extension
      // Since each upload creates a unique name, collisions are impossible.
      const filename = `${randomUUID()}.${ext}`;
      const volumePath = getVolumePath(opts.volumeEnvVar);
      const fullPath = `${volumePath}/${opts.pathBuilder(req, filename)}`;

      // Collect request body as buffer
      const chunks: Buffer[] = [];
      for await (const chunk of req) {
        chunks.push(typeof chunk === 'string' ? Buffer.from(chunk) : chunk);
      }
      const body = Buffer.concat(chunks);

      if (body.length === 0) {
        throw validationError('Request body is empty. Provide file data.');
      }

      // Write to UC Volume via Databricks SDK Files API
      // Convert Buffer to a ReadableStream for the SDK's upload method.
      const wc = new WorkspaceClient({ host: process.env.DATABRICKS_HOST });
      const stream = Readable.toWeb(Readable.from(body)) as ReadableStream;
      await (wc.files as any).upload(fullPath, stream);

      res.status(201).json({
        filename,
        path: fullPath,
        size: body.length,
        content_type: contentType,
      });
    } catch (err) {
      next(err);
    }
  };
}

// ── Route setup ──────────────────────────────────────────────────────────────

export async function setupUploadRoutes(appkit: AppKitContext): Promise<void> {
  const { lakebase } = appkit;
  const auth = iosAuth({ lakebase });

  appkit.server.extend((app) => {
    // Audio uploads
    app.post('/api/sessions/:session_id/audio', auth, createUploadHandler({
      volumeEnvVar: 'DATABRICKS_VOLUME_SESSION_AUDIO',
      pathBuilder: (req, filename) => `${req.params.session_id}/${filename}`,
    }));

    // Screenshot uploads
    app.post('/api/sessions/:session_id/screenshots', auth, createUploadHandler({
      volumeEnvVar: 'DATABRICKS_VOLUME_SCREENSHOTS',
      pathBuilder: (req, filename) => `${req.params.session_id}/${filename}`,
    }));

    // Document uploads
    app.post('/api/projects/:project_id/documents', auth, createUploadHandler({
      volumeEnvVar: 'DATABRICKS_VOLUME_DOCUMENTS',
      pathBuilder: (req, filename) => `${req.params.project_id}/${filename}`,
    }));
  });
}
