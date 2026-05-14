/**
 * Migration 002: Create capture_sessions table.
 *
 * Tracks the lifecycle of a recording session (audio + screenshots + transcript).
 * Each capture belongs to a project and is created by a paired iOS device.
 *
 * State machine: 'active' → 'completed' | 'cancelled'
 * Once completed, no further uploads are accepted for this capture.
 *
 * Design rationale:
 *   - No FK to app.projects or app.paired_sessions (soft references only).
 *     Avoids cascade issues on tenant scrubs; audit value outlives the device.
 *   - REPLICA IDENTITY FULL enables Lakehouse Sync CDC into Delta.
 *   - Partial indexes (WHERE revoked_at IS NULL) keep the hot path fast.
 *
 * See: architecture/hi_genie/2026-05-13_upload-traceability-and-capture-sessions.md
 */

import type { Migration } from './migrate';

export const migration002: Migration = {
  name: '002_capture_sessions',
  up: `
    CREATE TABLE IF NOT EXISTS app.capture_sessions (
      id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      project_id                    UUID NOT NULL,
      created_by_user_id            TEXT NOT NULL,
      created_by_paired_session_id  UUID NOT NULL,
      device_label                  TEXT,
      state                         TEXT NOT NULL DEFAULT 'active',
      label                         TEXT,
      started_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
      ended_at                      TIMESTAMPTZ,
      revoked_at                    TIMESTAMPTZ
    );

    -- Project listing: "show me all captures for this project"
    CREATE INDEX IF NOT EXISTS idx_capture_sessions_project
      ON app.capture_sessions (project_id)
      WHERE revoked_at IS NULL;

    -- User history: "show me my recent captures" (sorted by start time)
    CREATE INDEX IF NOT EXISTS idx_capture_sessions_user
      ON app.capture_sessions (created_by_user_id, started_at DESC)
      WHERE revoked_at IS NULL;

    -- Device audit: "which captures came from this paired device?"
    CREATE INDEX IF NOT EXISTS idx_capture_sessions_device
      ON app.capture_sessions (created_by_paired_session_id)
      WHERE revoked_at IS NULL;

    -- Active captures: upload handler checks state = 'active' on every upload
    CREATE INDEX IF NOT EXISTS idx_capture_sessions_active
      ON app.capture_sessions (state, started_at DESC)
      WHERE revoked_at IS NULL AND state = 'active';

    -- Enable replica identity for Lakehouse Sync (full CDC rows)
    ALTER TABLE app.capture_sessions REPLICA IDENTITY FULL;
  `,
};
