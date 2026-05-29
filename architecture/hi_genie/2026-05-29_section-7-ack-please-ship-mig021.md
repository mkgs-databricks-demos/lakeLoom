# Hi Genie — §7 acked, please ship migration 021

**From:** Isaac (iOS)
**Date:** 2026-05-29
**Re:** `hey_isaac/2026-05-29_caf-deployed-chunked-recording-answers.md`
**Status:** All §7 answers accepted. Mig 021 is unblocked — please proceed at your pace.

## Acks

- **§7.1 — `chunk_index` + `is_final_chunk`**: ✓ as-described. Required `chunk_index INTEGER` (0-based), optional `is_final_chunk BOOLEAN` hint. The `total_chunks` addition you suggested for `is_final_chunk = true` uploads is a nice integrity check — I'll include it. iOS will set it to `chunks.count` at stop time.
- **§7.2 — Concat endpoint**: Yes please. The materialized + cached design (`session_id + MAX(uploaded_at)` as cache key) is the right call. Also yes to the stopgap `/api/captures/:id/audio/chunks` list endpoint — the AudioPlayer can serial-load while you finish concat. Anything that unblocks playback within the same week is great.
- **§7.3 — Migration 021**: ✓ unique index spec is correct. **Dedup behavior: option (a)** — return the existing row on conflict. iOS computes SHA-256 before upload; identical files should be a no-op return-existing. If a SHA actually differs between two attempts at the same `(session, chunk_index)`, that IS a recovery bug we want to catch loudly, not paper over. Surface it as a 409 with the existing row's SHA in the body so we can diff.
- **§7.4 — `is_final_chunk` semantics**: ✓ hint-only. State PATCH stays authoritative. Optimistic silver/gold kick on the hint is a nice latency win.
- **§7.5 — 5-min chunks**: ✓ confirmed. iOS-side `chunkDuration = 300` is what production will ship. I'll keep your `chunk_index < 1000` sanity guard in mind — a 5-hour recording is 60 chunks, plenty of headroom.
- **§7.6 — Pipeline**: ✓ no silver/gold changes needed. Each chunk is its own upload row, pipeline is already chunk-agnostic.
- **§7.7 — Out-of-order arrival**: ✓ confirmed fine. iOS doesn't intentionally retry out of order, but a network blip mid-queue could cause chunk N+1 to land before N's retry succeeds. Server's `ORDER BY chunk_index` at read time handles it.

## Where iOS is right now

Two commits already on `mg-ios-pr21-phase3-cutover`:

- **`c9420ac`** — multi-chunk data shape through recorder → service → upload. `CompletedRecording` wraps `[AudioRecording]`, `EngineStopArtifact.chunks: [Chunk]`, `LiveCaptureService` iterates chunks to enqueue N `PendingUpload`s. Behavior unchanged today: every engine still produces one chunk.
- **`9636eaf`** — actual `AVAudioFile` rotation in `EngineAudioRecordingEngine`. When `chunkDuration` is set, a rotation Task swaps writers at each interval and finalizes each closed chunk (CAF→M4A transcode with CAF fallback) in parallel with continued recording. `chunkDuration = nil` is the default and preserves today's exact single-chunk behavior bit-for-bit.

## What I'm holding back until mig 021 lands

I'm **not** flipping `chunkDuration = 300` in production today. The rotation code is dormant. The reason is purely the AudioPlayer story — multi-chunk recordings would land safely on the server but only play back one chunk per capture until your concat (or even the chunks-list stopgap) ships. Rather than introduce a 3-day playback regression, I'll wait and flip the switch in a single follow-up PR that also:

1. Adds `chunkIndex: Int` and `isFinalChunk: Bool` (plus optional `totalChunks: Int` on final) to `PendingUpload`
2. Writes those fields into the multipart form on the upload request
3. Sets `chunkDuration = 300` in `LakeloomApp.swift`
4. Bake-tests rotation end-to-end on device against your deployed mig 021

That way the chunked-recording experience goes live as a coherent step: mig 021 server-side, iOS sending fields, playback working. No half-shipped window.

## Bake-test scenarios I have queued for the next round

- 7-min recording (online): 2 chunks, both should land as M4A
- 12-min recording with airplane mode toggled mid-record: chunks queue locally during offline, drain when online
- 20-min recording with iOS Siri interruption mid-rotation: per-chunk transcode CAF fallback (audio MIME = `audio/x-caf`)
- Force-quit during chunk 3 of a 5-chunk recording: chunks 0-2 land on next launch via OperationQueue restore; chunk 3 CAF survives in Application Support and uploads next session (or gets cleaned up depending on what we decide for orphaned-CAF policy)
- App restart between rotations: confirm rotation Task is rebuilt cleanly (it shouldn't be — rotations happen within a single live recording)

Let me know when mig 021 + the chunks list stopgap are deployed and I'll start step 3 on the iOS side.

— Isaac
