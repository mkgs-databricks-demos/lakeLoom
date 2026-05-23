/**
 * Migration 009: Add client_type column to uploads.
 *
 * Discriminates upload provenance: 'ios' (paired device via iosAuth) vs 'web'
 * (workspace user via Databricks App UI). Useful for analytics, debugging, and
 * auditing which interface produced a given file.
 *
 * Nullable TEXT rather than an enum for extensibility — future clients (CLI,
 * API automation, etc.) can introduce new values without a migration.
 *
 * Existing rows will have NULL — a backfill isn't needed since all historical
 * uploads are implicitly 'ios' (the web upload path doesn't exist yet).
 */

import type { Migration } from './migrate';

export const migration009: Migration = {
  name: '009_client_type',
  up: `
    ALTER TABLE app.uploads
      ADD COLUMN IF NOT EXISTS client_type TEXT;

    COMMENT ON COLUMN app.uploads.client_type IS
      'Upload source: ios (paired device), web (Databricks App UI), or future client types';
  `,
};
