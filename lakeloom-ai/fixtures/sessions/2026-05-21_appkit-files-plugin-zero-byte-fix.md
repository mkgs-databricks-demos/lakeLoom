# 2026-05-21 — AppKit Files Plugin: Zero-Byte Upload Fix

## Problem

All uploaded files (audio, screenshots, photos, documents) persisted as 0 bytes in UC Volumes despite:
- 201 responses from upload endpoints
- Correct Lakebase metadata (size_bytes, sha256_hex, timestamps)
- OTel logs showing `volume.write_succeeded`

## Root Cause

`@databricks/sdk-experimental@0.17.0`'s `files.upload()` method silently failed to serialize request bodies (both `ReadableStream` and raw `Buffer`). The HTTP PUT to `/api/2.0/fs/files/{path}` was sent with 0 content bytes regardless of input format.

## Fix: AppKit files() Plugin (0.36.0)

Replaced direct SDK usage with AppKit's built-in `files()` plugin, which uses its own `FilesConnector` — a correct `fetch`-based implementation with proper `Content-Length` headers.

### Key Changes

| File | Change |
|------|--------|
| `package.json` | `@databricks/appkit` 0.24.0 → 0.36.0, `@databricks/appkit-ui` 0.24.0 → 0.36.0 |
| `server/server.ts` | Added `files()` plugin with `policy: files.policy.allowAll()` per volume; migrated to `onPluginsReady` pattern (0.36.0 breaking change) |
| `server/routes/uploads/upload-routes.ts` | Full rewrite: removed `WorkspaceClient`/`FilesApi`/`ReadableStream`/FUSE code; uses `appkitFiles(volumeKey).upload(relativePath, buffer, { overwrite: false })` |
| `app.yaml` | Added `DATABRICKS_VOLUME_FILES`, `DATABRICKS_VOLUME_SESSION_AUDIO`, `DATABRICKS_VOLUME_SCREENSHOTS`, `DATABRICKS_VOLUME_DOCUMENTS` env vars (files plugin auto-discovery) |
| `resources/lakeloom_ai.app.yml` | Added `files` resource (manifest-required default); added Task 4 `grant_xcode_spn_volume_access` to `configure_app_spn` job |

### Debugging Journey (Attempts That Failed)

1. **ReadableStream wrapper** — SDK didn't consume the stream
2. **Raw Buffer to SDK** — SDK still sent 0 bytes
3. **FUSE mount (node:fs)** — App containers have NO FUSE access to UC Volumes
4. **Hybrid SDK mkdir + FUSE writeFile** — writeFile also failed (no FUSE)
5. **AppKit 0.24.0 files() with policy** — `policy` field didn't exist in 0.24.0
6. **AppKit 0.24.0 files() without policy** — `throwIfNoUserContext` enforced OBO
7. **`.asUser(req)` in 0.24.0** — AsyncLocalStorage context didn't propagate (bug)

### AppKit 0.36.0 Breaking Changes Resolved

1. `server({ autoStart: false })` removed → use `server()` + `onPluginsReady` callback
2. `VolumeConfig.policy` now exists → `files.policy.allowAll()` permits all operations
3. `auth` defaults to `"service-principal"` → no OBO needed, App SPN executes directly
4. `DATABRICKS_VOLUME_*` env vars required for plugin auto-discovery

### Architecture Decision: SP Mode (Not OBO)

Volume writes execute as the **App SPN** (service-principal mode) because:
- iOS uploads authenticate via Xcode SPN Bearer token, not browser OBO
- The App SPN has WRITE_VOLUME grants on all three volumes
- User attribution is recorded in **Lakebase** (`user_id`, `paired_session_id`) — the authoritative audit trail
- OBO (`x-forwarded-access-token`) is designed for browser users, not SPN-to-SPN flows

### Grants Applied

Xcode SPN (`bc67e71b-99af-4357-a981-05eaed8c9b93`) granted `READ_VOLUME` + `WRITE_VOLUME` on:
- `session_audio`
- `screenshots`
- `documents`

(Applied via `configure_app_spn` job Task 4, validated via `SHOW GRANTS`.)

## Verification

```
File size:     3,244 bytes (expected: 3,244)
SHA-256:       2976da01e205a110c9fa41d47659e238a5c6d3c3f3137582f2949853faa201dd
Expected SHA:  2976da01e205a110c9fa41d47659e238a5c6d3c3f3137582f2949853faa201dd
Size match:    True
SHA match:     True

✅ UPLOAD VERIFIED — bytes persisted correctly
```

OTel log sequence: `ingress.request` → `request.accepted` → `request.received` → `volume.path_resolved` → `volume.write_attempt` → `volume.write_succeeded` → `metadata.insert_succeeded` → `ingress.response` (201, 592ms).

## Files Modified

- `server/server.ts`
- `server/routes/uploads/upload-routes.ts`
- `package.json`
- `app.yaml`
- `resources/lakeloom_ai.app.yml`
- `resources/configure_app_spn.job.yml`

## Next Steps

- Isaac to smoke-test all upload types from iOS (audio, screenshots, photos, documents)
- Verify Isaac's pending 219 MB m4a upload retries succeed
- Consider removing `@databricks/sdk-experimental` from package.json (no longer used)
