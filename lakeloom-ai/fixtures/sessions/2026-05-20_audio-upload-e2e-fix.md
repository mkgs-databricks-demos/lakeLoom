# 2026-05-20: Audio Upload E2E Fix

## Summary

Fixed two blocking bugs in `server/routes/uploads/upload-routes.ts` that prevented any upload (audio, screenshot, photo, document) from ever succeeding. First successful audio upload recorded in `lb_uploads_history`.

## Problems

### Bug 1: `iosAuth` middleware factory invoked incorrectly

**Symptom:** Upload requests hung for exactly 60s (client timeout), server logged only `[upload] ingress.request` with no downstream processing.

**Root cause:** Route registration passed the bare `iosAuth` factory function reference instead of calling it:
```typescript
// BEFORE (broken) — Express called the factory with (req, res, next)
app.post(..., iosAuth, createUploadHandler(...))

// AFTER (fixed) — factory invoked, returns actual middleware
app.post(..., iosAuth({ lakebase: ctx.lakebase }), createUploadHandler(...))
```

The factory received `(req, res, next)` as its options object, tried to use `req` as a Lakebase pool, and silently failed without calling `next()`.

### Bug 2: SDK 0.17 object-signature mismatch

**Symptom:** After Bug 1 was fixed, uploads failed fast with HTTP 500 `UPLOAD_VOLUME_WRITE_FAILED`. OTel traces showed 404s to `/api/2.0/fs/directoriesundefined`.

**Root cause:** `@databricks/sdk-experimental` 0.17.0 switched from positional arguments to request-object signatures:
```typescript
// BEFORE (0.14.x positional — broken on 0.17)
await filesApi.createDirectory(directoryPath)
await filesApi.upload(filePath, stream, options)

// AFTER (0.17 object signatures)
await filesApi.createDirectory({ directory_path: directoryPath })
await filesApi.upload({ file_path: path, contents: webStream, overwrite: false })
```

The old code also had a multi-format retry loop that tried `directoryPath`, `directory_path`, `path`, and `create_directory` — all generating wasted 404 calls.

### Bug 2b: Environment variable name mismatch

**Symptom:** Volume paths resolved to `undefined` at runtime.

**Root cause:** Route file referenced env vars without `_PATH` suffix (`LAKELOOM_AUDIO_VOLUME`) but `app.yaml` injects them with the suffix (`LAKELOOM_AUDIO_VOLUME_PATH`).

## Changes

### `server/routes/uploads/upload-routes.ts`

1. **iosAuth invocation** — All 4 route registrations now call `iosAuth({ lakebase: ctx.lakebase })`
2. **Env var alignment** — `LAKELOOM_AUDIO_VOLUME` → `LAKELOOM_AUDIO_VOLUME_PATH`, same for screenshot/photo/document
3. **`createVolumeDirectory`** — Simplified to single correct SDK call: `filesApi.createDirectory({ directory_path: directoryPath })`
4. **`uploadVolumeFile`** — Uses Web `ReadableStream` with correct SDK object signature: `filesApi.upload({ file_path, contents: webStream, overwrite })`
5. **`deleteVolumeFile`** — Correct object signature: `filesApi.delete({ file_path: canonicalPath })`
6. **`FilesApi` type alias** — Updated to match SDK 0.17 method signatures
7. **Removed dead code** — `buildDirectoryCreateRequests()` function deleted (referenced removed `DirectoryCreateRequest` type)

### `package.json`

* `@databricks/sdk-experimental`: `0.14.2` → `0.17.0`

## Decisions

* **Fix Bug 1 first** — It masked all downstream behavior. Once fixed, uploads failed fast with actionable diagnostics.
* **Keep `createDirectory`** — UC Volumes don't auto-create nested directories. We still need it for `/{project_id}/{capture_id}/` paths, just called correctly once instead of shotgun retries.
* **Prefer SDK over raw `fetch`** — SDK handles auth/OIDC automatically. A raw `fetch` intermediate was briefly introduced but lacked Authorization headers and was replaced.
* **`ReadableStream` for upload contents** — SDK 0.17 expects Web Streams API `ReadableStream`, not Node `Readable`. Simple `controller.enqueue(buffer); controller.close()` pattern works.

## Validation

* Deployed via `bundle deploy --target dev` + `wc.apps.deploy()` restart
* Health check: `GET /healthz` → 200
* End-to-end test: QR pair → project → device assign → capture → audio upload
* **HTTP 201** in 2.234s with full response: upload ID, volume path, size, SHA-256, timestamps
* Confirmed in `lb_uploads_history`: 1 audio row with correct volume path, size (3244 bytes), SHA-256 match
* Upload ID: `019e45e4-58ee-7749-94f6-0d254adf619f`
* Volume path: `/Volumes/hls_fde_dev/dev_matthew_giglia_lakeloom/session_audio/6c49b7ae-3d24-4cbb-b05f-3de553c731da/2331ce3a-89ac-43ed-a8d2-f2cfc12cebb9/019e45e4-58ee-7749-94f6-0d254adf619f.wav`

## Files Modified

* `server/routes/uploads/upload-routes.ts` — Major rewrite of SDK call patterns, middleware invocation, env vars
* `package.json` — SDK version bump

## Remaining Cleanup

* `package-lock.json` may be stale (still references 0.14.2 internally) — regenerate on next `npm install`
* Diagnostic helpers `buildVolumePathCandidates` / `maybeBuildVolumePathCandidates` still present for logging context; can be removed if no longer useful
* Screenshots, photos, and document uploads should now also work (same code path) — not yet tested from iOS
