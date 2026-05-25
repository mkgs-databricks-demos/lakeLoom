/**
 * Migration 017: Add updated_at column to capture_sessions table.
 *
 * The PATCH /api/v1/captures/:id/label handler attempts to SET updated_at = NOW()
 * but this column was never defined in migration 002. Reported by Isaac (iOS)
 * in hi_genie/2026-05-25_capture-label-patch-500.md.
 */

import type { Migration } from './migrate';

export const migration017: Migration = {
  name: '017_capture_sessions_updated_at',
  up: `ALTER TABLE app.capture_sessions ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ;`,
};
