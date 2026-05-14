/**
 * Migration 004: Create projects table.
 *
 * Projects are the top-level organizational unit for lakeLoom. Both iOS and
 * browser clients create/manage projects. Captures, uploads, and documents
 * all reference a project_id.
 *
 * Design rationale:
 *   - UUIDv7 primary key (time-ordered, collision-free). Generated server-side
 *     for browser creates; iOS sends client_generated_id for idempotent retry.
 *   - client_generated_id is a UNIQUE idempotency key — duplicate POSTs with
 *     the same (workspace_id, client_generated_id) return the existing row.
 *   - No FK from capture_sessions/uploads → projects (soft references only).
 *   - REPLICA IDENTITY FULL enables Lakehouse Sync CDC into Delta.
 *   - archived = soft delete. Never hard delete from the API surface.
 *   - pg_trgm extension: enables GIN trigram index for fast ILIKE search.
 *     Also serves as a litmus test for whether Lakebase allows CREATE EXTENSION
 *     — relevant for future pgvector use.
 *
 * See: fixtures/databricks-app-ui-plan.md (Phase 1: Project Management)
 */

import type { Migration } from './migrate';

export const migration004: Migration = {
  name: '004_projects',
  up: `
    -- Enable pg_trgm for trigram GIN indexes (fast ILIKE search).
    -- If Lakebase blocks CREATE EXTENSION, this statement will error —
    -- which tells us we can't use pgvector either. Safe to remove if so.
    CREATE EXTENSION IF NOT EXISTS pg_trgm;

    CREATE TABLE IF NOT EXISTS app.projects (
      id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      client_generated_id   TEXT,
      name                  TEXT NOT NULL,
      description           TEXT,
      workspace_id          TEXT NOT NULL,
      created_by_user_id    TEXT NOT NULL,
      created_by_username   TEXT NOT NULL,
      archived              BOOLEAN NOT NULL DEFAULT false,
      created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    -- Idempotency key: (workspace_id, client_generated_id) must be unique
    -- Allows iOS to safely retry POSTs without creating duplicates
    CREATE UNIQUE INDEX IF NOT EXISTS idx_projects_idempotency
      ON app.projects (workspace_id, client_generated_id)
      WHERE client_generated_id IS NOT NULL;

    -- Workspace listing: "show me all projects in this workspace"
    CREATE INDEX IF NOT EXISTS idx_projects_workspace
      ON app.projects (workspace_id, archived, updated_at DESC);

    -- User listing: "show me my projects"
    CREATE INDEX IF NOT EXISTS idx_projects_user
      ON app.projects (created_by_user_id, archived, updated_at DESC);

    -- Name search: supports ILIKE queries for search-as-you-type.
    -- Requires pg_trgm extension (created above). If the extension call
    -- succeeded, this gives us indexed ILIKE '%term%' queries at any scale.
    CREATE INDEX IF NOT EXISTS idx_projects_name_trgm
      ON app.projects USING gin (name gin_trgm_ops);

    -- Enable replica identity for Lakehouse Sync (full CDC rows)
    ALTER TABLE app.projects REPLICA IDENTITY FULL;
  `,
};
