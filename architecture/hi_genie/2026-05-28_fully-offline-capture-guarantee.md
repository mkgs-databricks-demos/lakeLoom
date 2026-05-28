# Hi Genie — Fully-offline capture guarantee: design pass needed

**From:** Isaac (iOS)
**Date:** 2026-05-28
**Re:** Phase 3 cutover scope correction. Supersedes the "scenarios 3–5 are follow-up polish" framing implied by PR #77's test plan.
**Status:** Design proposal. Holding PR #77 unmerged until this lands. Looking for your input on the server-side contract questions in §6 before I start implementing.

---

## 1. The use case we actually need to support

Matthew clarified the on-site reality: an FDE will routinely be in a customer environment where **lakeLoom's IP isn't allowlisted** at the time of the engagement. The SA still needs to record the requirements-gathering session — audio + screenshots + documents — across what could be several hours. The actual upload happens later: back at the hotel that evening, or at the office the next day, when they're on a network that can reach the Databricks App.

This is not an edge case. It's a dominant workflow.

The contract iOS owes the FDE is:

> "If you record while offline, every byte you captured will be preserved on the device, and it will all land in Databricks the moment you next reach the App — without you having to do anything beyond reopening the app."

PR #77 was framed as a Phase 3 cutover. The scenarios 1–2 it verifies cover online + transient-offline-while-recording. **Scenarios 3–5 cover the actual use case above, and the current implementation does not deliver them.**

## 2. What we found today trying to verify scenario 3

Scenario 3 = record offline → tap Stop offline → flip airplane OFF later → expect drain.

What actually happened on-device:

1. **LiveCaptureView didn't dismiss on Stop while offline.** The user tapped Stop, the recording animation stayed, the UI re-presented "uploading 1 file..." with a spinner, and the elapsed-time counter kept incrementing (jumped from ~1 minute to 3:21 over the course of investigation). The user couldn't tell whether the session was still recording or just stuck.
2. **The operation queue went silent.** After Stop, no `operation.attempt.start` events appeared in OSLog. We expected the worker to be retrying the `.createCaptureSession` op against the offline network and failing periodically; instead the queue was producing no events at all. I don't have a confident root cause yet — possibilities include: Stop never reached `LiveCaptureService.stopCapture` cleanly, the worker task was cancelled by some other lifecycle event, or my `.running → .queued` recovery isn't covering whatever state the op ended up in.
3. **The audio file we got back from an earlier wedged session was unreadable** ("the file couldn't be opened because there is no such file" / "file unreadable" depending on which queue surfaced it). AVAudioRecorder's `.m4a` writer needs a proper `stop()` call to flush the moov atom; if the app dies mid-recording without that call, the file on disk is unrecoverable. For a 30-minute customer session, that's catastrophic. **Late-breaking update from a live session this afternoon:** even online happy path stop can fail with `engineFailure(reason: "transcode: Operation Interrupted")` — `AVAssetExportSession.export(to:as:)` throws `AVError.operationInterrupted` on stop, presumably from an AVAudioSession interruption mid-export. The intermediate `.caf` survives on disk (the delete is after the throw on `EngineAudioRecordingEngine.swift:227`), but the in-memory reference is nilled, so the app loses track of the recoverable audio. Three audio reliability failure modes in one day — strongly suggests the recording path needs hardening as a single workstream.
4. **No diagnostic surface for the user.** There's no "you have N items queued and they're safe" UI. The user has to trust the spinner. If the spinner looks frozen — which it did for us, for legitimate-but-confusing reasons — there's no way to confirm the data is preserved.

The fixes I shipped today onto PR #77 are real but bounded:

- `a3e4d81` — OperationQueue restores `.running` ops back to `.queued` on cold start (so a force-quit during a network call doesn't wedge the queue forever).
- `61f2616` — Upload coordinator doesn't burn its retry budget against `.networkUnavailable` / `.timeout` failures, and exposes `wake()` so reachability `.online` can nudge it.
- `9fbe8ff` — Narrowed the network-error classifier so file-missing `.transport` errors still park permanent (preventing a tight 5s retry loop for irrecoverable uploads).

Those are foundation pieces, not the design. I'd like to keep them on PR #77 and then either rebase the offline-guarantee work on top, or merge #77 first as the prerequisite for it.

## 3. Design dimensions iOS needs to nail

This is the iOS-side checklist I want to work through. I'd appreciate a sanity check on the boundaries, especially anything that touches the App-side contract.

### 3.1 Stop-while-offline UX semantics

- Stop must be **synchronous from the user's perspective**: tap → view dismisses → return to home/project view. No "wait for upload to start" gating.
- All persistence (audio file finalize, operation queue enqueue, upload queue enqueue) happens before dismissal. If any of those fail, surface a non-blocking error toast but still dismiss — the user already mentally moved on.
- The view's "still uploading" state should never be coupled to the LiveCaptureService lifetime. Once stop is initiated, the LiveCaptureView is done; pending uploads are visible elsewhere.

### 3.2 AVAudioRecorder lifecycle vs app lifecycle

The current implementation finalizes the .m4a only when `stopCapture()` is called explicitly, and even when it does, the CAF→M4A transcode via AVAssetExportSession can throw "Operation Interrupted" on stop (the third failure mode noted in §2). The user can also:

- Force-quit while recording (no `stopCapture` ever runs)
- Get backgrounded by an incoming call / Siri / etc. and never return
- Have iOS jetsam the process under memory pressure
- Drain the battery to zero

For each, the audio file should be **recoverable**. Options I'm weighing:

- **`scenePhase = .background` → finalize and re-enqueue.** Catches voluntary backgrounding. Doesn't catch force-quit or jetsam.
- **`UIApplicationWillTerminate`** — fires for some but not all termination paths.
- **Chunked recording**: split audio into N-second segments written as they roll, so a force-quit only loses the last chunk. More complex but the durability is much better.
- **Periodic moov-atom rewrites**: AVAudioRecorder supports incremental file writes; we could trigger periodic flushes. Investigating.

I'm leaning toward chunked recording (option 3) because it's the only one that survives jetsam mid-session. Open to other approaches if you've thought about this.

**Transcode failure handling** is a separate sub-piece in PR A: when `AVAssetExportSession` throws on stop, today we throw `engineFailure` and the in-memory CAF reference is nilled. We should instead: (a) retry the export 2-3 times with brief backoff (often interruption is transient), (b) on permanent transcode failure, surface the orphaned CAF to the upload queue as-is (or transcoded asynchronously in the background), (c) never silently lose the user's audio. We may also want to upload the raw CAF and let the server transcode if the on-device export fails — would be useful to know if your side can handle a CAF audio upload as a fallback, or if we should keep the transcode strictly on-device.

### 3.3 File integrity at enqueue time

When the upload coordinator picks up an audio file, it should validate the file is well-formed before attempting to upload — not throw `.transport("file unreadable")` 5 times against a corrupt file and then park permanent (current behavior, even after today's classifier narrowing). Specifically:

- On enqueue, check the .m4a has a valid moov atom. If not, attempt recovery (e.g., AVAssetExportSession with the partial file).
- If unrecoverable, mark the upload as `.failed(permanent: true, reason: "file corrupted at recording")` at enqueue time, not after 5 network retries.
- Surface this in the diagnostic outbox UI so the user knows that specific file is lost (vs. is queued for later).

### 3.4 Operation queue robustness under multi-hour offline

Today's `.running → .queued` recovery fix solves the simplest wedge. But the queue still has issues for the multi-hour case:

- **`maxTransientAttempts = 6`** with exponential backoff caps at `[2, 4, 8, 16, 32, 60]` seconds — that's ~2 minutes of cumulative offline retry before parking permanent. Five hours offline blows past that. Same fix as the upload coordinator: network failures shouldn't count toward the transient budget. I'd extract a common classifier and apply it to both queues.
- **No `wake()` integration on reachability for the operation queue's in-flight sleeps.** I wired `LakeloomApp.swift:233-243` to call `wake()` on `.online`, but the worker's `Task.sleep(interval)` inside the backoff isn't cancellable. Realistically the worker will pick up within the current sleep window (≤60s) so this is a UX polish issue, not a correctness one.
- **Persistence atomicity:** the operation queue and upload queue are separate JSON files. If we crash between persisting the operation enqueue and the upload enqueue, we have an inconsistent state. Need to think about whether they should share a transaction or whether the system tolerates the inconsistency.

### 3.5 Diagnostic outbox UI

This is the user-facing piece. The SA needs to look at the phone after a customer session and feel confident.

Proposed surface: an "Outbox" tab or sheet that lists every pending capture session with:

- Capture label / start time / duration
- Status: queued / draining / done / errored
- Byte count for the audio file
- Whether the create has landed, whether the state PATCH has landed, whether the audio has uploaded
- Per-item retry / discard buttons for failed-permanent items

This is iOS-side UI but the data model behind it is the join of (operation queue) + (upload queue) + (local capture context).

## 4. What's still missing on the audio path

A few things I want to call out that we hit today but haven't fully designed for:

- **The deleted audio from the earlier wedged session was 818kb when iOS showed it in the pending uploads UI**, but the file on disk was gone. So the persisted `PendingUpload` retained the `sizeBytes` but the `localFileURL` pointed at a deleted file. We should either (a) eagerly delete the queue entry when the file goes missing, or (b) hold a strong file-system reference (security-scoped bookmark? hard link?) that survives whatever process killed the file. Worth investigating which iOS subsystem is reaping these.
- **ZeroBus events streamed live during the offline session** (the user saw transcripts in the App for one of the wedged sessions, even though no `app.capture_sessions` row existed). This works because the App proxies ZeroBus via SPN, so events tagged with the iOS-generated capture session ID get written even when the row doesn't exist yet. **Is this a problem on your side?** It means there can be a window where transcript events exist with no parent capture row. If so, we may want to gate ZeroBus emission on the capture create having landed — but that defeats the "fire and forget" nature of ZeroBus in offline mode. Open question.

## 5. Proposed sequence of work

I'd like to break this into three focused PRs, each with its own device test plan:

1. **PR A — Audio file durability**: chunked recording or whatever solution we converge on, file integrity validation at enqueue, AVAudioSession + app lifecycle observers. Test: record while offline → force-quit mid-recording → reopen → audio file integrity preserved.
2. **PR B — Queue robustness for multi-hour offline**: extend the network-classification fix to OperationQueue, add a shared `NetworkErrorClassifier`, address the LiveCaptureView dismissal bug, surface the diagnostic outbox UI. Test: record offline → stop → close app → walk away for an hour → reopen on Wi-Fi → all queues drain in order, capture lands fully.
3. **PR C — Polish + outbox UX**: diagnostic outbox UI surfaces, per-item retry/discard, pending-pill staleness fix (currently tracked as a follow-up).

PR #77 stays as-is on its branch with today's fixes — once PR A merges, I'll rebase #77 onto main and merge it (the fixes are still useful even if not sufficient alone). Or we close #77 and re-PR the same commits as part of PR A. Slight preference for the rebase since the history is clean.

## 6. Questions for you

Things I'd appreciate your read on before I start implementing:

1. **Resumable uploads.** Right now `POST /api/captures/:id/audio` is single-shot multipart. For a 60-minute session that's potentially hundreds of MB shipped in one request — if it fails halfway over hotel Wi-Fi it starts from zero. Is there appetite for a chunked/resumable contract? I'm imagining something like `POST .../audio/init`, `POST .../audio/chunk?offset=N`, `POST .../audio/complete`, with the App side reassembling on UC Volume write. Not blocking on this — single-shot is fine for the first cut — but worth knowing if you've thought about it.

  **Related question** from §3.2 above: would you accept a raw CAF upload as a fallback when iOS-side transcode fails? If the App's audio path is `.m4a`-only on UC Volume that's fine, we keep the transcode strictly on-device with the retry/recovery story; but if the App could accept CAF and lazily transcode server-side, that would eliminate an entire class of audio-loss bugs on iOS.

2. **Pending-sessions surface in the Databricks App.** Today the App only knows about sessions that have an `app.capture_sessions` row. Pre-create-lands, the App sees nothing. Would a "pending" surface be useful — fed by ZeroBus events tagged with the iOS-generated capture session ID — so the App shows "FDE has 3 captures pending upload from the Acme onsite, ETA when they're back on Wi-Fi"? Or is that overkill and we just wait for the create to land?

3. **Server-side reconciliation when iOS finally drains.** If iOS drains hours later, the order is `.createCaptureSession` (HTTP 201 or 200) → potentially several `.updateCaptureSessionState(.label)` PATCHes → `.updateCaptureSessionState(.completed)` → audio multipart upload → screenshot/document uploads. Is your handler chain robust to this sequence arriving as a tight burst after a long silence? Anything I should make iOS pace, or do you want the burst?

4. **ZeroBus event ordering.** Per §4 above, ZeroBus events can land in `transcript_events_raw` before the parent `app.capture_sessions` row exists. Is that a problem on your CDF pipeline / bronze layer? If so, do you want iOS to buffer ZeroBus events locally until the capture create lands, or do you want to handle it server-side?

5. **Any blockers on your side** that should drive the order of iOS work? If the answer to (1) is "yes, we should do resumable uploads soon," I'd rather do PR A on top of that than have to rewrite the upload path twice.

## 7. What I'm doing right now

- Holding PR #77, no merge.
- Reading the AVAudioRecorder lifecycle behavior in detail to confirm option-3 (chunked recording) is feasible.
- Sketching PR A's scope so the chunked-recording change has a tight, testable cut.

Holler when you've had a chance to read this. No urgency on a same-day reply — I'll be heads-down on the AVAudioRecorder investigation while you read.
