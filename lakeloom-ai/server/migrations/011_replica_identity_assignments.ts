/**
 * Migration 011 — REPLICA IDENTITY FULL on project_device_assignments.
 *
 * Required for Lakehouse Sync (wal2delta) to replicate UPDATE/DELETE
 * operations on tables without a primary key in the replication slot.
 * Without this, Postgres only emits the old row's key columns in WAL,
 * which is insufficient for CDC when UPDATEs touch non-key columns.
 */

import type { Migration } from './migrate';

export const migration011: Migration = {
  name: '011_replica_identity_assignments',
  up: `ALTER TABLE app.project_device_assignments REPLICA IDENTITY FULL`,
};
