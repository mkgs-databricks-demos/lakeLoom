/**
 * Migration 016: Add updated_at column to uploads table.
 *
 * Required for CDF-based document edit detection. When the PUT /content
 * handler updates a file in-place, it now also sets updated_at = NOW()
 * so Lakehouse Sync propagates the change and CDF can detect it.
 */

import type { Migration } from './migrate';

export const migration016: Migration = {
  name: '016_uploads_updated_at',
  up: `ALTER TABLE app.uploads ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ;`,
};
