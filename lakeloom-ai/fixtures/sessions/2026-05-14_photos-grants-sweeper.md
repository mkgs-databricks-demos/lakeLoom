# 2026-05-14 — Photos Endpoint, Volume Grants, Orphan Sweeper

**Date:** 2026-05-14 10:38 UTC  
**Scope:** Isaac's 05-14 requests + two backlog items from PROJECT_MEMORY

---

## Problems Addressed

1. Isaac requested a new photos endpoint for whiteboard/camera captures (JPEG only)
2. Isaac confirmed HEIC not needed — drop from screenshots allowlist
3. Isaac confirmed `device_pubkey` uses base64url encoding (no padding)
4. App SPN lacked WRITE_VOLUME (and READ_VOLUME) on UC Volumes — uploads would fail at runtime
5. No mechanism to detect orphan files on Volumes missing from `app.uploads`
6. Stale `endpoint.hostname` bug note in PROJECT_MEMORY (already fixed in code)

## Root Causes

- Per-endpoint MIME filtering didn't exist (single global allowlist)
- `UploadKind` type didn't include `'photo'`
- `configure_app_spn` job only handled secrets + Lakebase schema — no volume grants
- Orphan detection was flagged as future work with no implementation

## Changes Made

### `server/routes/uploads/upload-routes.ts`
- Added `allowedMimes` option to `UploadHandlerOpts` interface
- Added per-endpoint MIME validation (415 with allowed list in error)
- Added `'photo'` to `UploadKind` type union
- Registered `POST /api/captures/:capture_session_id/photos` route (JPEG only, screenshots volume)
- Removed `image/heic` from global `MIME_TO_EXT` map
- Each existing route now declares explicit `allowedMimes`

### `src/tests/pairing-api-test` (notebook)
- Added Test 8: photo upload endpoint validation (401 expected, not 302)
- Updated CI/CD Gate cell: `expected_tests` list expanded to 8 items

### `src/admin/grant-app-spn-volume-access` (new notebook)
- 10 SQL cells matching infra bundle's `grant-volume-access` pattern
- Params: `catalog_use`, `schema_use`, `spn_application_id`, `volume_name`
- Grants READ_VOLUME + WRITE_VOLUME via EXECUTE IMMEDIATE

### `resources/configure_app_spn.job.yml`
- Added Task 3: `grant_volume_access` (forEach over 3 volumes, concurrency 3)
- Uses `sql_warehouse_id` for SQL execution context
- Job run succeeded (1m 31s, all 3 tasks green)

### `src/admin/orphan-byte-sweeper` (new notebook)
- 7 cells: install deps, params, recursive volume scan, Lakebase query, set diff, report
- Report-only (no auto-delete in v1)
- Emits `orphan_count` and `orphan_bytes` task values for alerting

### `resources/orphan_byte_sweeper.job.yml` (new)
- Scheduled weekly: Sunday 2:00 AM UTC
- Serverless compute, 30-minute timeout
- Passes catalog, schema, lakebase params

### `architecture/hey_isaac/2026-05-14_photos-endpoint-ack.md` (new)
- Ack to Isaac: photos shipped, HEIC dropped, encoding confirmed, per-endpoint MIME filtering

### `PROJECT_MEMORY.md`
- Struck through: App SPN WRITE_VOLUME, orphan sweeper, HEIC/base64url confirmation, manual step 3
- Added "Photos Endpoint & Per-Endpoint MIME Filtering: COMPLETE" section
- Updated hostname bug note (already fixed)

## Decisions

- **Per-endpoint MIME filtering:** Each handler declares allowed MIMEs independently (not a global gate)
- **Photos use screenshots volume:** Same UC Volume, differentiated by `kind` column in `app.uploads`
- **Orphan sweeper is report-only v1:** No auto-delete until production traffic validates the detection logic
- **App SPN gets both READ + WRITE:** Prepares for future file viewer/playback UI

## Files Modified

| File | Type |
|------|------|
| `server/routes/uploads/upload-routes.ts` | Modified |
| `src/tests/pairing-api-test` | Modified (notebook) |
| `src/admin/grant-app-spn-volume-access` | New (notebook) |
| `resources/configure_app_spn.job.yml` | Modified |
| `src/admin/orphan-byte-sweeper` | New (notebook) |
| `resources/orphan_byte_sweeper.job.yml` | New |
| `architecture/hey_isaac/2026-05-14_photos-endpoint-ack.md` | New |
| `PROJECT_MEMORY.md` | Modified |

## Validation

- `bundle validate --target dev` — passes
- `configure_app_spn` job run — all 3 tasks succeeded (run ID 229469340738597)
- Post-deploy validation notebook expanded to 8 tests (not yet re-run with new app deploy)
