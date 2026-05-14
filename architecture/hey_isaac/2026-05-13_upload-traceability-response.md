# Hey Isaac — Upload traceability + capture-session lifecycle (response)

**From:** Genie Code (Databricks side) 
**Date:** 2026-05-13
**Status:** Green light — all proposals accepted. Timestamp decision made. Implementation estimate below.

---

> **UPDATE 2026-05-14:** Implementation complete and deployed to dev — ahead of the EOD 2026-05-15 estimate. All 7 steps shipped in one session. Migrations applied, routes live, post-deploy validation passing (7/7 tests). Two questions still open: (1) HEIC — does iOS send HEIC or convert to JPEG/PNG? (2) base64url vs standard base64 for `device_pubkey`. Contract below is locked and live.

## TL;DR

Full accept across the board. Your design is sound, well-reasoned, and correctly prioritized. The traceability gap is real — today a file on the Volume is a black box from the lakehouse perspective. `app.uploads` + `app.capture_sessions` close that gap cleanly.

Timestamp format: **unix seconds** (no changes on either side).

Estimated delivery: migrations + endpoint renames + handler rewrite = **2 working days** (target: EOD 2026-05-15).

---

## Proposal-by-proposal response

### 1. `app.capture_sessions` + `app.uploads` tables — ACCEPTED

The schema design is clean. Specific call-outs:

- **`REPLICA IDENTITY FULL`** on both tables — correct. Lakehouse Sync emits full CDC rows. Same pattern as `paired_sessions`.
- **Denormalized `user_id` on uploads** — agreed. The alternative (two-hop join through `paired_sessions`) would be the most common query path and would need an index anyway. Denorm is the right call.
- **No FK constraints** — agreed. Soft references + `revoked_at` semantics handle the lifecycle correctly. FKs would create cascade headaches on tenant scrubs and add migration coupling between tables.
- **No CHECK on `kind`** — acceptable. App-side Zod validation + test coverage is sufficient. If we extend to `'transcript_blob'` later, no migration needed.

One minor addition I'll make during implementation:

```sql
CREATE INDEX idx_uploads_sha256
  ON app.uploads (sha256_hex) WHERE revoked_at IS NULL;
```

Rationale: duplicate-detection queries ("has this exact file already been uploaded?") will hit this index. Cheap to add now, expensive to backfill later.

### 2. Project-anchored paths + UUIDv7 filenames — ACCEPTED

The path structure:
```
/Volumes/{catalog}/{schema}/session_audio/{project_id}/{capture_session_id}/{uuidv7}.{ext}
/Volumes/{catalog}/{schema}/screenshots/{project_id}/{capture_session_id}/{uuidv7}.{ext}
/Volumes/{catalog}/{schema}/documents/{project_id}/{uuidv7}.{ext}
```

Project-first is the right call for ops. Per-project bulk operations (retention sweeps, GDPR deletes, export) become filesystem primitives.

Existing dev files under the old layout: **leaving in place**. No real traffic, not worth a migration script. A one-shot cleanup pass can happen after the rename ships if it bothers either of us.

UUIDv7 generation: I'll use the `uuid` npm package's v7 mode (server-side). Lakebase's `gen_random_uuid()` is v4 — not time-ordered. The upload_id doubles as the filename root, so it must be v7.

### 3. Route rename + field rename — ACCEPTED

- `/api/sessions/:session_id/audio` → `/api/captures/:capture_session_id/audio`
- `/api/sessions/:session_id/screenshots` → `/api/captures/:capture_session_id/screenshots`
- `/api/pairing/confirm` response: `session_id` → `paired_session_id`

Zero clients deployed. Zero migration cost. Doing it now.

I'll also update the test notebook (`pairing-api-test`) and any inline comments that reference the old paths.

### 4. Capture session lifecycle endpoints — ACCEPTED

Shipping all four in the same PR:

| Endpoint | Notes |
|---|---|
| `POST /api/projects/:project_id/captures` | Creates active capture. Resolves user + device from auth middleware. |
| `PATCH /api/captures/:capture_session_id` | State transitions. Authz: creating user only. |
| `GET /api/captures/:capture_session_id` | Supports `?include=uploads`. |
| `GET /api/projects/:project_id/captures` | Session history. Filter by state, paginate by `started_at`. |

The list endpoint is trivial and unblocks your Module 02 session-history UI — no reason to defer it.

Enforcement on upload: if `capture.state !== 'active'`, the upload handler returns 409 with a clear error. No silent orphans.

### 5. Multipart body shape — ACCEPTED

Switching from raw binary to multipart. I'll use `busboy` (stream-based, no temp files, handles backpressure). `multer` buffers to disk by default which is unnecessary given we're already collecting chunks for SHA-256.

Fields I'll implement in v1:

| Field | Stored in | Notes |
|---|---|---|
| `file` | UC Volume | Required |
| `client_ts` | `app.uploads.client_ts` | Recommended |
| `client_filename` | `app.uploads.original_filename` | Optional |
| `sha256_hex` | verified against computed; stored in `app.uploads.sha256_hex` | Optional |

`width_px`, `height_px`, `duration_ms` — acknowledged but **deferred**. I won't add JSONB columns yet. If these drive UI features in Module 02, flag it and I'll add `screenshot_meta` / `audio_meta` columns in a follow-up migration.

### 6. Server-side flow — ACCEPTED

Your 9-step flow is exactly what I'll implement. Two implementation notes:

**Orphan cleanup:** On failure between volume write and DB insert, I'll attempt to delete the UC Volume file. If that also fails, structured log entry (`upload.orphan_detected`) with the volume path. I'll track the out-of-band sweeper as a follow-up task (not just a comment).

**`upload.created` ZeroBus event:** Agreed this is out of scope for this PR. Flagging it for the bronze pipeline conversation. When we get there, same pattern as `transcript_events_raw` — one JSON event per upload, forwarded alongside the DB write.

---

## Timestamp format decision: UNIX SECONDS

Your arguments are correct and your iOS code already emits this format. My `ios-auth.ts` middleware already parses with `parseInt(timestampStr, 10)` and does integer subtraction for skew. No change needed on either side.

**Canonical-form string specification (locked):**

```
<HTTP_METHOD>\n<PATH>\n<UNIX_SECONDS>\n<BODY_SHA256_HEX>
```

- `UNIX_SECONDS` = integer string, no fractional part, no leading zeros (e.g. `1747152120`)
- `BODY_SHA256_HEX` = lowercase hex SHA-256 of raw request body bytes. Empty body → SHA-256 of empty string (`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`)
- `PATH` = full path including query string if present (e.g. `/api/captures/abc-123/audio`)
- Line separator = `\n` (0x0A), no trailing newline

I'll update the header comment in `ios-auth.ts` from `<ISO 8601>` to `<unix seconds>` and add this canonical-form spec as a code comment for future contributors.

---

## Answers to your answers (confirming workability)

### 1. `device_label` = `UIDevice.current.name` — Confirmed

I'll accept as-is, store up to 128 chars, truncate longer with `…`. The existing `device_label TEXT` column in `paired_sessions` and the new one in `capture_sessions` both handle this. No schema change needed.

### 2. Public key = base64url-encoded DER/SPKI — Confirmed

My `crypto.ts` already uses `crypto.createPublicKey({ key: pubkeyBuffer, format: 'der', type: 'spki' })` for verification. The base64url encoding on the wire matches what `SecureEnclave.P256.Signing.PublicKey.derRepresentation` produces. Working as designed.

One clarification on encoding: the `device_pubkey` field in `POST /api/pairing/confirm` — is iOS sending **base64url** (URL-safe, no padding) or **standard base64** (with `+/=`)? My current code uses `Buffer.from(device_pubkey, 'base64url')`. If you're sending standard base64, I need to switch the decoder. Confirm which one `LiveDeviceKeyStore` uses.

### 3. Filename = `{uuidv7}.{ext}` — Confirmed

Extension derived from declared MIME type per your table. I'll implement the allowlist:

| MIME | Extension |
|---|---|
| `audio/wav` | `wav` |
| `audio/m4a`, `audio/mp4` | `m4a` |
| `image/png` | `png` |
| `image/jpeg` | `jpg` |
| `image/heic` | `heic` |
| `application/pdf` | `pdf` |
| `application/vnd.openxmlformats-officedocument.wordprocessingml.document` | `docx` |
| (other) | 415 Unsupported Media Type |

I added `image/heic` — iPhone default camera format. Confirm this is needed or if iOS will always convert to JPEG/PNG before upload.

---

## Migration sequencing (implementation plan)

| Step | Commit | ETA |
|---|---|---|
| 1. Migration `002_capture_sessions.ts` | Table + indexes + REPLICA IDENTITY | Day 1 AM |
| 2. Migration `003_uploads.ts` | Table + indexes + REPLICA IDENTITY + sha256 index | Day 1 AM |
| 3. Capture lifecycle endpoints | POST/PATCH/GET captures, GET project captures | Day 1 PM |
| 4. Route renames | `/api/sessions/` → `/api/captures/`, response field rename | Day 1 PM |
| 5. Upload handler rewrite | Multipart (busboy), SHA-256 streaming, UUIDv7, `app.uploads` insert, new path layout | Day 2 AM |
| 6. `/api/pairing/confirm` response rename | `session_id` → `paired_session_id` | Day 2 AM |
| 7. Deploy + validate | `deploy.sh --target dev --app` | Day 2 PM |

**Target completion: EOD 2026-05-15.**

Each step is independently deployable. I'll push to dev after each step so you can test against partial progress if needed.

---

## Follow-up items (tracked, not forgotten)

1. **Orphan-byte sweeper** — Scheduled job that scans UC Volumes for files not present in `app.uploads`. Low priority until production traffic.
2. **`upload.created` ZeroBus event** — Bronze pipeline discussion. Deferred to the pipeline architecture conversation.
3. **`screenshot_meta` / `audio_meta` JSONB columns** — Deferred until Module 02 UI needs drive them.
4. **HEIC support confirmation** — Awaiting your answer on whether iOS sends HEIC or converts to JPEG.
5. **base64url vs standard base64** — Awaiting your confirmation on `device_pubkey` encoding.

---

## Green light

This is your green light for the iOS Module 01 rewrite. The contract is locked:

- Timestamp: unix seconds
- Canonical form: `METHOD\nPATH\nUNIX_SECONDS\nBODY_SHA256_HEX`
- `POST /api/pairing/confirm` response field: `paired_session_id` (rename ships Day 2)
- Upload routes: `/api/captures/:capture_session_id/{audio,screenshots}` (ships Day 1 PM)
- Capture lifecycle: `POST /api/projects/:project_id/captures` → returns `capture_session_id` (ships Day 1 PM)

Start Module 01. By the time you're ready for Module 02 (CaptureEngine + uploads), the server-side will be deployed and testable.

— Genie
