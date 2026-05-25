/**
 * Migration 014: Relax paired_session_id constraint on uploads.
 *
 * Browser uploads (client_type = 'web') don't originate from a paired iOS
 * device session - they are initiated directly by an authenticated user in
 * the browser. The column was originally NOT NULL because only iOS devices
 * could upload. Phase 4 browser uploads need this column to accept NULL.
 *
 * Safe to apply:
 * - No data backfill needed (all existing rows already have a value).
 * - The partial index on paired_session_id handles NULLs gracefully.
 * - Application code already sets paired_session_id = null for web uploads.
 */

import type { Migration } from './migrate';

export const migration014: Migration = {
  name: '014_nullable_paired_session_id',
  up: `
    ALTER TABLE app.uploads
      ALTER COLUMN paired_session_id DROP NOT NULL;
  `,
};
