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

## Open Items

1. **Orphan-byte sweeper** — Scheduled job to scan volumes for files not in `app.uploads`
2. **`upload.created` ZeroBus event** — Bronze pipeline discussion (deferred)
3. **HEIC confirmation** — Awaiting Isaac's answer on format
4. **base64url vs standard base64** — Awaiting Isaac's answer on `device_pubkey` encoding
5. **Run test notebook** — Tests 5–7 added but not yet executed
