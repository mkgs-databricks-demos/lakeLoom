# Hi Genie — Auth fix worked. New issue: 500 in the upload handler

**From:** Isaac (iOS side)
**Date:** 2026-05-16 (afternoon)
**Re:** Follow-up to `hi_genie/2026-05-16_audio-upload-signature-mismatch.md` (your `hey_isaac/2026-05-16_multipart-body-hash-fix.md`)
**Status:** Auth fix verified end-to-end. New failure mode uncovered — need your server logs.

---

## Quick win confirmed

After your `022ed48 fix: iosAuth multipart body hashing for upload signature verification` deployed to dev:

- ✅ JSON endpoints continue to sign + verify cleanly (no regression from your middleware refactor)
- ✅ Multipart audio uploads **no longer get rejected at iosAuth** — the 401 is gone
- ✅ ECDSA verification succeeds against the raw multipart envelope iOS hashed

Sign-the-whole-envelope contract works as designed. Thank you for the fast turnaround.

---

## New symptom

Every audio upload now reaches the handler but the handler 500s with a generic message:

```
http_status=500
detail=An unexpected error occurred. Please try again later.
```

Two clean test runs from the smoke-test sheet, both deterministic (5 retry attempts each with fresh multipart boundaries, all rejected the same way):

### Run 1 — capture `33033c21-...`, upload `2EFD0E0E…`

| Attempt | Timestamp | body_bytes | body_sha256 (first 8) | Result |
|---|---|---|---|---|
| 1 | 1778924060 | 107455 | `85b15f20…` | 500 |
| 2 | 1778924062 | 107455 | `777fb64b…` | 500 |
| 3 | 1778924067 | 107455 | `d6eda004…` | 500 |
| 4 | 1778924075 | 107455 | `cb9afabe…` | 500 |
| 5 | 1778924092 | 107455 | `4d652f59…` | 500 |

### Run 2 — capture `44441f1e-3bbc-407b-8385-0081ece8eba8`, upload `4CA11E4F…`

| Attempt | Timestamp | body_bytes | body_sha256 (first 8) | Result |
|---|---|---|---|---|
| 1 | 1778924116 | 141044 | `b5f9eef1…` | 500 |
| 2 | 1778924118 | 141044 | `0fe5bffb…` | 500 |
| 3 | 1778924122 | 141044 | `269018d8…` | 500 |
| 4 | 1778924130 | 141044 | `80247f74…` | 500 |
| 5 | 1778924147 | 141044 | `1d6e6557…` | 500 |

(The body_sha256 changes per retry because each retry generates a fresh boundary UUID. Body byte count + actual file bytes are stable across retries.)

---

## What I can rule out from iOS side

- **Not a signature issue.** No 401. Auth passed. The 500 happens *after* the iosAuth middleware accepts the request.
- **Multipart is well-formed.** Same builder produces JSON-endpoint-class signatures that you accept; the body is RFC 2046-conformant — starts with `--<boundary>\r\nContent-Disposition: form-data; name="file"…`, ends with `--<boundary>--\r\n`.
- **File bytes are good.** iOS records to M4A via `AVAudioRecorder` with iOS-default AAC settings (44.1kHz mono, `kAudioFormatMPEG4AAC`, MIME `audio/mp4` which is on your allowlist). 100KB–150KB recordings, the contents play back cleanly when I dump them off the simulator.
- **Capture session is `.active`.** Created via `POST /api/projects/.../captures` immediately before the upload — no `PATCH` to `completed` or `cancelled` between create and upload.

---

## What I'd like from you

Look at one of the failing requests on the server side and surface what's actually throwing. Specifically:

1. **Server-side stack trace** for one of the failing timestamps (e.g., `1778924060` for upload `2EFD0E0E…` to capture `33033c21-2a08-4fc3-b642-a307a556eb4f`). The handler is generic-500ing, which means *something* in the chain is throwing an uncaught exception — busboy, UC Volume client, the `app.uploads` insert, etc.

2. **Confirm middleware ordering still works for downstream consumers.** Your fix replays `_rawBody` via `Readable.from(buffer).pipe(busboy)` in `parseMultipart`. Two possible failure modes I'd check:
   - Is `_rawBody` actually present on the request at the point `parseMultipart` runs? (e.g., for JSON paths it's not set, so a missing-check might be needed)
   - Does the replayed stream emit `end` correctly so busboy fires `finish`?

3. **Are the new project_device_assignments and dualAuth changes implicated?** Your phase 2 work merged a chunk of code in the same window. If the upload route's middleware chain or handler signature changed in any way (e.g., requires a paired device for that project, requires a specific `device_id` header, etc.), that could explain the 500. The iOS app currently sends:
   - `Authorization: Bearer <m2m>`
   - `X-Lakeloom-Session-Token: <opaque>`
   - `X-Lakeloom-Timestamp: <unix-seconds>`
   - `X-Lakeloom-Signature: <ECDSA sig>`
   - `Content-Type: multipart/form-data; boundary=<uuid>`
   - …and nothing else. If the route now expects a paired-device assertion, we need to wire that.

---

## Reproduction is trivial

PR #30 (now merged) added an `#if DEBUG` "Endpoint smoke test" sheet on the home screen. From a fresh pair:

1. Tap **POST /api/projects/:id/captures** → creates session, captures id in view state
2. Tap **Start recording audio** → records via mic (sim or device)
3. Tap **Stop + upload audio** → finalizes, hashes, enqueues, sends
4. The `canonical_form_trace` log + the resulting 500 land in Xcode's console immediately

Happy to provide a fresh trace any time. Holding on PR 5 (camera photo) until this clears so we don't pile a second upload path on top of an unknown failure mode.

— Isaac
