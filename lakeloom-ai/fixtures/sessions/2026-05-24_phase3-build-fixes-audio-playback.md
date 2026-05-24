# 2026-05-24: Phase 3 Media Viewer — Build Fixes & Audio Playback

## Context

Deployed Phase 3 (Media Viewer & Audio Playback) on branch `gc-phase3-browser-ui`. Initial code had multiple TypeScript compilation errors discovered through iterative deploy cycles. All diagnosed via OTel logs in UC.

## Problems & Fixes

### Deploy 1 — Template Literal Escaping (pre-session)
- **Error:** TS1127 Invalid character, TS1005 `;` expected, TS1160 Unterminated template literal
- **Root cause:** Python `executeCode` with `Path.write_text()` wrote `\\` before backticks in TypeScript template literals
- **Fix:** Rewrote file via `editAsset` tool (commit `3919599`)

### Deploy 2 — Express Param Type Mismatch (TS2345)
- **Error:** `Argument of type 'string | string[]' is not assignable to parameter of type 'string'`
- **Root cause:** Express `@types` defines `req.params.*` as `string | string[]`; Lakebase `query()` expects `string`
- **Fix:** Added `as string` type assertions on `req.params.upload_id` and `req.params.capture_session_id` (commit `fd98688`)

### Deploy 3 — Client Type Errors (TS6133, TS2322)
- **Errors:**
  - `ImageViewer.tsx(2,46)`: `Minimize2` declared but never read
  - `CaptureDetailPage.tsx(402,29)`: `Upload.original_filename` (`string | null`) not assignable to `UploadItem.original_filename` (`string | undefined`)
- **Fix:** Removed unused import; changed `UploadItem.original_filename` to `string | null | undefined`; added `?? undefined` coercion in MediaPanel (commit `f645963`)

### Deploy 4 — Silent Audio Playback
- **Symptom:** Images render fine, audio player shows but no sound. Server returns 200/206 correctly.
- **Root cause:** Chrome's Web Audio API treats `<audio>` elements connected to `MediaElementAudioSourceNode` as CORS-tainted when served through auth proxies. Result: audio output silently muted (no error thrown).
- **Fix (two-part):**
  1. **Server:** Added `Access-Control-Allow-Origin` (mirrors request Origin) + `Access-Control-Allow-Credentials: true` on `/api/media/:upload_id` responses
  2. **Client:** Added `crossOrigin="anonymous"` on `<audio>` element; deferred `createMediaElementSource()` until after first `timeupdate` event confirms playback is active
- **Commit:** `7d0ce9e`

## Successful Deploy

Deployment `01f1573cea591feaa48fd86a3bd152bb` at 06:52:00Z (35.3s):
- `tsc` server + client passed clean
- Vite built client in 2.56s
- App started, Lakebase pools initialized, all migrations applied

## Commits (session)

| Hash | Description |
|------|-------------|
| `fd98688` | fix(media): add type assertions for req.params (TS2345) |
| `f645963` | fix(ui): remove unused Minimize2 import, fix null/undefined type mismatch (TS6133, TS2322) |
| `7d0ce9e` | fix(media): add CORS headers + defer Web Audio init to fix silent audio playback |

## Files Modified

- `server/routes/media/media-routes.ts` — type assertions + CORS headers
- `client/src/components/media/ImageViewer.tsx` — removed unused import
- `client/src/components/media/MediaPanel.tsx` — nullable `original_filename`, `?? undefined` coercion
- `client/src/components/media/AudioPlayer.tsx` — `crossOrigin`, deferred Web Audio init, `waveformReady` state

## Lessons Learned

1. **Always use `editAsset` for TypeScript files containing template literals** — Python string escaping corrupts backticks
2. **Express `req.params` needs `as string` casts** — types are `string | string[]` but route params are always strings
3. **Lakebase nullable columns return `null`, not `undefined`** — TypeScript interfaces must use `| null` not just `?`
4. **Web Audio + auth proxy = silent playback** — `createMediaElementSource()` before CORS handshake silently mutes; defer connection and set `crossOrigin="anonymous"` + explicit CORS response headers

## Status

- Branch `gc-phase3-browser-ui` at `7d0ce9e` (7 commits total)
- Build passing, app live
- Audio playback fix deployed, pending user verification
