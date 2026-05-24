# 2026-05-24: iOS Auth Hardening & Device Assignment Backfill

## Problems

1. **Projects created from iOS attributed to SPN identity.** The 55 iOS-created projects had `created_by_user_id = '71833269206346@7474657291520070'` (the Xcode SPN SCIM ID) instead of the human user. Root cause: iOS `ProjectService` was sending only Layer 0 M2M Bearer (Xcode SPN) without Layer 2 headers. The `dualAuth` middleware fell through to `browserAuth`, which used `X-Forwarded-User` — set to the SPN's identity by the auth sidecar.

2. **iOS-created projects showing "Unpaired" in browser UI.** Even after fixing user_id attribution, project cards showed the gray "Unpaired" badge because no `project_device_assignments` row existed. iOS projects were never assigned via the browser "Pair Device" modal — they were created directly on the iPhone which doesn't go through that flow.

## Root Cause Analysis

**Detection flaw in `dualAuth`:** The middleware allowed bare SPN requests to pass through when:
- No `X-Lakeloom-Session-Token` header (iOS Layer 2 path skipped)
- `X-Forwarded-User` present but `X-Forwarded-Email` absent (SPN identity only)

The auth sidecar sets `X-Forwarded-Email` **only** for human browser sessions. SPNs never have email headers. This is the reliable discriminator.

## Changes

### Migration 012: Remediate iOS project user_id
- `UPDATE app.projects SET created_by_user_id = '<human_scim_id>', created_by_username = 'matthew.giglia@databricks.com' WHERE created_by_user_id = '<spn_scim_id>'`
- Affected 55 projects (confirmed via UC table query)

### Migration 013: Backfill project_device_assignments
- `INSERT INTO app.project_device_assignments` from `capture_sessions` where `created_by_paired_session_id IS NOT NULL` and no existing assignment
- Uses `DISTINCT ON (project_id)` with `ORDER BY started_at DESC` to pick the most recently active device per project
- Backfilled 5 assignments (confirmed via UC table query)

### browser-auth.ts: Hardened browserAuth
- `browserAuth()` now REQUIRES `X-Forwarded-Email` header
- Bare SPN requests (only `X-Forwarded-User`) get explicit 401 with actionable message: "Service principal identity detected without Layer 2 auth. iOS must send X-Lakeloom-Session-Token."
- `dualAuth()` detection matrix updated — no SPN fallthrough possible

### project-routes.ts: Auto-assign device on iOS project create
- After INSERT into `app.projects`, checks `req.user.sessionId` (populated by iosAuth for Layer 2 requests)
- If present, inserts `project_device_assignments` row automatically
- Non-fatal: catches errors without failing the project creation
- Eliminates need for manual "Pair Device" step for iOS-created projects going forward

### hey_isaac notification
- `architecture/hey_isaac/2026-05-24_ios-layer2-on-project-endpoints.md`
- Documents: affected endpoints, required iOS fix, data remediation, forced 401 behavior

## Decisions

- **Server enforces, not works around.** User rejected a server-side workaround to detect SPN and resolve human identity heuristically. Correct fix: iOS must send Layer 2 headers on ALL `/api/v1/` endpoints. Server enforces with hard 401.
- **Forced 401 as a feature.** iOS `ProjectService` will get 401 until Isaac adds Layer 2 headers. This is intentional — it's a forcing function to ensure the fix ships.

## Detection Matrix (After Fix)

| Request has | Result |
|------------|--------|
| X-Lakeloom-Session-Token + Layer 2 headers | iosAuth → resolves human from paired_sessions |
| X-Forwarded-Email (human browser) | browserAuth → uses SCIM ID |
| Only X-Forwarded-User (SPN, no Layer 2) | 401 REJECTED |
| Nothing | 401 REJECTED |

## Verification

- Migration 012: All 57 projects now attributed to human SCIM ID (confirmed via `lb_projects_history`)
- Migration 013: 5 device assignments backfilled (confirmed via `lb_project_device_assignments_history`)
- OTel traces: Session completion PATCH calls clean — 13-21ms, 2 Lakebase queries each, all OK
- UI: All projects show correct device badge; session complete button working

## Files Modified

- `server/migrations/012_remediate_ios_project_user_id.ts` (new)
- `server/migrations/013_backfill_project_device_assignments.ts` (new)
- `server/migrations/migrate.ts` (registered 012 + 013)
- `server/middleware/browser-auth.ts` (hardened — SPN rejection)
- `server/routes/projects/project-routes.ts` (auto-device-assign on iOS create)
- `architecture/hey_isaac/2026-05-24_ios-layer2-on-project-endpoints.md` (new)
- `fixtures/sessions/2026-05-24_phase2-capture-session-complete.md` (earlier in session)

## Commits

- `74becf5` — browserAuth hardening + migration 012
- `10d1174` — hey_isaac notification
- `5fccd6e` — migration 013 + auto-device-assign
