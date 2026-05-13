/**
 * Migration 001: Create paired_sessions table.
 *
 * Stores QR-pair sessions for iOS device authentication.
 * Schema matches Isaac's spec in hi_genie/qr-pair-auth-model.md.
 *
 * Indexes are partial (WHERE revoked_at IS NULL) to keep the hot path fast
 * and avoid indexing soft-deleted rows.
 */

import type { Migration } from './migrate';

export const migration001: Migration = {
  name: '001_paired_sessions',
  up: `
    CREATE TABLE IF NOT EXISTS app.paired_sessions (
      id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      token_hash      BYTEA NOT NULL UNIQUE,
      user_id         TEXT NOT NULL,
      workspace_id    TEXT NOT NULL,
      device_pubkey   BYTEA,
      device_label    TEXT,
      paired_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
      first_seen_at   TIMESTAMPTZ,
      last_seen_at    TIMESTAMPTZ,
      expires_at      TIMESTAMPTZ NOT NULL,
      revoked_at      TIMESTAMPTZ
    );

    -- Hot-path index: every iOS request looks up by token_hash
    CREATE INDEX IF NOT EXISTS idx_paired_sessions_token_hash
      ON app.paired_sessions (token_hash)
      WHERE revoked_at IS NULL;

    -- User device listing: browser "My paired devices" page
    CREATE INDEX IF NOT EXISTS idx_paired_sessions_user
      ON app.paired_sessions (user_id, workspace_id)
      WHERE revoked_at IS NULL;

    -- Expiry cleanup: background job or query to find stale sessions
    CREATE INDEX IF NOT EXISTS idx_paired_sessions_expires
      ON app.paired_sessions (expires_at)
      WHERE revoked_at IS NULL;

    -- Enable replica identity for Lakehouse Sync (SCD Type 2 CDC)
    ALTER TABLE app.paired_sessions REPLICA IDENTITY FULL;
  `,
};
