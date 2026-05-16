/**
 * Lakebase migration runner.
 *
 * Auto-applies pending migrations on server startup. Tracks applied migrations
 * in the `app._migrations` table. Migrations are ordered by filename (numeric prefix).
 *
 * All tables live in the `app` Postgres schema — single Lakehouse Sync config
 * targets the UC catalog.schema (hls_fde_dev.lakeloom / hls_fde.lakeloom).
 */

import { migration001 } from './001_paired_sessions';
import { migration002 } from './002_capture_sessions';
import { migration003 } from './003_uploads';
import { migration004 } from './004_projects';
import { migration005 } from './005_project_devices';

// ── Migration registry ─────────────────────────────────────────────────────
// Add new migrations here in order. The `name` must be unique and stable.

export interface Migration {
  name: string;
  up: string; // SQL to apply
}

const migrations: Migration[] = [migration001, migration002, migration003, migration004, migration005];

// ── Lakebase query interface ───────────────────────────────────────────────

interface LakebaseClient {
  query(text: string, params?: unknown[]): Promise<{ rows: Record<string, unknown>[] }>;
}

// ── Migration runner ───────────────────────────────────────────────────────

const ENSURE_SCHEMA = `CREATE SCHEMA IF NOT EXISTS app`;

const ENSURE_MIGRATIONS_TABLE = `
  CREATE TABLE IF NOT EXISTS app._migrations (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  )
`;

const GET_APPLIED = `SELECT name FROM app._migrations ORDER BY id`;

const INSERT_APPLIED = `INSERT INTO app._migrations (name) VALUES ($1)`;

/**
 * Run all pending migrations against the Lakebase database.
 * Safe to call on every startup — already-applied migrations are skipped.
 *
 * @param lakebase - AppKit lakebase client (exposes .query())
 * @returns Number of migrations applied this run
 */
export async function runMigrations(lakebase: LakebaseClient): Promise<number> {
  // Ensure the app schema and migrations tracking table exist
  await lakebase.query(ENSURE_SCHEMA);
  await lakebase.query(ENSURE_MIGRATIONS_TABLE);

  // Determine which migrations have already been applied
  const { rows } = await lakebase.query(GET_APPLIED);
  const applied = new Set(rows.map((r) => r.name as string));

  let count = 0;
  for (const migration of migrations) {
    if (applied.has(migration.name)) {
      continue;
    }

    console.log(`[migrations] Applying: ${migration.name}`);
    try {
      await lakebase.query(migration.up);
      await lakebase.query(INSERT_APPLIED, [migration.name]);
      count++;
      console.log(`[migrations] Applied: ${migration.name}`);
    } catch (err) {
      console.error(`[migrations] FAILED: ${migration.name}`, err);
      throw new Error(
        `Migration "${migration.name}" failed: ${(err as Error).message}. ` +
          `Database may be in an inconsistent state. Fix the migration and restart.`,
      );
    }
  }

  if (count === 0) {
    console.log('[migrations] All migrations already applied.');
  } else {
    console.log(`[migrations] Applied ${count} migration(s).`);
  }

  return count;
}
