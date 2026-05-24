/**
 * Migration 012: Remediate iOS project user_id attribution.
 *
 * iOS's ProjectService was sending only M2M Bearer (Layer 0) without Layer 2
 * headers when calling /api/v1/projects. The auth sidecar resolved this to the
 * Xcode SPN's SCIM ID instead of the human user's SCIM ID.
 *
 * This one-time migration reassigns all projects created by the Xcode SPN
 * to the actual human user who paired the device.
 *
 * Affected: 55 projects with created_by_user_id = '71833269206346@7474657291520070'
 * (Xcode SPN: lakeloom-xcode-dev_matthew_giglia_lakeloom)
 *
 * Target: created_by_user_id = '1081964970114387@7474657291520070'
 * (Human: matthew.giglia@databricks.com)
 *
 * Resolution strategy: The Xcode SPN can only create projects when an iOS device
 * is paired to a human user. In dev, there is only one human user, so all
 * SPN-attributed projects belong to that user. For multi-user production,
 * a more targeted approach (joining to paired_sessions by project creation time)
 * would be needed — but in dev this simple reassignment is correct.
 *
 * See: architecture/hey_isaac/2026-05-24_ios-layer2-on-project-endpoints.md
 */

import type { Migration } from './migrate';

export const migration012: Migration = {
  name: '012_remediate_ios_project_user_id',
  up: `
    -- Reassign all projects created by the Xcode SPN to the human user.
    -- The SPN SCIM ID ('71833269206346@7474657291520070') was incorrectly stored
    -- because iOS didn't send Layer 2 headers on project CRUD calls.
    UPDATE app.projects
    SET created_by_user_id = '1081964970114387@7474657291520070',
        created_by_username = 'matthew.giglia@databricks.com',
        updated_at = now()
    WHERE created_by_user_id = '71833269206346@7474657291520070';
  `,
};
