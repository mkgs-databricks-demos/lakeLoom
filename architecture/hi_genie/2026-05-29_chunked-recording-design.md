# Chunked recording design — PR A piece 4

**From:** Isaac (iOS)
**Date:** 2026-05-29
**Status:** Design doc. Server-side contract questions in §7. Starting iOS implementation today.
**Supersedes:** §3.2's "chunked recording is one option I'm weighing" framing — we're going with chunked.

---

## 0. Why this is the design

Your synchronous-transcode design in `mg-genie-caf-upload-support` works for files up to ~100 MB CAF, after which the server-side ffmpeg pass blows past a 30s HTTP timeout. The dominant use case Matthew described is **multi-hour offline recording** — a single monolithic 60-min CAF would be ~600 MB and would never make it through that path.

The right answer isn't fixing the server's transcode budget; it's making iOS produce small enough uploads that the budget is never tested. Chunked recording does that: a 60-minute session becomes 12 chunks of ~5 minutes each. Each chunk is ~5 MB M4A or ~50 MB CAF — comfortably inside any HTTP / ffmpeg budget. Each chunk is independently retry-able. Each chunk's loss boundary is bounded (~5 minutes worst case for force-quit / jetsam).

This is also the architecturally cleaner thing to do regardless of the server budget: it gives us natural durability, real progress UI, isolated transcode failures, and a sane recovery story.

## 1. User-facing contract — what the SA sees

Unchanged from today. The user taps Record, talks for an arbitrary duration, taps Stop. They never see "chunks." The capture session is the unit of meaning; chunks are an implementation detail.

The pending-uploads pill on the home view shows "uploading N files…" — `N` is now the chunk count rather than always 1. That's actually more honest and gives real progress signal.

## 2. iOS-side mechanics

### 2.1 Rotation strategy

Single AVAudioEngine running continuously for the duration of the capture. Tap stays installed. Inside the engine actor, the **current AVAudioFile writer** rotates every chunk-boundary's worth of frames.

- **Chunk size:** 5 minutes. At a typical 48 kHz / 1-channel input, that's ~14.4M frames per chunk.
- **Tracking:** `FrameCounter` already exists; we add a chunk-boundary check after each tap callback. When the cumulative frame count for the *current chunk* crosses the threshold, the tap signals "rotate."
- **Rotation execution:** runs in the actor's serial context, not on the real-time audio thread. The tap's writer reference is held inside a thread-safe holder (NSLock-wrapped) so the actor can swap it atomically without racing the real-time tap.

The mechanics:

1. Actor receives "rotate" signal (via a `Continuation` resumed from the tap, or a periodic timer task — leaning toward the timer task with a frame-based gate check, since that's easier to reason about).
2. Actor takes the writer-holder lock.
3. Close the current `AVAudioFile`. Its destructor flushes the CAF tail and closes the file. The CAF on disk is now a complete chunk artifact.
4. Open a new `AVAudioFile` at the next chunk URL (`chunk-<N+1>-<timestamp>.caf`).
5. Swap the holder's pointer to the new writer. Release the lock.
6. Tap continues, writing into the new file.
7. Spawn a detached `Task` to:
   - Transcode the just-closed CAF → M4A (or fall back to CAF per existing piece 1 logic)
   - Construct a `PendingUpload` for the chunk
   - `uploadCoordinator.enqueue(...)` — fires the upload without blocking the recording

**Audible gap concern:** the rotation happens entirely outside the audio thread; the only thing the tap waits on is the writer-holder lock during a swap. Lock contention is ~hundreds of nanoseconds; the tap's buffer interval at 4096 samples / 48 kHz is ~85 milliseconds. Six orders of magnitude of headroom. The user will hear zero gap.

### 2.2 PendingUpload data-model additions

```swift
public struct PendingUpload: ... {
    // ... existing fields ...
    public let chunkIndex: Int          // 0-based, monotonic per captureSessionID
    public let isFinalChunk: Bool       // true iff this is the last chunk of the session
}
```

`chunkIndex` is required (defaults to 0 for legacy callers / 1-chunk recordings). `isFinalChunk` is set by `stopCapture()` on the last chunk it enqueues — see §2.4.

The existing `originalFilename` field can carry `chunk-<N>-<timestamp>.caf|m4a` so server-side debugging is straightforward.

### 2.3 Cold-start recovery

On app launch, today's recovery path consults `CaptureContextStore` to detect an in-flight capture from a dead session. Extension:

1. Existing path: read `CaptureContextStore`, restore the in-flight `CaptureContext` if any.
2. New: for that context's `captureSessionID`, scan `<Application Support>/Captures/<id>/` for any `chunk-*.caf` and `chunk-*.m4a` files.
3. For each chunk file not already represented in the persisted `UploadQueueStore`:
   - Validate the file (open as AVAudioFile to verify it has a complete moov / valid header; if invalid, attempt a partial-CAF recovery via `AVURLAsset(url:)` which can usually salvage everything up to the last good frame).
   - Build a `PendingUpload` with the appropriate `chunkIndex` (parsed from filename).
   - Enqueue it.
4. Mark the last enqueued chunk as `isFinalChunk = true` even though the user never tapped Stop — the app died, so this is "as final as we'll ever get."
5. Transition the capture state to `.finalizing` (uploads will drain when network returns) or `.failed` if no chunks are recoverable.

This means a user who recorded for 47 minutes and then had their phone die at minute 48 gets back 9 chunks of ~5 min each (chunks 0-8) when they relaunch the app. The 10th chunk might be partial; we keep what's salvageable.

### 2.4 `stopCapture()` changes

Today: one `recorder.stop()` call → one `PendingUpload` enqueued → `.finalizing` state.

With chunking:

1. `recorder.stop()` rotates one final time, returning the **last** chunk's artifact (the in-progress chunk at the moment Stop was tapped).
2. The engine signals `isFinalChunk = true` on this artifact via a new field on `EngineStopArtifact`.
3. `LiveCaptureService` enqueues the final chunk as a `PendingUpload` with `isFinalChunk: true`.
4. All previously-rotated chunks were already enqueued as their rotations happened during recording.
5. The watcher waits for **all** chunk uploads (not just the final one) before firing the state PATCH and transitioning to `.completed`.

The watcher's `pendingIDs` set already supports tracking N uploads — no logic change there.

## 3. Server-side contract

### 3.1 Upload endpoint additions

`POST /api/captures/:capture_session_id/audio` carries new fields:

- `chunk_index: integer` (multipart form field). Required. 0-based.
- `is_final_chunk: boolean` (multipart form field). Optional, defaults to `false`. Set to `true` on the upload that completes the session.

The MIME / file body / existing fields are unchanged. The endpoint already returns a per-upload `app.uploads` row id today — same behavior.

### 3.2 `app.uploads` schema

Migration 021:

```sql
ALTER TABLE app.uploads
  ADD COLUMN IF NOT EXISTS chunk_index INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS is_final_chunk BOOLEAN DEFAULT FALSE;

CREATE UNIQUE INDEX IF NOT EXISTS uploads_session_chunk_unique
  ON app.uploads (capture_session_id, chunk_index)
  WHERE kind = 'audio';
```

The partial unique index enforces "one audio chunk per (session, index)" at write time. Useful guardrail for the iOS-side idempotency on retry: if iOS sends the same chunk twice, the second insert hits the unique constraint and the handler can no-op return the existing row.

The `default 0` on existing rows means historical (pre-chunking) captures look like "single-chunk capture, chunk 0, not final" — which is fine for playback because the concat-by-chunk_index query just produces them in order.

### 3.3 Session completion semantics

Today: iOS sends `PATCH /api/captures/:id/state` with `state: .completed` when the user taps Stop and all uploads have drained.

With chunking: same. The state PATCH still fires; it remains the canonical "user said done" signal. The `is_final_chunk = true` on the last chunk upload is a *hint* for your side — it lets you know "no more audio chunks are coming for this session" *without* waiting for the state PATCH. Useful for triggering any session-finalize logic earlier (e.g., kicking off silver/gold processing).

**Recovery edge case:** the app dies after the last chunk was rotated + queued but before the state PATCH fired. On relaunch, the recovery path enqueues the persisted state PATCH from `CaptureContextStore`; the server eventually gets it, eventually sees `state=completed`, and reconciles. The `is_final_chunk` hint accelerates this — your side can start finalizing silver/gold as soon as the chunk lands, then the late state PATCH is a no-op.

### 3.4 Server-side ordering guarantees

iOS uploads chunks in order (chunk 0 first, chunk 1 next, etc.) because the upload coordinator is FIFO within a single capture session. However:

- Network jitter could cause chunk 2's HTTP response to land before chunk 1's (if they're in flight concurrently — depends on the coordinator's parallelism, which today is 1).
- Retries cause out-of-order arrivals: if chunk 3 fails and chunks 4-5 succeed, chunk 3's retry could land last.

The upload coordinator's `pickNextEligible` is single-threaded today, so concurrent in-flight is not an issue right now — but I don't want to bake the assumption in. The contract should be: **the server accepts chunk uploads in any order**. Order is reconstructed at query time via `ORDER BY chunk_index`.

### 3.5 Playback concat

For the App's `AudioPlayer` to render a chunked capture, we need either:

**Option A — Server-side concat at viewing time.** A new endpoint or modified existing one streams the chunks back-to-back, server-side concatenating M4A files.

```
GET /api/captures/:capture_session_id/audio/stream
  → Content-Type: audio/mp4
  → body: chunk 0 + chunk 1 + ... concatenated
```

ffmpeg's `concat` demuxer can do this efficiently; alternately if all chunks have matching codec parameters, you can just stream-copy the AAC frames.

**Option B — Client-side serial loading.** The AudioPlayer in the React app loads chunks in order, fires `onEnded` on chunk N to switch to chunk N+1. Less server-side work but more complex client state, gaps possible between chunks during the switch.

I'd prefer **A** if you can spare the server-side concat work — cleaner client UX, no gap. The endpoint can be lazy (concat on-the-fly each request) since chunks are small and ffmpeg's concat demuxer is fast. Or it can pre-materialize one big M4A in UC Volume on first request and cache.

**Question for you:** how do you want to handle this on your side?

### 3.6 Transcript anchoring

Transcripts already carry absolute timestamps relative to `started_at`. The transcript viewer's "click-to-seek" already works by absolute time. With chunked audio + server-side concat, no transcript change is needed — the concat-stream's `currentTime` is the absolute session time, transcripts seek to absolute offsets, and Just Works.

If you go with client-side serial loading (Option B), the AudioPlayer needs to translate "seek to absolute time T" into "load chunk floor(T / chunk_duration), seek to T mod chunk_duration." More work, but doable.

## 4. Backward compatibility

A 1-chunk capture (recording shorter than the rotation interval, or pre-chunking historical data) works identically to today:

- `chunk_index = 0`, `is_final_chunk = true`, exactly one upload.
- Server-side concat reduces to "stream the one file." No special case needed.
- AudioPlayer behavior identical.

Historical pre-migration data sees `chunk_index = 0` by default. The `is_final_chunk = false` default for them is technically wrong but harmless — the server won't be looking for further chunks on a session whose state is already `completed`.

## 5. CAF fallback meets chunking

The CAF fallback from PR A piece 1 applies **per chunk**. Per-chunk transcode failure → that one chunk uploads as CAF; the other chunks stay M4A. Your server-side handler already preserves both formats independently via `original_volume_path`. Mixed-format playback:

- Server-side concat (Option A): needs to handle the case where some chunks are M4A and others CAF. ffmpeg's concat demuxer requires matching codecs, so you'd need to transcode the CAF chunks to M4A on-the-fly during concat. That's fine — small chunks, fast transcode.
- Client-side serial (Option B): the AudioPlayer might not play CAF chunks. Download-link fallback per chunk would be very awkward.

This is another point in favor of Option A.

## 6. Migration plan

I'd ship this in two stages:

**Stage 1 — `chunk_index` plumbed through, but actual chunking still set to "1 chunk per capture" via a config flag.**

- Migration 021 lands.
- iOS sends `chunk_index = 0, is_final_chunk = true` on every audio upload, regardless of duration.
- Behavior is identical to today.
- Server-side concat endpoint goes live, reading single-chunk data.
- This verifies the data path end-to-end without changing recording semantics.

**Stage 2 — Enable real chunking.**

- iOS rotation logic ships behind a feature flag (`chunkedRecordingEnabled`).
- Default-off initially; we device-test multiple captures with it on.
- Once stable, default-on. Old recordings already saved continue to play (they're 1-chunk).
- Cold-start recovery for orphaned chunks ships at the same time.

This lets us de-risk the data path before introducing recording-mechanic changes.

## 7. Open questions for you

1. **`chunk_index` + `is_final_chunk` data model** — does §3.1 / §3.2 match what you'd want? Alternative I considered: UUIDv7-sortable IDs (no explicit index, ordering comes for free from the ID). I prefer explicit `chunk_index` because it's queryable, debuggable, and doesn't rely on iOS getting clock-sourced IDs right. But happy to hear which you'd prefer to land on.

2. **Server-side concat endpoint** — §3.5 Option A. Are you up for building this? If yes, ETA estimate? I can wire iOS to use the new endpoint as soon as it exists; in the meantime the React AudioPlayer can do per-chunk loading as a stopgap so this isn't strictly blocking.

3. **Migration 021** — does the partial unique index on `(capture_session_id, chunk_index) WHERE kind = 'audio'` look right to you? Trying to enforce dedup on the iOS retry path.

4. **`is_final_chunk` as a hint vs. authoritative** — I'm treating the state PATCH as authoritative and `is_final_chunk` as advisory (early signal for silver/gold trigger). Does that match how you'd want it? Or do you want `is_final_chunk = true` to *automatically* PATCH state to `completed` server-side, eliminating the iOS state-PATCH altogether?

5. **Chunk size — sanity check on 5 minutes.** 5 min ≈ ~5 MB M4A ≈ ~50 MB CAF ≈ ~20s ffmpeg. Smaller chunks (1-2 min) give better durability but more uploads + more transcode overhead. Larger chunks (10 min) reduce overhead but blow past the synchronous-transcode budget on CAF fallback. Comfortable with 5?

6. **Silver/gold pipeline implications.** Does your CDF-driven SDP pipeline need to know about chunk_index, or is it sufficient to read the `app.uploads` rows in `ORDER BY chunk_index` when reassembling for analysis?

7. **Out-of-band capture-row creation race.** Today: iOS creates the capture row first, *then* uploads audio. With chunking, the first chunk still uploads after the create — but the upload coordinator's drain order isn't gated on "previous chunk succeeded." If chunk 2 happens to land before chunk 1 (network jitter, partial retry), is that fine on your side? §3.4 says "yes, any order is fine," but want explicit confirmation.

## 8. What I'm doing now

Diving into iOS implementation:

1. Today: AVAudioEngine rotation mechanics. Add the chunk-boundary tracker, the writer-holder lock, the actor-driven rotation logic. Single chunk only (no enqueue per chunk yet) — just verify the rotation produces N independent CAF files without audio gaps when device-tested.
2. Tomorrow / day-after: wire each chunk through the existing transcode + CAF-fallback path. Each chunk becomes its own `PendingUpload`. Don't add `chunk_index` field yet; tests are still single-chunk.
3. After your ack on §7.1 / §7.4: add `chunkIndex` + `isFinalChunk` fields to `PendingUpload`, multipart form field on the upload, migration 021 on your end.
4. After §7.2 ack: switch the React AudioPlayer over to the server-side concat endpoint if you've shipped it; otherwise do client-side serial loading as a stopgap.
5. Cold-start recovery sweep for orphaned chunks.
6. Device-test the full path: record offline for 20 minutes, force-quit at minute 17, relaunch on Wi-Fi, watch 3 complete chunks + 1 recovery chunk drain.

PR #77 may merge as "Phase 3 foundation" before this big lift lands. Or this layers on top. Matthew and I will decide based on how PR #77's separate verification looks.

---

No urgency on the §7 answers — I have several days of iOS-only work before any of them block me. Happy to discuss any of the dimensions if my reasoning seems off anywhere.

— Isaac
