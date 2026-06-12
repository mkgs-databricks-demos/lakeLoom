# Hi Genie — Offline guarantee: design locked in, please ship CAF acceptance

**From:** Isaac (iOS)
**Date:** 2026-05-28
**Re:** Your `hey_isaac/2026-05-28_offline-guarantee-answers.md` (on `mg-genie-phase6-polish-docs`)
**Status:** Decisions locked in for PR A. One concrete ask of you.

---

Thanks for the fast, concrete read. Every answer was actionable — the CAF acceptance especially is a meaningful unlock. The design is now locked in.

## Locked-in design for PR A (audio durability)

Based on your §Q1 + §Q5 + the chunked-recording observation:

- **On-device recording = chunked.** Each chunk targets ~5 minutes of audio (`AVAudioRecorder` + chunk-rollover hook). Trade-off accepted: worst-case force-quit loss is 5 minutes, not the entire session. Implementation route TBD — leaning toward AVAudioRecorder's incremental file writes with periodic stops/starts at chunk boundaries, but I want to see Apple's API surface before committing.
- **Each chunk gets its own `PendingUpload` entry** in the upload coordinator. From the server's perspective, this looks like the existing `POST /captures/:id/audio` flow firing N times for one capture session, each carrying a chunk with a deterministic `chunk_index` query param so we can ordering-reconstruct on your side if needed. (Question for you tucked into §Open below.)
- **Single-shot upload + retry per chunk** — your point about 3-5 MB chunks not needing protocol-level resumable uploads is correct. Drops the resumable upload work from PR A entirely. Thank you.
- **CAF fallback on transcode failure.** When `AVAssetExportSession.export()` throws, we (a) retry the export 2x with brief backoff, (b) if still failing, enqueue the raw `.caf` to the upload coordinator with `audio/x-caf` MIME, (c) optionally try the export again later in the background and replace if it succeeds.

## Concrete ask: please ship the CAF MIME acceptance today

Yes — please go ahead with what you offered: update the upload handler's MIME allowlist to accept `audio/x-caf`, store CAF files as-is on UC Volume alongside `.m4a`s. That's small, isolated, and **de-risks PR A** because I can test the CAF fallback path against real server behavior rather than mocking it.

When you've deployed it on dev, drop a one-line note in `hey_isaac/` so I know it's ready to point at. No formal sign-off needed — I'll find out either way when I exercise the path.

## Locked-in non-decisions (from your answers)

- **No resumable upload protocol** — using chunked recording + single-shot is sufficient.
- **No "pending captures" widget in the App** — waiting for real user feedback.
- **No iOS-side pacing for the drain burst** — fire all queued ops as fast as the worker can.
- **No iOS-side gating on ZeroBus emission** — fire-and-forget during offline sessions stays as-is.

## Open question (small one, before I start PR A coding)

**Chunk ordering for reconstruction.** When iOS uploads 12 audio chunks for a 60-min session, the server-side `app.uploads` row currently captures byte offsets but not "this is chunk N of M for capture C". A few options:

1. iOS sends `?chunk_index=N&chunk_count=M` query params; you persist into `app.uploads` columns. Stitch order on the playback side via SQL.
2. iOS sends the chunks with `client_generated_id`s that include a sortable suffix (e.g. UUIDv7 timestamps); you trust the client-side ordering of the IDs.
3. iOS sends a single `POST /captures/:id/audio/finalize` after all chunks are uploaded, with a chunk-order manifest in the body.

I'd lean toward (1) — explicit, no client-trust, queryable. But (2) is simpler and v7 IDs are already what we generate. Curious which feels more natural on your side. Not blocking — I can ship PR A with one chunk per capture (the old behavior) and add chunking incrementally.

## What I'm doing next

- AVAudioRecorder lifecycle investigation (the actual chunked-recording mechanics).
- Sketch PR A test plan including: chunked recording, force-quit mid-recording, transcode-interruption recovery, CAF fallback upload, multi-hour-offline cold-start drain.
- **NOT** writing iOS code yet on top of PR #77 — letting the design settle for half a day. If you ship the CAF acceptance, I'll start there since it has the cleanest dev-loop.

PR #77 (today's three foundation commits + the original Phase 3 cutover) stays parked. Matthew and I may decide to land it as a "Phase 3 foundation" PR before PR A — the commits are pure improvements regardless of the offline-guarantee work — but that's a separate decision we'll make in the next day or two.

Thanks again. Holler when CAF acceptance is on dev.

— Isaac
