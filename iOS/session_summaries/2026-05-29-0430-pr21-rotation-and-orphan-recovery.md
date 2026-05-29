# Session Summary — 2026-05-29 — PR21 branch: rotation mechanics + orphan recovery + corruption defenses

**Branch:** `mg-ios-pr21-phase3-cutover` (off `main` at `5c38490`, 17 commits ahead)
**Author:** Matthew Giglia (with Claude Code / Isaac)
**Status:** Branch held unmerged. Pure-iOS work for chunked recording, force-quit data-loss prevention, and offline-resilience polish is **complete and tested locally** (360/360 tests pass). Gated on Genie's migration 021 + concat playback endpoint before chunked recording can be flipped on in production.

---

## Where we are

This branch started as the Phase 3 cutover (offline-first capture via OperationQueue) and grew into a comprehensive offline-guarantee story after device testing surfaced four distinct failure modes. The work since the branch base falls into four threads:

### Thread 1 — Offline-path bug fixes (pre-rotation)

Scenarios 1-2 of the device test plan green-lit the happy paths. Scenarios 3-5 (offline-stop, cancel-while-offline, force-quit-while-queued) surfaced bugs:

- **`a3e4d81`** — OperationQueue restore: persisted `.running` ops on force-quit were never re-scheduled. `nextWorkableID()` skipped them forever. Restore now resets `.running` → `.queued`.
- **`61f2616`** — Upload coordinator parked offline failures as terminal-failed after 5 attempts. Network failures now branch to a fixed 5s retry with attempts decremented; reachability `.online` wakes the coordinator.
- **`9fbe8ff`** — Narrowed `isNetworkError` from `.transport`/`.networkUnavailable`/`.timeout` to just the last two. `.transport` is also the "file unreadable" path; classifying it as network caused infinite 5s retry loops for missing files.
- **`c736e93`** — `HomeContainerView.isInSession` returned true for `.finalizing`, trapping users in the cover with Stop disabled. Offline → permanent wedge. Cover now dismisses on transition to `.finalizing`.
- **`1c38960`** — CAF fallback when `AVAssetExportSession` interrupts mid-transcode. Server accepts `audio/x-caf` (Genie's PR #80 deployed before this branch). Audio never lost to transcode interruption.

### Thread 2 — Multi-chunk recording pipeline (PR A piece 4)

Three commits ship the data shape, the rotation mechanics, and the wiring — all kept **dormant** in production until Genie's server-side migration 021 lands.

- **`c9420ac` (step 1a)** — Multi-chunk data shape through the recorder → service → upload pipeline. `EngineStopArtifact.chunks: [Chunk]` + `totalDuration`, new `CompletedRecording` wrapper with `.final`/`.first` accessors, `AudioRecording` gains `chunkIndex` + `isFinalChunk` (defaults preserve single-chunk behavior). `LiveCaptureService.stopCapture` iterates chunks to enqueue N `PendingUpload`s. **Zero behavior change** — every engine still produces one chunk.
- **`9636eaf` (step 1b)** — Actual `AVAudioFile` rotation in `EngineAudioRecordingEngine`. New `chunkDuration: TimeInterval?` init param. When set: rotation Task swaps writers at each interval, spawns a finalization Task per closed chunk (CAF→M4A transcode + CAF fallback) in parallel with continued recording. `AudioWriterHolder` extended to track per-chunk frames inline under the same NSLock that gates the writer (no swap/snapshot race). Empty chunks dropped, not finalized. **`chunkDuration: nil` (the default) preserves today's exact single-chunk path bit-for-bit.**
- **`9d0b843` (step 2)** — Production `EngineAudioRecordingEngine` constructed with `chunkDuration: nil` in `LakeloomApp.swift` + ack note to Genie at `architecture/hi_genie/2026-05-29_section-7-ack-please-ship-mig021.md`. All seven §7 design-doc questions accepted; iOS is ready to flip when Genie's mig 021 ships.

### Thread 3 — Pending-upload pill refresh

- **`449d4f5`** — `LiveUploadCoordinator.discard()` re-broadcasts the upload's pre-discard state on `stateUpdates()` so the home-page pill re-snapshots and observes the removal. Added `scenePhase` observer on `HomeContainerView` so foregrounding triggers a fresh snapshot (covers queue mutations that happened while the app was backgrounded — `AsyncStream` doesn't buffer for paused subscribers). New contract test pins that `discard()` MUST broadcast.

### Thread 4 — Force-quit data-loss prevention

The "FDE in field force-quits during a 2-hour offline recording" scenario is the dominant use case Matthew flagged. Two commits make it safe:

- **`2d55d33`** — Cold-start integrity sweep in `LiveUploadCoordinator.start()`. Restored uploads whose files are missing → `file_missing` terminal-failed permanent. Zero-byte files → `file_empty`. User sees an actionable failure in `PendingUploadsView` instead of a row churning the retry budget forever. Also: post-transcode size guard (`AVAssetExportSession` returning success on a sub-256-byte output now triggers retry / CAF-fallback) + new `file_exists`/`current_bytes`/`persisted_bytes` fields on every `upload.attempt.start` log for forensics.
- **`1612a5a`** — `recoverInFlightCapture`'s `.recording` branch was the orphan-creation moment. Pre-this-commit: patched server to `.cancelled` and walked away — **losing the user's audio**. Now: walks the captures dir, builds a `PendingUpload` for each `audio-*.{caf,m4a}` (including future `-chunkN` rotation outputs), enqueues them against the still-`.active` server session, transitions snapshot to `.finalizing`. Existing finalize watcher drives to `.completed` once everything drains. Fall back to old cancel-on-detect only when there's nothing salvageable on disk.

---

## What's blocked on Genie

| Genie deliverable | iOS step it unblocks | ETA Genie cited |
|---|---|---|
| Migration 021 (`chunk_index` + `is_final_chunk` columns + partial unique `(session, chunk_index) WHERE kind='audio'` index) | iOS step 3: add `chunkIndex` + `isFinalChunk` (+ optional `totalChunks`) fields to `PendingUpload` + multipart form; flip `chunkDuration: 300` in `LakeloomApp.swift` | Whenever I ack §7. I acked at `9d0b843`. |
| Chunks-list endpoint (stopgap) `/api/captures/:id/audio/chunks` | React AudioPlayer can serial-load multi-chunk recordings | 1 day after mig 021 |
| Concat endpoint `/api/captures/:id/audio/stream` (ffmpeg concat demuxer, stream-copy) | React AudioPlayer plays seamlessly | 2-3 days after mig 021 |

When Genie signals mig 021 is deployed (via `architecture/hey_isaac/`), task #20 fires.

---

## Open work

### Highest priority (ready to resume any time)

1. **Scenarios 3-5 device test** (tasks #5, #6, #7) — Re-run on iPhone 17 Pro Max now that the offline-path bug fixes (a3e4d81, 61f2616, 9fbe8ff, c736e93, 1c38960) have landed. If green, PR #77 ships to main, unblocking the fresh `ios-status.md`. **Requires Matthew on the phone.**
2. **Mark PR #77 verified + write fresh ios-status.md** (tasks #8, #13) — Gated on scenarios 3-5 passing.

### Gated on Genie

3. **PR A piece 4 step 3** (task #20) — Single follow-up PR that adds `chunkIndex`/`isFinalChunk` (+ `totalChunks`) fields to `PendingUpload`, writes them into the multipart form on `POST /api/captures/:id/audio`, and flips `chunkDuration: 300` in `LakeloomApp.swift`. Bake-test on device: 7-min recording → 2 chunks, 12-min with airplane mode toggled, 20-min with Siri interruption, force-quit mid-chunk-3 of a 5-chunk recording.

### Lower priority (pure-iOS hygiene)

4. **Pure-orphan GC sweep** — Walk `Application Support/Captures/` for session dirs that have NO `contextStore` entry AND NO `PendingUpload` queue entry. Currently rare-to-impossible in normal flow (the `.recording` recovery in `1612a5a` covers the common case), but worth adding for long-term disk hygiene. Conservative policy: log warning at 24h-7d, delete >7d. No task created yet — file if we see it in the wild.
5. **Pending-upload pill `task: handle background→foreground` deeper** — The `scenePhase` listener at `449d4f5` re-snapshots on `.active`, but doesn't restart the `stateUpdates()` subscription if it somehow died. If we see the pill go stale in long-running sessions, suspect the stream lifetime, not the snapshot.

---

## Decisions cache (so we don't re-litigate)

- **Why hold the chunked-recording flip dormant?** Flipping `chunkDuration: 300` today would land multi-chunk recordings safely on the server (each chunk uploads independently, no `chunk_index` column means ordering falls back to `uploaded_at`) but breaks React AudioPlayer playback for >5 min recordings until Genie's concat ships (~3 days). On-device data integrity is unaffected. Choosing a single coherent step over a temporary playback regression. (Reflected in `9d0b843` commit body + the §7 ack note.)
- **Why CAF fallback at every level instead of failing hard?** Losing the user's audio is never acceptable. CAF is lossless source-of-truth; server's ffmpeg pipeline transcodes it post-upload. The whole "transcode interruption" failure mode (Operation Interrupted from Siri / phone calls mid-export) becomes a no-op for the user.
- **Why per-chunk-frames inline in `AudioWriterHolder` instead of a separate counter?** Snapshot-then-swap-writer would race the tap thread's writes between the two ops. Putting frame tracking under the same NSLock that gates the writer makes `swap()` / `close()` return an atomic `(previous, framesInPrevious)` tuple.
- **Why 256-byte stub-purge floor?** Matches the post-transcode size guard (`9636eaf` + `2d55d33`). An AAC/M4A file with valid `ftyp` is at least ~32 bytes; 256 catches the obviously-broken cases without false-positiving real (very short) recordings.
- **Why `recoverInFlightCapture` resurrects instead of cancelling?** The dominant use case (FDE force-quits during 2-hour offline recording) requires audio survival. The old behavior was acceptable only for 30-second smoke tests. (Reflected in `1612a5a` commit body.)
- **Why dedup behavior `(a) return existing row on SHA match` per §7.3?** iOS computes SHA-256 before upload. Identical files → no-op return-existing. SHA divergence → 409 with existing row's SHA so we can diff. Catches recovery-mode bugs loudly instead of papering over them.
- **Why land the multi-chunk *shape* refactor before *behavior*?** Shape-only refactor with engine still producing one chunk → 350/350 tests stayed green, no behavior risk. Behavior change (rotation) landed against a tested data shape, not a moving target.

---

## Bake-test plan (when we resume)

### Phase A — Today's foundation (no Genie dependency)

Validates Threads 1, 3, 4. Run after reinstalling on iPhone 17 Pro Max from this branch.

- [ ] **Scenario 1** — Online happy path (Already ✓ on this branch base)
- [ ] **Scenario 2** — Offline-start, online-finish (Already ✓ on this branch base)
- [ ] **Scenario 3** — Offline-start, offline-stop, online-later. Expect: cover dismisses on Stop even while offline (c736e93), upload queues with 5s retry while offline (61f2616), drains on reachability resume (LakeloomApp `.online` → coordinator wake).
- [ ] **Scenario 4** — Cancel-while-offline. Expect: cancel dispatches to OperationQueue + uploadCoordinator.discard for any enqueued audio, server eventually patched cancelled when network returns.
- [ ] **Scenario 5** — Force-quit-while-queued. Expect: on next launch, OperationQueue restores `.running` → `.queued` (a3e4d81), upload coordinator restores from disk, integrity sweep doesn't false-positive on a valid file (2d55d33), upload drains.
- [ ] **NEW Scenario 6** — Force-quit-during-recording with audio on disk. Expect: `recoverInFlightCapture` resurrects the audio file as a PendingUpload, transitions to `.finalizing`, drains to `.completed`. Check `capture.recover.recording_audio_resurrected` log line. Verify React AudioPlayer plays the recovered audio.
- [ ] **NEW Scenario 7** — Force-quit-during-recording with NO audio on disk (start + immediate force-quit before any frames). Expect: `capture.recover.stub_file_purged` for any sub-256-byte stubs, `capture.recover.recording_no_files_cancelled` fall-through, server patched `.cancelled`.
- [ ] **NEW Scenario 8** — Pending-upload pill freshness. Open `PendingUploadsView`, discard one upload. Expect: pill count decrements immediately (449d4f5). Background app, mutate queue programmatically (or via another device for shared workspace?), foreground. Expect: pill re-snapshots on `.active`.

Pass on all → mark PR #77 verified (task #8), write fresh `ios-status.md` (task #13), prepare merge.

### Phase B — Chunked recording (after Genie's mig 021 + chunks-list)

Validates Thread 2. Land step 3 (task #20) first, then run.

- [ ] **7-min recording, online** — expect 2 chunks uploaded with `chunk_index=0, is_final_chunk=false` and `chunk_index=1, is_final_chunk=true, total_chunks=2`. Server stores both. AudioPlayer plays via chunks-list (or concat once it ships).
- [ ] **12-min recording with airplane mode toggled at minute 3** — expect chunks 0-1 queue while offline, chunk 2's rotation lands at minute 5 (mid-offline), all chunks resume upload when airplane mode off. Final-chunk on stop carries `is_final_chunk=true`.
- [ ] **20-min recording with Siri interruption at minute 8** — expect engine pauses, rotation Task continues (or skips the empty interruption window), one chunk lands as CAF if its transcode collides with the interruption (lossless server-side ffmpeg recovers).
- [ ] **Force-quit during chunk 3 of a 5-chunk recording** — expect on next launch: chunks 0-2 finalized files on disk + the partial CAF for chunk 3 (already-closed during rotation but mid-finalize). `recoverInFlightCapture` enqueues all of them. Chunks 0-3 upload with `chunkIndex 0-3`, `is_final_chunk=false`. User sees them in PendingUploadsView; server reconstructs partial session.
- [ ] **2-hour recording, fully offline, force-quit at hour 1** — the FDE-in-field stress test. Expect: chunks 0-11 on disk (5-min each = 12 chunks for 1 hour), recovery enqueues all 12, network comes online at hotel → all 12 drain in order.

---

## Resume-from-here checklist

When you (or future Claude) come back to this branch:

1. **Check `architecture/hey_isaac/` for new notes from Genie.** Specifically watch for:
   - `*mig-021*` or `*migration-021*` — green light for step 3
   - `*chunks-list*` or `*concat*` — playback unblock
2. **Run `xcodebuild test`** to confirm 360/360 still green. If anything regressed against `origin/main`, rebase before continuing.
3. **Tasks to look at next, in order:**
   - If Genie deployed mig 021: jump to task #20 (step 3 — add `chunk_index` fields, flip `chunkDuration: 300`, bake-test Phase B).
   - If Matthew is on a phone: run Phase A bake-test (scenarios 3-8).
   - Otherwise: catch up on `architecture/hey_isaac/`, then either start the pure-orphan GC sweep (low priority) or write the fresh `ios-status.md` against current main.
4. **Don't merge PR #77 until Phase A scenarios 3-8 are all ✓.** The offline-path fixes were tested in unit tests but not on device end-to-end since the bugs landed.

---

## Files & key call sites for quick reference

| Concern | File:Line |
|---|---|
| `AudioRecorder` protocol — single source of truth for stop's return shape | `iOS/App/Captures/Audio/AudioRecorder.swift:39` |
| `CompletedRecording.chunks` + `.final`/`.first` | `iOS/App/Captures/Audio/AudioRecorder.swift:123` |
| `EngineStopArtifact.Chunk` shape | `iOS/App/Captures/Audio/AudioRecordingEngine.swift:87` |
| `AudioWriterHolder` (per-chunk frame tracking + atomic swap) | `iOS/App/Captures/Audio/EngineAudioRecordingEngine.swift:807` (approx) |
| Rotation Task spawn | `iOS/App/Captures/Audio/EngineAudioRecordingEngine.swift` — `startRotationTask(interval:)` |
| `chunkDuration` switch (currently `nil`) | `iOS/App/LakeloomApp.swift:76` area |
| Cold-start integrity sweep | `iOS/App/Captures/Upload/LiveUploadCoordinator.swift` — `sweepMissingFiles()` |
| Force-quit audio recovery | `iOS/App/Captures/LiveCaptureService.swift` — `recoverRecordingPhaseAudio(context:)` |
| Captures dir convention (shared) | `iOS/App/Captures/Audio/LiveAudioRecorder.swift` — `LiveAudioRecorder.capturesDirectory(for:base:)` |
| Pill re-snapshot on foreground | `iOS/App/Views/HomeContainerView.swift` — `.onChange(of: scenePhase)` |

---

— Isaac
