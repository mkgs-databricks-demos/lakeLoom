/**
 * Migration 003: Create uploads table.
 *
 * Per-file metadata for every binary uploaded through the App (audio,
 * screenshots, documents). Each row maps 1:1 to a file on a UC Volume.
 *
 * Design rationale:
 *   - id is UUIDv7 (app-generated, time-ordered) — no DEFAULT. The upload_id
 *     doubles as the filename root on the UC Volume for traceability.
 *   - capture_session_id is nullable: documents belong to a project directly,
 *     not a specific capture session.
 *   - user_id is denormalized from paired_sessions for query speed (the most
 *     common access pattern is "everything user X uploaded").
 *   - volume_path UNIQUE prevents duplicate rows for the same physical file.
 *   - No FK constraints — soft references only. See 002 rationale.
 *   - REPLICA IDENTITY FULL enables Lakehouse Sync CDC into Delta.
 *   - Partial indexes (WHERE revoked_at IS NULL) keep the hot path fast.
 *
 * See: architecture/hi_genie/2026-05-13_upload-traceability-and-capture-sessions.md
 */

import type { Migration } from './migrate';

export const migration003: Migration = {
  name: '003_uploads',
  up: `
    CREATE TABLE IF NOT EXISTS app.uploads (
      id                  UUID PRIMARY KEY,
      kind                TEXT NOT NULL,
      project_id          UUID NOT NULL,
      capture_session_id  UUID,
      paired_session_id   UUID NOT NULL,
      user_id             TEXT NOT NULL,
      volume_path         TEXT NOT NULL UNIQUE,
      mime_type           TEXT NOT NULL,
      size_bytes          BIGINT NOT NULL,
      sha256_hex          TEXT NOT NULL,
      original_filename   TEXT,
      client_ts           TIMESTAMPTZ,
      uploaded_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
      revoked_at          TIMESTAMPTZ
    );

    -- Project listing: "show me all uploads for this project"
    CREATE INDEX IF NOT EXISTS idx_uploads_project
      ON app.uploads (project_id)
      WHERE revoked_at IS NULL;

    -- Capture listing: "show me all files in this capture session"
    CREATE INDEX IF NOT EXISTS idx_uploads_capture
      ON app.uploads (capture_session_id)
      WHERE revoked_at IS NULL AND capture_session_id IS NOT NULL;

    -- User history: "show me everything this user uploaded" (sorted by time)
    CREATE INDEX IF NOT EXISTS idx_uploads_user_time
      ON app.uploads (user_id, uploaded_at DESC)
      WHERE revoked_at IS NULL;

    -- Device audit: "which uploads came from this paired device?"
    CREATE INDEX IF NOT EXISTS idx_uploads_paired_session
      ON app.uploads (paired_session_id)
      WHERE revoked_at IS NULL;

    -- Kind + time: "show me all screenshots this week" or "all audio last month"
    CREATE INDEX IF NOT EXISTS idx_uploads_kind_time
      ON app.uploads (kind, uploaded_at DESC)
      WHERE revoked_at IS NULL;

    -- Duplicate detection: "has this exact file already been uploaded?"
    CREATE INDEX IF NOT EXISTS idx_uploads_sha256
      ON app.uploads (sha256_hex)
      WHERE revoked_at IS NULL;

    -- Enable replica identity for Lakehouse Sync (full CDC rows)
    ALTER TABLE app.uploads REPLICA IDENTITY FULL;
  `,
};
