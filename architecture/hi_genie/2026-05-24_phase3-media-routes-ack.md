# Hi Genie — Phase 3 media routes acked + iOS reconciled

**From:** Isaac (iOS)
**Date:** 2026-05-24
**Re:** PR #61 (Phase 3 browser UI) — specifically `media-routes.ts`
       + the `upload_kinds` enrichment on captures list
**Status:** iOS reconciled with the actual contract; everything green
            on this end.

---

## TL;DR

I was mid-flight on a documents surface for iOS when PR #61 landed. I had scaffolded against a guessed contract (`GET /api/projects/:id/documents` returning `{ documents: [...] }`) — your shipped path is `GET /api/media/project/:project_id` returning `{ uploads: [...] }`. Repointed the iOS client to your real route; everything else folds in cleanly. Nothing for you to do here.

---

## What I reconciled

| Field | My scaffold | Your shipped | iOS resolution |
|---|---|---|---|
| Path | `/api/projects/:id/documents` | `/api/media/project/:project_id` | Repointed `LiveCaptureAPIClient.listProjectDocuments` |
| Response key | `documents` | `uploads` | Decoder updated |
| Item shape | Full `CaptureUpload` | Leaner: `id`, `kind`, `mime_type`, `original_filename`, `size_bytes`, `uploaded_at` | New `ProjectDocument` value type (separate from `CaptureUpload` so the leaner shape doesn't force me to weaken the capture-detail decoder) |
| Filter | `kind = 'document'` | `capture_session_id IS NULL` | Fine — iOS lists everything project-level. The `kind` field is on each row so the UI shows the right icon (doc / audio / photo / screenshot). |
| Pagination | `?limit&before` | None | iOS drops the params. Will wire if you add a cursor later. |
| Auth | iosOnly (guessed) | dualAuth | Already correct — iOS routes through `LakeloomAppClient.requestRaw` so Layer 2 headers go on automatically. |

`size_bytes` decode is lenient (number-or-string) per the 2026-05-20 bigint discussion. `original_filename` is optional. `uploaded_at` decodes as ISO 8601.

## Capture list `upload_kinds` enrichment

I also saw you added `upload_kinds` to the captures list response (the `array_agg(DISTINCT kind)` LATERAL join in `capture-routes.ts`). iOS's `CaptureSession` decoder ignores unknown fields by default, so it's a no-op on my side today. If you want me to surface a "Audio + Photos" badge next to each row in the sessions list, I can add it in a follow-up — just let me know if there's a preferred render style. Probably most useful once captures start carrying multiple kinds (audio + photos + screenshots).

## What iOS now offers

Documents sheet accessible from the home toolbar menu ("Documents" entry, right under "Switch project"). Loading / empty / loaded / error states with brand styling. Pull-to-refresh re-fetches. Each row shows the filename, MIME type in DM Mono, byte size, and relative `uploaded_at` time. The kind icon picks the right SF Symbol per `CaptureUpload.Kind` so an audio-pipeline transcript renders distinct from a PDF reference doc.

What I haven't wired yet (separate iteration):

* **Tap-to-view** — I'll route through `GET /api/media/:upload_id` (your proxy with Range support) when I add the in-app viewer. Probably PDFs / markdown rendered inline, audio + photos play/show via QuickLook.
* **Upload from iOS** — the POST documents route exists; iOS doesn't yet have an "Upload document" affordance. Will add when there's a concrete use case.

## What I shipped on the iOS side (rebased on top of your main)

Three commits on `mg-ios-pr10-live-ui-and-docs`:

1. `feat(recording): live transcript panel on RecordingView` — fans out the on-device speech recognizer's segments to the recording view's scrolling card so the FDE sees their own words appearing in real time during a session
2. `feat(documents): listProjectDocuments + ProjectDocumentsView` — the surface above, now matching your contract
3. `feat(recording): in-session photo capture` — "Take photo" button on the recording view that uses the existing `PhotoCapture` to attach JPEGs to the active capture session; stopCapture's watcher now snapshots ALL non-terminal uploads for the session (not just audio) so server-side state=completed waits for photos to drain

Will open a PR once I've smoke-tested all three on device. Thanks for the Phase 3 work — the modal-overlay media viewer + per-capture-card icons sound like a big browser-side polish hit, and your `media-routes.ts` is exactly the proxy iOS will lean on for tap-to-view.
