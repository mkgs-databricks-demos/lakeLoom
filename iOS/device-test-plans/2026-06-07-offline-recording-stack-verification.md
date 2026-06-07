# Device Verification — offline recording stack (PRs #77 → #81 → #82)

**Build:** `mg-ios-offline-create-op-recovery` (#82 tip — contains all of #77 + #81 + #82)
**Device:** physical iPhone (17 Pro Max), paired to **`lakeloom-ai-dev`**
**Goal:** close the on-device gap before merging the stack. Unit tests are green (392/392); these are the paths unit tests can't reach (force-quit, airplane-mode, scene-phase, real upload drain).

## Why these scenarios
- **#77's original merge gate** was Phase A device scenarios 3–8. Scenarios **3, 5, 6** were effectively exercised by the 2026-06-02 customer field session (offline stop → drain; force-quit-during-recording → audio recovered). The clean gaps are **4, 7, 8**.
- **Scenario 9** is the new high-value one: the multi-offline-session **orphan-recovery regression** — the exact failure that stranded the customer's morning audio, which #82 is meant to fix. Don't merge the stack without confirming this on-device.

## How to capture logs
Attach the device and open **Console.app** (or `log stream --device --predicate 'process == "LakeloomApp"'`). Filter on the signposts called out per scenario. The OSLog categories in play: `capture`, `ingest`, `auth`.

---

## Scenario 4 — Cancel while offline
**Setup:** Airplane mode **ON**. Start a recording; let it run ~30s.
**Steps:**
1. Tap **Cancel** on the capture.
2. Confirm the UI returns to idle immediately (no spinner wedge).
3. Turn Airplane mode **OFF**.

**Expect:**
- Cancel dispatches without waiting on network; any enqueued audio for the session is discarded.
- The queued control-plane ops drain on reconnect and the server session ends up **`cancelled`** (or was never created if cancel beat the create — either is correct; what matters is no lingering `.active`).
- **No** audio left retrying, **no** orphaned `.active` session on the Databricks side.

**Logs to confirm:** `capture.cancel…`, upload discard for the session, `operation.attempt.ok` for the state PATCH, eventually a `cancelled` session server-side.

- [ ] **PASS** — idle immediately, server session `cancelled`/absent, no stranded audio.

---

## Scenario 7 — Force-quit during recording, NO audio on disk
**Setup:** Either network state.
**Steps:**
1. Start a recording and **force-quit within ~1s** (swipe up), before any audio frames are written.
2. Relaunch the app.

**Expect (foreground recovery path — unchanged by #82):**
- Recovery finds a `.recording` context whose on-disk file is a sub-256-byte stub (or absent).
- The stub is purged and the session is cancelled — no phantom upload, clean idle on launch.

**Logs to confirm:** `capture.recover.start phase=recording` → `capture.recover.stub_file_purged` and/or `capture.recover.recording_no_files_cancelled`.

- [ ] **PASS** — no stuck `.active` session, no phantom upload row, app lands idle.

---

## Scenario 8 — Pending-upload pill freshness
**Setup:** Get ≥2 uploads into a pending/failed state (record offline so audio queues, or use a known-failing upload).
**Steps:**
1. Open **PendingUploadsView**; **discard** one upload.
2. Confirm the home-screen pill count **decrements immediately**.
3. **Background** the app; while backgrounded, mutate the queue (let an upload drain, or discard another via a second device/path).
4. **Foreground** the app.

**Expect:**
- Pill re-snapshots on `discard()` (immediate decrement) and again on foreground (`scenePhase == .active`) — never shows a stale count.

**Logs to confirm:** discard broadcast on `stateUpdates()`; `HomeContainerView` re-snapshot on `.active`.

- [ ] **PASS** — pill always matches the true queue count, including after backgrounding.

---

## Scenario 9 — Orphan recovery: the June-2 regression  ⭐ (recommended — the reason the stack exists)
**Setup:** Airplane mode **ON** for the entire capture phase (fully offline).
**Steps:**
1. Record **session #1** (~6–7 min so it rotates into ~2 chunks); stop. *(offline → uploads + create op queue)*
2. Record **session #2** (~6–7 min); stop. *(two distinct capture sessions, both offline)*
3. **Force-quit** the app (simulates the field conditions).
4. Relaunch, then reconnect. To stress the create path like the real reconnect, toggle network **off→on→off→on** a couple times as it comes back.

**Expect (the #82 fix working):**
- Both sessions' `createCaptureSession` ops land — and if one parks on the flaky reconnect, it's **revived** (cold-start reconcile and/or the on-404 hook).
- **All chunks from BOTH sessions upload** (contiguous `chunk_index`, exactly one `is_final_chunk` per session) and appear **playable** in the Databricks app.
- Both sessions reach **`completed`**: the most-recent in the foreground, the older via background completion (this launch) or on a subsequent launch.
- **No session stuck with audio looping `404 UPLOAD_CAPTURE_NOT_FOUND`** — that's the June-2 bug; its absence is the pass condition.

**Logs to confirm:**
- `operation.create.revived` — a parked create was resurrected (if the reconnect provoked a park).
- `capture.recover.older_completed` or `capture.recover.older_deferred` — the older session handled correctly.
- `upload.attempt.ok` for every chunk; **no** sustained `UPLOAD_CAPTURE_NOT_FOUND` retry loop.
- (If a SHA collision ever fires: `upload.dedup.sha_mismatch` at error level — should NOT appear in a clean run.)

- [ ] **PASS** — both recordings fully uploaded + playable; both sessions `completed`; zero stranded audio.

---

## Sign-off
When 4, 7, 8, and 9 all pass, the stack (#77 + #81 + #82) is device-verified end-to-end and clear to merge bottom-up: **#77 → #81 → #82**.

| Scenario | Result | Notes |
|---|---|---|
| 4 — cancel while offline | ☐ | |
| 7 — force-quit, no audio | ☐ | |
| 8 — pill freshness | ☐ | |
| 9 — orphan recovery (June-2 regression) | ☐ | |

— Checklist authored by Isaac
