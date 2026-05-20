# Hi Genie — Audio uploads verified working iOS-side. Two requests + one bug.

**From:** Isaac (iOS)
**Date:** 2026-05-20
**Re:** `hey_isaac/2026-05-20_audio-uploads-working.md`
**Status:** End-to-end success against dev. Need server-side verification + answer about one serialization quirk.

---

## TL;DR

Massive thanks for getting the upload handler unblocked — your fix landed cleanly and **iOS uploaded two audio files to dev in the same smoke-test run, both succeeding on attempt 1**. The full pipeline (record → hash → multipart → signed POST → server iosAuth → busboy → UC Volume → `app.uploads` row → 201 response) works.

Two asks below:

1. **Verification:** can you confirm the records I produced this morning show up in Lakebase + UC Volume the way I think they should? I have the iOS-side numbers; you have the server-side ground truth.
2. **Decode bug:** the `GET /api/captures/:id?include=uploads` response sends `size_bytes` as a JSON string (`"134931"`) instead of a JSON number (`134931`). iOS decodes it as `Int64` and rejects the response. Is this a Lakebase bigint serialization quirk (which we'll just be lenient about iOS-side) or a server-side bug?

Details below.

---

## Records to verify

All produced during a single smoke-test run at ~2026-05-20 15:48–15:51 UTC on dev. Workspace `7474657291520070` (`fevm-hls-fde.cloud.databricks.com`). Paired user: my SCIM ID. `paired_session_id` starts `e7ca1bff…`.

### Project (created this run)

| Field | Value |
|-------|-------|
| `project_id` | `ecf0fee3-726e-4a7c-b73e-11758a5938a2` |
| `client_generated_id` (iOS-side hint) | `019e4613…` |
| Created via | `POST /api/projects` from the home screen onboarding flow |
| Created at (unix) | ~1779292080 |

Should appear in `app.projects` with `created_by_user_id` matching my SCIM and `workspace_id` matching the FE-VM HLS FDE workspace.

### Capture session 1

| Field | Value |
|-------|-------|
| `capture_session_id` | `34162e4f-a1f0-40a6-a5c6-6691a0cfff90` |
| `project_id` | `ecf0fee3-726e-4a7c-b73e-11758a5938a2` |
| Label | `smoke test 11:48:47` (EDT — UTC 15:48:47) |
| Created (unix) | 1779292127 |
| Completed (unix) | 1779292217 |
| Expected `state` | `completed` |
| Expected `device_label` | the iPhone display name from `UIDevice.current.name` (likely "iPhone 17 Pro Max" / sim variant) |

### Audio upload 1 (attached to capture 1)

| Field | Value |
|-------|-------|
| iOS `upload_id` (client side) | starts `0CFCD907…` (full UUIDv4 from the upload coordinator) |
| Raw audio file size | 134931 bytes |
| Multipart envelope size | 135558 bytes (raw + ~627 bytes of boundary markers + part headers + 3 metadata fields) |
| Multipart envelope SHA-256 (signature canonical) | `38697166a67b46b7391d92ec9a37f6a08152d4c0c38b0cb8735b13879cd87939` |
| Sent at (unix) | 1779292149 |
| iOS reported | `upload.attempt.ok` on attempt 1 |
| Audio file (decoded multipart) | M4A/AAC, mono, 44.1kHz, `AVAudioQuality.medium`, duration 9.778s |

**Expected server-side artifacts:**
- One row in `app.uploads` with `capture_session_id = 34162e4f-…`, `kind = 'audio'`, `mime_type = 'audio/mp4'`, `size_bytes = 134931`, an `sha256_hex` value (this is iOS's hash of the *file bytes only*, not the multipart envelope), `client_ts ≈ 2026-05-20T15:48:48Z` with `client_ts_source = 'client'`, `original_filename` starting `audio-20260520T154858`
- One file at `/Volumes/{catalog}/{schema}/session_audio/ecf0fee3-…/34162e4f-…/{uuidv7}.m4a`
- The UUIDv7 you generate server-side should be sortable just-after the `client_ts` above

### Capture session 2

| Field | Value |
|-------|-------|
| `capture_session_id` | `23c4e537-5edc-4035-b27f-aee268450d5c` |
| `project_id` | `ecf0fee3-726e-4a7c-b73e-11758a5938a2` |
| Label | `smoke test 11:50:51` |
| Created (unix) | 1779292251 |
| Completed (unix) | 1779292277 |
| Expected `state` | `completed` |

### Audio upload 2 (attached to capture 2)

| Field | Value |
|-------|-------|
| iOS `upload_id` (client side) | starts `23071564…` |
| Raw audio file size | 116535 bytes |
| Multipart envelope size | 117162 bytes |
| Multipart envelope SHA-256 | `20a7f0020179bc0c0d2e00bb4dfac907b80e1214f300245f2b00e7e99999e1df` |
| Sent at (unix) | 1779292269 |
| iOS reported | `upload.attempt.ok` on attempt 1 |
| Audio file | M4A/AAC, mono, 44.1kHz, duration 7.605s |

**Expected server-side artifacts:**
- One row in `app.uploads` with `capture_session_id = 23c4e537-…`, `kind = 'audio'`, `size_bytes = 116535`, `original_filename` starting `audio-20260520T155101`
- One file at `/Volumes/{catalog}/{schema}/session_audio/ecf0fee3-…/23c4e537-…/{uuidv7}.m4a`

### Net expected lakebase state

- 1 row in `app.projects` (the new project `ecf0fee3-…`)
- 2 rows in `app.capture_sessions` (both `state = 'completed'`)
- 2 rows in `app.uploads` (both `kind = 'audio'`, total 251466 raw bytes across the two)
- 0 rows in `app.uploads` for the prior failed attempts from the 500-era (we deleted the app from the simulator before this run, so no stale upload-queue entries fired)

### Net expected UC Volume state

- 2 new M4A files under `/Volumes/{catalog}/{schema}/session_audio/ecf0fee3-…/` — one under each capture session's subdirectory
- No files under any other path (no screenshots, photos, or documents this run)

---

## The decode bug

After each successful upload, the smoke-test sheet tapped `GET /api/captures/:capture_session_id?include=uploads` to verify the round-trip. Both times the iOS decoder threw:

```
[error] app.request.decode_failed
  path=/api/captures/34162e4f-…?include=uploads
  reason=typeMismatch(Swift.Int64, Swift.DecodingError.Context(
    codingPath: [uploads -> Index 0 -> size_bytes],
    debugDescription: "Expected to decode Int64 but found a string instead."
  ))
```

iOS's `CaptureUpload` struct has `sizeBytes: Int64`. Swift's `JSONDecoder` won't coerce a JSON string into `Int64` automatically. So the server must be sending `"size_bytes": "134931"` (string) rather than `"size_bytes": 134931` (number).

This is interesting because **the upload's own 201 response** (per your `hey_isaac/2026-05-20_audio-uploads-working.md` example) shows:

```json
"size_bytes": 3244
```

…with no quotes. So either:

- (a) The `POST /api/captures/:id/audio` 201 response and the `GET /api/captures/:id?include=uploads` response are serialized through different code paths, and the GET path is leaking Lakebase's bigint-as-string serialization (some Postgres drivers do this to avoid JS `Number` precision loss for values > 2^53)
- (b) Your documented example didn't match what's actually shipped
- (c) Something else

**My ask:** can you check `lakeloom-ai/server/routes/captures/capture-routes.ts` or wherever the GET handler with `include=uploads` lives, and confirm whether `size_bytes` is intentionally serialized as a string? If it's the bigint-driver quirk we should commit to (because Lakebase bigints really can exceed `Number.MAX_SAFE_INTEGER` and JS can't represent them precisely), I'll just make iOS lenient and accept either. If it's a serialization bug, easy server fix.

I'd lean toward **iOS being lenient** — your contract should preserve precision, and the multi-driver realities of Postgres → JSON serialization are not iOS's problem. I'm shipping the iOS-side fix today regardless so this stops blocking the smoke-test sheet; just want to know if you want to revisit on your end.

The other fields on `CaptureUpload` (`mime_type`, `sha256_hex`, etc.) decoded fine, so this is contained to numeric fields. I'll apply the same lenient pattern to any other `Int64` in the response shape preemptively.

---

## Two other small notes

1. **The `Cannot transition from 'cancelled' to 'completed'` 400 hasn't reappeared.** iOS PR #35 added cancel/complete mutex in the smoke-test sheet. Both PATCHes in this run were `completed` and both succeeded.

2. **iOS-side decode of the upload's 201 response is still minimal** (`let id: String?` only). I'm shipping a richer typed decoder in the same iOS PR that covers the new `client_ts_source` field per your documented shape. So when uploads succeed, we'll have the full server-side row (volume path, server-issued upload UUID, client-vs-server timestamp source, etc.) available on `PendingUpload.remoteUploadID` and downstream UI surfaces.

---

## What I'm doing next on iOS

PR in flight on `mg-ios-upload-response-polish`:
- Lenient `sizeBytes` decoder (accepts string or number) on `CaptureUpload`
- Richer `UploadResponse` typed decoder for the 201 body
- New `clientTsSource` field on `CaptureUpload`
- Honor the RFC 9457 `UPLOAD_VOLUME_WRITE_FAILED` / `UPLOAD_INTEGRITY_MISMATCH` / `UNSUPPORTED_MEDIA_TYPE` error codes in `UploadCoordinator.isPermanent` so retry behavior matches the typed semantics you documented

Module 02 PRs 6 (screen broadcast) and 7 (real UI) are still queued. With uploads green I no longer have a blocker on those.

Thanks again for the fast turnaround on the server fix.

— Isaac
