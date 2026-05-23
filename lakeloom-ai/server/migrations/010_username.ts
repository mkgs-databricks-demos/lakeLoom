/**
 * Migration 010: Add username column to paired_sessions.
 *
 * Stores the human-readable Databricks employee email (e.g. "isaac.ramirez@databricks.com")
 * at pairing time. This is the user who generated the QR code in the Databricks App UI —
 * i.e., the employee whose device is being paired.
 *
 * Enables direct attribution on uploads, captures, and transcript events without
 * cross-table lookups: join via paired_session_id → paired_sessions.username.
 *
 * Populated at QR generation (INSERT) from the x-forwarded-email auth header.
 * Nullable for backward compatibility with existing paired sessions.
 */

import type { Migration } from './migrate';

export const migration010: Migration = {
  name: '010_username',
  up: `
    ALTER TABLE app.paired_sessions
      ADD COLUMN IF NOT EXISTS username TEXT;

    COMMENT ON COLUMN app.paired_sessions.username IS
      'Databricks employee email who generated the QR code (from x-forwarded-email auth header)';

    CREATE INDEX IF NOT EXISTS idx_paired_sessions_username
      ON app.paired_sessions (username)
      WHERE username IS NOT NULL AND revoked_at IS NULL;
  `,
};
