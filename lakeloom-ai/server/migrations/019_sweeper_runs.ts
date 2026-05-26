import type { Migration } from './migrate';

export const migration019: Migration = {
  name: '019_sweeper_runs',
  up: `
    CREATE TABLE IF NOT EXISTS app.sweeper_runs (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      completed_at TIMESTAMPTZ,
      orphan_count INTEGER NOT NULL DEFAULT 0,
      bytes_reclaimed BIGINT NOT NULL DEFAULT 0,
      files_deleted INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'running',
      error_message TEXT
    );
  `,
};
