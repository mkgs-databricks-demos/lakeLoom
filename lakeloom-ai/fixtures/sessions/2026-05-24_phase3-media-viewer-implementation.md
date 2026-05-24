# 2026-05-24: Phase 3 Media Viewer & Audio Playback

## Context

After merging the `mg-ui-improvements` branch (Phase 2 + iOS auth hardening), created `gc-phase3-browser-ui` branch and implemented the full Media Viewer & Audio Playback feature (Phase 3 of the browser UI plan).

## Problems Encountered

### TypeScript Build Failure (deployment `01f15739cd7b1e16acae193f67419665`)

When `media-routes.ts` was written via Python's `Path.write_text()` using triple-quoted strings containing TypeScript template literals (backticks), Python preserved `\`` escape sequences literally in the output. The TypeScript compiler threw:
- `TS1127: Invalid character` (line 118)
- `TS1005: ';' expected` (line 178)
- `TS1160: Unterminated template literal` (line 325)

**Fix:** Rewrote using `editAsset` tool which passes content directly without Python string escaping.

**Lesson:** Always use `editAsset` (not `executeCode` with `Path.write_text()`) for TypeScript/JavaScript files containing template literals.

## Changes

### Server: Media Streaming Proxy (`server/routes/media/media-routes.ts`)

New route file with 3 endpoints:

- `GET /api/media/:upload_id` — Streams file from UC Volume via internal AppKit files plugin proxy. Full HTTP Range request support (bytes=START-END → 206 Partial Content). Essential for audio `<audio>` element seeking. Sets Accept-Ranges, Content-Type, Content-Disposition, Cache-Control headers.
- `GET /api/media/:upload_id/metadata` — Returns upload record from Lakebase (kind, mime_type, size, sha256, timestamps).
- `GET /api/media/session/:capture_session_id` — Lists all uploads for a capture session (for media panel population).

**Design decisions:**
- Proxies through AppKit files plugin's internal `/api/files/:volumeKey/download` route (inherits its SDK auth + volume resolution)
- Resolves volume path by stripping first 4 segments from `volume_path` (/Volumes/catalog/schema/volume/)
- Maps upload `kind` to volume key: audio→session_audio, screenshot/photo→screenshots, document→documents
- Uses `dualAuth` (browser OR iOS Layer 2)

### Client: Media Viewer Components (`client/src/components/media/`)

Four new components:

**AudioPlayer.tsx** (10.5KB)
- HTML5 `<audio>` element with custom branded controls
- Web Audio API waveform visualization (AnalyserNode → canvas frequency bars)
- Playback speed selector: 0.5x, 0.75x, 1x, 1.25x, 1.5x, 2x
- Seek bar with hover thumb indicator
- Play/Pause, Restart, Mute/Unmute, Download buttons
- Title + file size footer
- Lava 600 accent for play button and progress indicators

**ImageViewer.tsx** (8KB)
- Thumbnail card (aspect-ratio container, object-contain)
- Hover overlay with expand icon
- Lightbox modal: zoom in/out/reset (0.5x–4x), percentage display
- Download link, close on Escape, backdrop click to close
- Bottom info bar: title, dimensions, MIME type, size, upload date
- Kind indicator: Camera icon (photo) vs Image icon (screenshot)

**DocumentViewer.tsx** (5.3KB)
- PDF: inline rendering via `<iframe>` with toolbar
- DOCX: download card with FileText icon + prominent download CTA
- Info footer: type label, size, upload date
- Collapsible SHA-256 integrity hash detail
- Open in new tab (PDF only)

**MediaPanel.tsx** (2KB)
- Auto-dispatch container: detects MIME type from upload record
- `audio/*` → AudioPlayer
- `image/*` → ImageViewer
- `application/pdf` or `officedocument` → DocumentViewer
- Unknown → download link fallback

**index.ts** — barrel exports for all components

### Integration: CaptureDetailPage Update

- Upload timeline items are now clickable (toggle selection)
- Selected item gets highlighted background (info-subtle blue) + border
- Clicking shows `MediaPanel` below timeline with fade-in animation
- "Close preview" button to dismiss
- Import added for `MediaPanel` from `../../components/media`

### Server Registration

- `setupMediaRoutes` imported and registered in `server/server.ts` (after `setupZerobusRoutes`)

## Commits

| Hash | Description |
|------|-------------|
| `5689c3b` | feat(media): add streaming proxy endpoint with Range support |
| `16d7abd` | feat(ui): add media viewer components |
| `ce4a632` | feat(ui): integrate MediaPanel into CaptureDetailPage |
| `3919599` | fix(media): remove escaped backticks causing TS build failure |

## Files Modified

- `server/routes/media/media-routes.ts` (new)
- `server/server.ts` (import + registration)
- `client/src/components/media/AudioPlayer.tsx` (new)
- `client/src/components/media/ImageViewer.tsx` (new)
- `client/src/components/media/DocumentViewer.tsx` (new)
- `client/src/components/media/MediaPanel.tsx` (new)
- `client/src/components/media/index.ts` (new)
- `client/src/pages/projects/CaptureDetailPage.tsx` (media panel integration)

## Also Completed This Session (before Phase 3)

- Verified migration 012 (user_id remediation) and 013 (device assignment backfill) applied in UC
- Reviewed OTel traces for session completion flow (3 PATCH /state calls, 13–21ms, all OK)
- Updated PROJECT_MEMORY_APP.md with iOS auth hardening details
- Created session summary for iOS auth hardening (`2026-05-24_ios-auth-hardening-device-backfill.md`)
- Assessed merge safety (clean auto-merge, no file overlap with Isaac's iOS PRs)
- Provided PR title/description for `mg-ui-improvements` → main merge
- Created `gc-phase3-browser-ui` branch from updated main

## Status

- Branch `gc-phase3-browser-ui` pushed to origin (4 commits)
- Build fix deployed — awaiting successful build confirmation
- Phase 3 implementation complete pending deploy verification
- Existing FilesPage retained as admin volume browser (not repurposed)
