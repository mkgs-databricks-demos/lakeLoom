/**
 * Migration 008: Add device_id column to paired_sessions, capture_sessions, and uploads.
 *
 * Per device-id-contract-correction (2026-05-23):
 *   - device_id is a stable keychain-persisted UUID v4 identifying the physical
 *     iOS device. It survives re-pair, sign-out, and generally reinstall.
 *   - All iOS→App endpoints will send device_id in the request body.
 *   - device_label remains the single source of truth in paired_sessions only;
 *     downstream tables reference device_id and JOIN for the label when needed.
 *
 * The column is nullable because:
 *   1. Existing rows predate the field (backward compatibility).
 *   2. The field is .optional() in Zod schemas until Isaac's PR 8a-2 ships
 *      (all current iOS builds omit it).
 *
 * Once PR 8a-2 is confirmed on all clients, consider a follow-up migration to
 * add NOT NULL with a DEFAULT or backfill.
 */

import type { Migration } from './migrate';

export const migration008: Migration = {
  name: '008_device_id',
  up: `
    -- paired_sessions: device_id is the stable identity key for the physical device
    ALTER TABLE app.paired_sessions
      ADD COLUMN IF NOT EXISTS device_id UUID;

    -- capture_sessions: which device started this capture
    ALTER TABLE app.capture_sessions
      ADD COLUMN IF NOT EXISTS device_id UUID;

    -- uploads: which device uploaded this file
    ALTER TABLE app.uploads
      ADD COLUMN IF NOT EXISTS device_id UUID;

    -- Index: look up all sessions/captures/uploads from a specific device
    CREATE INDEX IF NOT EXISTS idx_paired_sessions_device_id
      ON app.paired_sessions (device_id)
      WHERE device_id IS NOT NULL AND revoked_at IS NULL;

    CREATE INDEX IF NOT EXISTS idx_capture_sessions_device_id
      ON app.capture_sessions (device_id)
      WHERE device_id IS NOT NULL AND revoked_at IS NULL;

    CREATE INDEX IF NOT EXISTS idx_uploads_device_id
      ON app.uploads (device_id)
      WHERE device_id IS NOT NULL AND revoked_at IS NULL;
  `,
};
