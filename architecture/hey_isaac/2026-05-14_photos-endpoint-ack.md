# Hey Isaac — Photos endpoint shipped, HEIC dropped, encoding confirmed

**From:** Genie Code (Databricks side)  
**Date:** 2026-05-14  
**Status:** All changes from your `2026-05-14_photos-endpoint-and-encoding-answers.md` implemented. No open questions.

---

## Summary

| # | Request | Status |
|---|---|---|
| 1 | `POST /api/captures/:capture_session_id/photos` (JPEG only) | **Shipped** |
| 2 | Drop `image/heic` from `/screenshots` MIME allowlist | **Done** |
| 3 | HEIC: iOS sends JPEG, no HEIC anywhere | **Confirmed** — removed from global MIME map |
| 4 | `device_pubkey` encoding: base64url, no padding | **Confirmed** — `Buffer.from(x, 'base64url')` unchanged |

---

## Implementation details

### Per-endpoint MIME allowlists (new pattern)

Previously, all upload endpoints shared a single global MIME → extension map. Your photos spec (JPEG-only) made it clear each endpoint should enforce its own allowlist. Refactored `createUploadHandler` to accept an `allowedMimes` option:

| Endpoint | Allowed MIMEs |
|---|---|
| `/api/captures/:id/audio` | `audio/wav`, `audio/m4a`, `audio/mp4` |
| `/api/captures/:id/screenshots` | `image/png`, `image/jpeg` |
| `/api/captures/:id/photos` | `image/jpeg` |
| `/api/projects/:id/documents` | `application/pdf`, `application/vnd.openxmlformats-officedocument.wordprocessingml.document` |

A request with a MIME outside the per-endpoint list gets 415 with an error body listing the allowed types. The global `MIME_TO_EXT` map still resolves extensions but no longer has `image/heic`.

### Photos endpoint contract

Matches your spec exactly:

- **Auth:** Bearer + Layer 2 (standard)
- **Multipart body:** `file` (JPEG bytes) + `client_ts` + `client_filename` + `sha256_hex` (all optional metadata)
- **MIME:** `image/jpeg` only → 415 for anything else
- **Storage:** `/Volumes/{catalog}/{schema}/screenshots/{project_id}/{capture_session_id}/{uuidv7}.jpg`
- **`app.uploads` row:** `kind = 'photo'`
- **Authz/state:** Same as screenshots — `capture.state` must be `'active'`, 409 if completed/cancelled
- **Response:** `201 { id, kind: 'photo', volume_path, size_bytes, sha256_hex, uploaded_at }`

### `screenshots` volume semantic widening

Documented in `PROJECT_MEMORY.md`. The volume now holds "session images" (screenshots + photos). The `kind` column in `app.uploads` provides semantic separation at query time.

---

## Validation

Post-deploy validation notebook (`pairing-api-test`) updated with Test 8 — hits the new photos endpoint with SPN token, expects 401 (Layer 2 missing), confirms route is registered and reachable.

---

## No open questions

Both of your open answers are confirmed and implemented. iOS Module 01 rewrite remains unblocked. Module 02 (CaptureEngine) will have the photos endpoint ready when it lands.

— Genie
