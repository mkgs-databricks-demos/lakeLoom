# 2026-05-14 — Upload Traceability & Capture Session Implementation

## Problem

Isaac's design proposal (`hi_genie/2026-05-13_upload-traceability-and-capture-sessions.md`) identified a critical traceability gap: files uploaded to UC Volumes had no metadata in Lakebase — no user, device, SHA-256, or capture session linkage. The upload routes used ambiguous naming (`/api/sessions/`) and the pairing confirm response used `device_id` (colliding with the capture session concept). Without these changes, the downstream Genie Code pipeline has no source of truth for file provenance.

## Root Causes

- No `app.capture_sessions` table — uploads weren't linked to recording lifecycles
- No `app.uploads` table — files on volumes were opaque blobs
- Route naming collision: `session_id` overloaded (paired session vs capture session)
- Raw binary upload handler lacked integrity checks (no SHA-256, no MIME validation)
- `X-Lakeloom-Timestamp` documented as ISO 8601 but iOS already emits unix seconds

## Changes Made

### Files Created

| File | Purpose |
|------|------|
| `server/migrations/002_capture_sessions.ts` | DDL for `app.capture_sessions` — state machine, 4 partial indexes, REPLICA IDENTITY FULL |
| `server/migrations/003_uploads.ts` | DDL for `app.uploads` — UUIDv7 PK, 6 partial indexes (incl. sha256), REPLICA IDENTITY FULL |
| `server/routes/captures/capture-routes.ts` | POST/PATCH/GET lifecycle + project list endpoint |
| `architecture/hey_isaac/2026-05-13_upload-traceability-response.md` | Green-light reply to Isaac's proposal |

### Files Modified

| File | Change |
|------|------|
| `server/migrations/migrate.ts` | Imported + registered migration002 and migration003 |
| `server/server.ts` | Imported + registered `setupCaptureRoutes` |
| `server/routes/uploads/upload-routes.ts` | Full rewrite: multipart (busboy), SHA-256, UUIDv7, MIME allowlist, capture state enforcement, `app.uploads` INSERT, orphan cleanup |
| `server/routes/pairing/pairing-routes.ts` | Response field `device_id` → `paired_session_id`; SSE event updated |
| `server/middleware/ios-auth.ts` | Updated docstring: ISO 8601 → unix seconds, added canonical-form spec |
| `package.json` | Added `busboy`, `uuid`, `@types/busboy` |
| `src/tests/pairing-api-test` (notebook) | Updated overview, added Tests 5–7 (health, captures, uploads) |

## Decisions

| Decision | Rationale |
|----------|------|
| Unix seconds for `X-Lakeloom-Timestamp` | Already deployed in iOS RequestSigner; integer eliminates canonicalization ambiguity |
| UUIDv7 via `uuid` npm (not Postgres) | Lakebase gen_random_uuid() is v4; upload_id must be time-ordered for filename sorting |
| `busboy` over `multer` | Stream-based, no temp files, handles backpressure |
| No FK constraints on uploads/captures | Soft references; avoids cascade issues on tenant data scrubs |
| `idx_uploads_sha256` (our addition) | Duplicate-detection queries; cheap now, expensive to backfill |
| `image/heic` in MIME allowlist | iPhone default format; awaiting Isaac's confirmation |
| Project-anchored volume paths | Per-project bulk ops (GDPR deletes, retention) become fs primitives |

## Deployment

- Bundle validated: `databricks bundle validate --strict --target dev` → OK
- First deploy failed: TS2322 on `req.params` (Express 5 types return `string | string[]`)
- Fix: added `as string` casts on route param reads in context resolvers
- Second deploy succeeded: migrations 002 + 003 applied, app running
- OTel logs confirmed: `[migrations] Applied 2 migration(s).`

## Test Results (pairing-api-test notebook)

All 7 tests pass:

| Test | Endpoint | Status | Result |
|------|----------|--------|--------|
| 1 | `GET /api/pairing/qr` | 401 | ✓ Expected (browser-auth requires session cookie from notebook) |
| 2 | `GET /api/pairing/devices` | 401 | ✓ Expected (same browser-auth limitation) |
| 3 | Xcode SPN OAuth token | 200 | ✓ Bearer token acquired (3600s expiry) |
| 4 | `POST /api/pairing/confirm` | 401 | ✓ SPN passed sidecar, Layer 2 correctly rejected (`token_not_found`) |
| 5 | `GET /healthz` | 200 | ✓ Sidecar intercepted (non-JSON login page), app running |
| 6 | Capture lifecycle (4 endpoints) | 401×4 | ✓ All routes registered, sidecar passed SPN, Layer 2 rejected |
| 7 | Upload endpoints (3 routes) | 401×3 | ✓ Renamed routes reachable, sidecar passed SPN |

Key validation: no 302 redirects (SPN passes sidecar), no 404s (all routes registered), all Layer 2 rejections return RFC 9457 problem+json.

## CI/CD Additions (post-deployment)

After initial deployment, added CI/CD automation:

### deploy.sh Changes
* **Step 7:** `run_post_deploy_validation()` — runs `databricks bundle run post_deploy_validation` after source deploy
* **`--skip-validation` flag** — skips Step 7 for rapid iteration when endpoints haven't changed
* **Constant:** `POST_DEPLOY_VALIDATION_JOB="post_deploy_validation"`
* Non-fatal: warns on failure but doesn't block deploy.sh exit

### Bundle Job
* `resources/post_deploy_validation.job.yml` — single notebook task on serverless
* Deployed and ran successfully (7/7 tests pass)

### Notebook Enhancements
* `test_results` dict initialized in config cell, populated by each test
* Final gate cell: prints timestamped summary, raises `AssertionError` on any FAIL or missing test

## Next Feature Branch

**Orphan-byte sweeper** — scheduled job to scan UC Volumes for files without a matching `app.uploads` row. Low priority until production traffic begins.

## Open Items (blocked on Isaac)

1. **HEIC confirmation** — Does iOS send HEIC or convert to JPEG/PNG before upload?
2. **base64url vs standard base64** — Which encoding does `LiveDeviceKeyStore` use for `device_pubkey`?
3. **`upload.created` ZeroBus event** — Bronze pipeline discussion (deferred)
