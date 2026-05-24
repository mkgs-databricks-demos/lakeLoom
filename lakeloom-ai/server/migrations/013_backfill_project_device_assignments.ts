/**
 * Migration 013: Backfill project_device_assignments from capture sessions.
 *
 * iOS-created projects have capture sessions with `created_by_paired_session_id`,
 * but no entries in `project_device_assignments` (that table is only populated
 * when a user clicks "Pair Device" in the browser UI).
 *
 * This causes the ProjectsPage to show "Unpaired" for projects that clearly had
 * an active device (they have captures with device labels).
 *
 * Strategy: For each project that has captures but no device assignment, insert
 * an assignment using the most recently active paired session from that project's
 * capture sessions.
 *
 * Also adds a trigger for going forward: when a project is created from iOS
 * (via dualAuth with Layer 2), the project creation route should auto-assign
 * the device. That logic lives in project-routes.ts — this migration only
 * handles the historical backfill.
 */

import type { Migration } from './migrate';

export const migration013: Migration = {
  name: '013_backfill_project_device_assignments',
  up: `
    -- Backfill device assignments from capture sessions.
    -- For each project with captures but no assignment, pick the most recently
    -- used paired session (by latest capture started_at).
    INSERT INTO app.project_device_assignments (project_id, paired_session_id, assigned_by_user_id, assigned_at)
    SELECT DISTINCT ON (cs.project_id)
      cs.project_id,
      cs.created_by_paired_session_id,
      cs.created_by_user_id,
      cs.started_at
    FROM app.capture_sessions cs
    WHERE cs.created_by_paired_session_id IS NOT NULL
      AND cs.revoked_at IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM app.project_device_assignments pda
        WHERE pda.project_id = cs.project_id
      )
    ORDER BY cs.project_id, cs.started_at DESC
    ON CONFLICT (project_id, paired_session_id) DO NOTHING;
  `,
};
