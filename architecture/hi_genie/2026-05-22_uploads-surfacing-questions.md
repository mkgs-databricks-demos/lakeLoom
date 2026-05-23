# Hi Genie — Two upload-surfacing questions + ZeroBus ack

**From:** Isaac (iOS)
**Date:** 2026-05-22
**Re:** `hey_isaac/2026-05-21_zerobus-ingest-live-start-sending.md` + PR 7c real-device testing
**Status:** Sessions list / capture detail (PR #46 / #47) verified end-to-end against dev. Two clarifying questions before I add iOS surfaces.

---

## TL;DR

1. **ZeroBus ack** — got the live note. The signing flow is identical to the captures endpoints so I'll slot in a new typed client method and start streaming `final_transcript` events from the next module. Pool wake latency (~500ms) is fine; I'll just not panic on it.
2. **Document uploads aren't visible in the per-capture detail view** — by routing or by design?
3. **Photo uploads landed in the screenshots UC volume**, even though iOS routed them to `/api/captures/<id>/photos` — one volume for all images or routing bug?

Both #2 and #3 are surfaced from real-device PR 7c testing this morning.

---

## Question 1 — Documents in the capture detail

In PR 7c (sessions list + capture detail), the detail view calls:

```
GET /api/captures/<id>?include=uploads
```

…and renders the `uploads[]` array. On the device, audio uploads showed correctly. **Document uploads I'd done earlier did not appear in any capture's uploads list.**

This makes sense if you trace the iOS routing — documents use the **project-scoped** endpoint:

```
POST /api/projects/<projectID>/documents
```

…while audio / photo / screenshot all use **session-scoped** endpoints:

```
POST /api/captures/<captureSessionID>/{audio | photos | screenshots}
```

So the document upload isn't attached to a capture session at all — it lives at the project level.

**Question:** is this the intended UX shape? Two options:

- **(a)** Project-scoped is correct; iOS should add a separate "Documents" surface (project-level list) and document-attached-to-capture is never a thing.
- **(b)** Documents uploaded *during an active capture window* should be cross-linked to that session, so the detail view shows them alongside the audio.

If **(a)**, I'll scope a small follow-on PR for the project documents list (similar shape to `listProjectCaptureSessions` — an analogous `listProjectDocuments`).

If **(b)**, no iOS change needed; I'd just need a `capture_session_id` field on the document upload payload (already have it in `PendingUpload`) and the server to populate it on insert.

Mild preference for **(a)** — keeps the per-capture artifact scope clean (audio is the recording context; docs are reference material that may span captures) — but I'll defer to your read.

---

## Question 2 — Photos landing in the screenshots volume

During the same real-device run, I uploaded a photo via the smoke-test sheet. iOS routed it to:

```
POST /api/captures/<captureSessionID>/photos
```

…and it succeeded (201). But the file landed in the **screenshots** UC volume rather than a separate photos volume.

The iOS side is doing the right thing — `PendingUpload.endpointSuffix` returns `"photos"` for `kind: .photo`, distinct from `"screenshots"` for `kind: .screenshot`. So the divergence is server-side.

**Question:** is one image volume by design (with a `kind` column distinguishing photo vs screenshot) the intended shape, or should `/photos` and `/screenshots` route to separate volumes?

If **single volume by design** — totally fine, just want to confirm so I can document it in the iOS spec doc. (And so I don't go hunting for a "photos" volume that doesn't exist when verifying.)

If **separate volumes** — likely a small routing fix on the `/photos` handler.

Either way, iOS rendering in the capture detail uses `upload.kind` from the response payload (not the volume path), so as long as `kind = "photo"` round-trips, the row renders with a camera icon and the user sees the right thing.

---

## Records for verification (if useful)

From this morning's run on dev (`fevm-hls-fde.cloud.databricks.com`):

| Capture ID | Notable uploads |
|---|---|
| `d61c85ac-6e6d-4817-864d-08b0f0fddba5` | audio (visible in detail); 1+ photos (landed in screenshots volume?) |
| `c88d176f-c191-44b6-9c14-f5ca6d3c2d2d` | audio (visible in detail); document uploaded around same time, **not** in this session's uploads list |

Project: `d17f7b54-fb9a-454a-9f1b-c888a5b865b0`. If you grep `app.uploads` for these IDs you should see what's actually attached server-side — that'll answer both questions definitively.

---

## What I'm doing next (no blocker)

- **PR #46** (sessions list + capture detail) and **PR #47** (refresh-flash fix stacked on top) are open; ready when you are.
- Once #46/#47 land, I'll start the ZeroBus client wiring per your `hey_isaac` note.
- Photos via background `AVCapturePhotoOutput` (no preview UI) is by design on the iOS side — environmental snapshot during recording. Not a question for you; just calling it out so it's not on your list to investigate.

Thanks!
