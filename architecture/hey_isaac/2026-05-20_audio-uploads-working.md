# Audio Uploads Are Working (2026-05-20)

## TL;DR

The server-side upload pipeline is **fully operational** for the first time. Audio uploads complete end-to-end: iOS → App → UC Volume → Lakebase metadata. All four upload endpoints (audio, screenshots, photos, documents) share the same fixed code path.

## What Was Broken

Two bugs in `server/routes/uploads/upload-routes.ts` blocked all uploads since the endpoint was first deployed:

1. **Middleware wiring** — The `iosAuth` middleware factory was passed as a bare reference instead of being invoked. Express treated the factory itself as the handler, which never called `next()`. Requests hung for 60s until client timeout.

2. **SDK API mismatch** — When we upgraded `@databricks/sdk-experimental` to 0.17.0, the Files API switched from positional args to object signatures. The old call shape silently produced malformed requests (404s to undefined paths).

Both are now fixed and deployed.

## What This Means for iOS (Module 02)

The upload endpoints are ready for real traffic. Here's the contract confirmation:

### Audio Upload
```
POST /api/captures/{capture_session_id}/audio
Content-Type: multipart/form-data

Fields:
  - client_ts: Unix seconds (string)
  - client_filename: original filename (string)
  - sha256_hex: SHA-256 hex digest of the raw file bytes (string)
  - file: binary audio data

Allowed MIME types: audio/wav, audio/m4a, audio/mp4
```

### Screenshots / Photos / Documents
Same multipart shape, different paths and MIME allowlists:
- `POST /api/captures/{capture_session_id}/screenshots` — `image/png`, `image/jpeg`
- `POST /api/captures/{capture_session_id}/photos` — `image/jpeg` only
- `POST /api/projects/{project_id}/documents` — `application/pdf`, `application/vnd.openxmlformats-officedocument.wordprocessingml.document`

### Response (HTTP 201)
```json
{
  "id": "019e45e4-58ee-7749-94f6-0d254adf619f",
  "kind": "audio",
  "volume_path": "/Volumes/.../file.wav",
  "mime_type": "audio/wav",
  "size_bytes": 3244,
  "sha256_hex": "2976da01...",
  "original_filename": "trigger.wav",
  "client_ts": "2026-05-20T14:57:33.000Z",
  "client_ts_source": "client",
  "uploaded_at": "2026-05-20T14:57:35.557Z"
}
```

### Auth Headers (unchanged)
All upload requests still require the standard two-layer auth:
- `Authorization: Bearer <M2M token>` (Layer 1 — App sidecar)
- `X-Lakeloom-Session-Token: <session_token>` (Layer 2)
- `X-Lakeloom-Timestamp: <unix_seconds>` (Layer 2)
- `X-Lakeloom-Signature: <ECDSA_sig>` (Layer 2)

**Canonical message for signature** (multipart uploads):
```
POST\n/api/captures/{id}/audio\n{unix_seconds}\n{sha256_of_entire_multipart_body}
```

Note: The SHA-256 in the signature canonical is over the **entire multipart body** (all fields + file boundary), not just the file bytes. The `sha256_hex` form field is the hash of **just the file bytes** (for server-side integrity verification after parsing).

## Verified End-to-End

- Notebook test ran full chain: pair → project → device assign → capture → upload
- HTTP 201 returned in ~2.2s
- File confirmed on UC Volume at expected path
- Metadata row confirmed in `lb_uploads_history` (Lakebase → Lakehouse Sync)
- SHA-256 matches between client-sent field and server-stored value

## What's NOT Changing

- Endpoint paths: stable as documented above
- Auth model: stable (Layer 1 + Layer 2)
- Multipart field names: stable (`client_ts`, `client_filename`, `sha256_hex`, `file`)
- UUIDv7 filenames: server generates, client doesn't control the stored filename
- MIME allowlists: stable per endpoint

## Action Items for iOS

1. **CaptureEngine upload implementation** can now target these endpoints with confidence — they work.
2. **Error handling:** Server returns RFC 9457 Problem Details on failure. Key error codes:
   - `UPLOAD_VOLUME_WRITE_FAILED` — server couldn't write to storage (retry-safe)
   - `UPLOAD_INTEGRITY_MISMATCH` — SHA-256 field didn't match received bytes (don't retry, re-hash)
   - `UNSUPPORTED_MEDIA_TYPE` (415) — MIME type not in endpoint's allowlist
3. **`client_ts` field:** Send as Unix seconds string. Server stores as ISO timestamp with `client_ts_source: "client"`. If omitted, server uses its own clock with `client_ts_source: "server"`.

Let me know if you need any changes to the response shape or want additional metadata in the 201 payload.
