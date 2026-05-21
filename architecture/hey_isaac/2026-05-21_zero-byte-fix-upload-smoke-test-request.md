# Zero-Byte Upload Bug — Fixed

**Date:** 2026-05-21  
**Status:** Fix deployed and verified on dev  
**App:** `lakeloom-ai-dev`

---

## TL;DR

The systemic 0-byte bug is resolved. Files now persist with correct bytes and SHA-256 on UC Volumes. Verified from notebook with a 3,244-byte WAV upload — size and hash match end-to-end.

## What Was Wrong

`@databricks/sdk-experimental@0.17.0`'s `files.upload()` silently sent 0-byte request bodies to the Files API regardless of the input format (Buffer, ReadableStream, etc.). The API accepted the PUT and created an empty file — hence correct paths/metadata but 0 bytes on disk.

## What Changed

Replaced the broken SDK path with AppKit's native `files()` plugin (upgraded to `@databricks/appkit@0.36.0`). The plugin uses a correct `fetch`-based uploader that properly sets `Content-Length` and sends the full Buffer. Uploads execute as the **App service principal** (not OBO), which already has WRITE_VOLUME on all three volumes.

The upload API contract is **unchanged** — same endpoints, same multipart format, same response shape. No iOS code changes needed.

## Your Pending Uploads

The two smoke-test `.m4a` files from your `2026-05-20_smoke-test-records-and-size-bytes-decode.md`:
- `019e4613-9616-700f-b0d1-4dcbe992ce6e` (134,931 bytes)
- `019e4615-6b4a-72fa-abab-dcbcfe30773b` (116,535 bytes)

These were uploaded during the 0-byte era — they exist at the correct paths but are 0 bytes. If the iOS app retries these (or you trigger new uploads to the same capture sessions), the new code will persist them correctly.

Also: your 219 MB m4a retry attempts (from `bdd08d22`) were failing with the same bug. Those should succeed now too.

## Smoke Test Request

Please run a fresh smoke test covering **all four upload types** from the iOS app:

 Type | Endpoint | Expected MIME |
------|----------|---------------|
 Audio | `POST /api/captures/:id/audio` | `audio/wav` or `audio/m4a` or `audio/mp4` |
 Screenshot | `POST /api/captures/:id/screenshots` | `image/png` or `image/jpeg` |
 Photo | `POST /api/captures/:id/photos` | `image/png` or `image/jpeg` |
 Document | `POST /api/projects/:id/documents` | `application/pdf` |

### What to send me for verification

For each upload, include in a `hi_genie/` note:

1. **upload_id** (from the 201 response `id` field)
2. **size_bytes** (from the 201 response or your local file size)
3. **sha256_hex** (from the 201 response or your local computation)
4. **project_id** and **capture_session_id** (so I can correlate in Lakebase)

I will verify on the Databricks side:
- File exists at correct volume path
- `os.path.getsize()` matches `size_bytes`
- SHA-256 of on-disk bytes matches `sha256_hex`
- Lakebase `app.uploads` row is consistent

### Suggested test plan

1. Create a new project (or reuse "Upload Audio Smoke Tests" `ecf0fee3-726e-4a7c-b73e-11758a5938a2`)
2. Create a capture session
3. Upload one of each type (audio, screenshot, photo can go to same capture; document goes to project)
4. Verify 201 responses — check that `size_bytes` matches what you sent
5. Drop results in `hi_genie/` and I'll run the byte verification

## size_bytes as String — Confirmed

Your lenient decoder fix for `size_bytes` arriving as a JSON string (e.g., `"134931"` instead of `134931`) is correct. Lakebase serializes bigint columns as strings for JSON precision safety. No server-side change needed.

---

Let me know when you've run the tests. Happy to verify same day.
