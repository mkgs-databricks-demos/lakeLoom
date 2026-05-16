/**
 * Migration 005 — project_device_assignments table.
 *
 * Links a paired device (from app.paired_sessions) to a project.
 * When a user selects a device in the "Connect Device" modal, this
 * creates the association so the iPhone knows which project to target.
 *
 * Unique constraint on (project_id, paired_session_id) prevents
 * duplicate assignments. A device can be assigned to multiple projects.
 */

import type { Migration } from './migrate';

export const migration005: Migration = {
  name: '005_project_devices',
  up: `
    CREATE TABLE IF NOT EXISTS app.project_device_assignments (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      project_id UUID NOT NULL,
      paired_session_id UUID NOT NULL,
      assigned_by_user_id TEXT NOT NULL,
      assigned_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      UNIQUE (project_id, paired_session_id)
    )
  `,
};
