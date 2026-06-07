# Session Summary — 2026-06-07 — Offline create-op orphan recovery (June-2 field bug)

**Branch:** `mg-ios-offline-create-op-recovery` (off `mg-ios-pr-a-step3-chunk-fields`, 4 commits)
**Author:** Matthew Giglia (with Claude Code / Isaac)
**Status:** Complete, pushed, **392/392 tests green.** Fix for the bug surfaced by the first real customer field session.

---

## Context — the field session that started this

On **2026-06-02**, lakeLoom was used live with a customer: a fully-offline session with **two recordings, each >1hr**, plus screen captures. This was the first real-world exercise of the chunked-recording + offline-durability work (the `chunkDuration: 300` flip from the step-3 branch).

**The durability design held: zero audio lost.** Every chunk survived on disk through the offline window. But on reconnect the next morning, the **morning recording's audio would not upload** — `404 UPLOAD_CAPTURE_NOT_FOUND` for capture session `019e8881-…`, in an endless retry loop. The afternoon recording's audio + screenshots landed fine on the active session `019e89b4-…`.

### Root cause (confirmed, not theorized)

Genie confirmed **no dev Lakebase wipe**, so session `019e8881` was simply **never created server-side**. The chain:

1. Each recording mints its own capture session and enqueues a `createCaptureSession` op (`startCapture`, production always takes the queued path).
2. On the flaky June-3 reconnect, the **morning** create op (oldest in the FIFO queue) failed in a way the executor classified **permanent** — `OperationExecutor.throwClassifiedCapture` parked `authFailed` / `decodeFailed` / `unexpectedResponse` / create-`notFound` on attempt 1.
3. `LiveOperationQueue.nextWorkableID` **skips permanent ops forever** — nothing ever retried the morning create.
4. Meanwhile the morning **audio uploads treat 404 as transient** (`LiveUploadCoordinator.isPermanent`) and retried indefinitely against a session that would never exist.
5. The afternoon create, tried later once the connection stabilized, succeeded — hence afternoon-fine / morning-stranded.

**Customer data recovered:** Genie reconstructed session `019e8881` server-side (exact ID, active, mirroring the afternoon session); the morning audio then drained. Both recordings up, zero loss.

---

## The fix (this branch) — break the deadlock from both ends

### Part 1 — create-op resilience + revival primitive (`65460ca`)
- **`OperationExecutor`**: a `createCaptureSession` gates an entire recording's audio, so it now parks **only on a definitive client error** (`validationFailed` / `forbidden` / `auth`). The ambiguous failures that stranded the morning session — `notFound` (the project's own create may still be draining), `decodeFailed`, `unexpectedResponse` — are now **transient/revivable**. PATCH classification unchanged. *(Watch the per-pattern `where` on the create-only decode/unexpected case — a single trailing `where` binds only to the last pattern.)*
- **`OperationQueueing.reviveCreate(forCaptureSessionID:)`**: resets a parked/backing-off create op to `.queued` with a fresh budget. Matches the create variant specifically (a same-session PATCH is left alone). Added `captureSessionID` / `isCaptureSessionCreate` accessors to `PendingOperation.Variant`.

### Part 2 — reconcile the two queues
- **2b cold-start (`0ed88c3`)**: `OrphanedCaptureRecovery.reconcile`, run from bootstrap after **both** queues rehydrate, walks pending uploads and revives the create op for any capture session with non-terminal capture-routed uploads (audio/screenshot/photo; documents excluded). This is what would have auto-healed June-2 on the next launch — no manual server reconstruction.
- **2c live-404 (`d94d994`)**: `LiveUploadCoordinator` gained an `onCaptureNotFound` hook; a 404 on a capture-routed upload asks the queue to `reviveCreate` that session — so a stalled create is re-driven **mid-session**, not only on cold start. Wiring: `LakeloomApp` now builds the operation queue **before** the upload coordinator so the hook can call into it.

### Part 3 — multi-slot context store (`627df3b`)
- `CaptureContextStore` held a single `active-capture.json`, so a second recording overwrote the first's snapshot — which is why the morning session could never be driven to `.completed` even once its audio landed. Store now holds an **array keyed by `captureSessionID`** (transparent legacy-file migration; session-scoped `clear(captureSessionID:)`; all 11 clear sites updated).
- **Recovery** recovers the most-recent session in the **foreground exactly as before** (drives `current` + the live watcher — that tested path is untouched), and completes **older** sessions in the background: PATCH completed + clear if drained, else defer to a later launch. An older `.recording` snapshot (rare under a single recorder) has its audio resurrected + re-persisted as `.finalizing` so it's never lost/double-enqueued.

---

## Decisions cache (so we don't re-litigate)

- **Why both executor-softening AND revival?** Belt-and-suspenders: the create no longer parks on a flaky reconnect in the first place (Part 1), and if it ever does, both cold-start and an in-session 404 resurrect it (Part 2). Robust regardless of which error fired.
- **Why not rework the single-watcher lifecycle for Part 3?** Spawning a second concurrent live recovery watcher would require turning the single `watcherTask` into a keyed collection + guarding every terminal `current` transition — a delicate rewrite of the heavily-tested recovery/finalize state machine. Given Parts 1+2 already guarantee the audio *lands*, Part 3's remaining value is state-hygiene (older session marked completed vs lingering active). The background "complete-if-drained, else defer to next launch" delivers that with **zero change to the foreground path**. Documented limitation: an older session still uploading at recovery completes on a subsequent launch, not concurrently.
- **Why exclude documents from reconcile?** They route under `/api/projects/:id/documents`, not a capture — they never block on a capture create.
- **Why keep `auth` permanent in the executor?** It genuinely needs a re-pair; but revival (cold-start + 404) re-drives it after the user re-pairs, so dependent audio still lands.

## What we could NOT get (and why it didn't block)

- **Device OperationQueue dump** — would have named the exact `lastError` that parked the morning create (`auth:` vs `decode` vs project-`404`). Couldn't retrieve it. The fix is robust across all of them, so it wasn't needed; the executor matrix test covers every classification.

---

## Open items / follow-ups

1. **Verify on device** once the next field/bench session happens: two offline recordings → force-quit/reconnect → both sessions land **and** both reach `.completed` (the Part 3 hygiene win). Watch for `operation.create.revived` and `capture.recover.older_*` log lines.
2. **Possible future hardening** (not done, low priority): a live background watcher for older in-flight sessions so they complete concurrently rather than on a later launch. Only worth it if the deferred-completion is observed to matter.
3. **Server `is_final_chunk` optimistic completion** (Genie §7.4) partially overlaps Part 3's completion PATCH — confirm they don't fight (they shouldn't; state PATCH is authoritative).

---

## Files & key call sites

| Concern | File |
|---|---|
| Create-op failure classification | `iOS/App/Common/Operations/OperationExecutor.swift` — `throwClassifiedCapture(error:kind:)` |
| Revival primitive | `iOS/App/Common/Operations/OperationQueue.swift` — `reviveCreate(forCaptureSessionID:)` |
| Cold-start reconcile | `iOS/App/Captures/OrphanedCaptureRecovery.swift` |
| Live-404 hook wiring | `iOS/App/LakeloomApp.swift` (queue-before-coordinator) + `LiveUploadCoordinator` `onCaptureNotFound` |
| Multi-slot store | `iOS/App/Captures/CaptureContextStore.swift` |
| Multi-session recovery | `iOS/App/Captures/LiveCaptureService.swift` — `recoverInFlightCapture` / `recoverForeground` / `recoverOlderSession` |

— Isaac
