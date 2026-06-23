# Session Summary — 2026-06-23 — Offline finalize-wedge + offline project create (June-onsite field bug)

**Branch:** `mg-ios-offline-multisession-project-create` (off `mg-ios-offline-create-op-recovery` / #82 tip `da92567`)
**Author:** Matthew Giglia (with Claude Code / Isaac)
**Status:** **Bug B implemented + tested green. Bug A scaffolded behind a gate + tested green.** Full iOS suite passes ("Test Succeeded", 0 failures) on the iPhone 17 Pro sim (iOS 26.3). Branch strategy: **new feature branch continuing the stack** (see below). Not yet committed (awaiting go-ahead) and not yet device-verified.

> **Env note:** the suite was initially un-runnable here — the active Xcode SDK needed an iOS 26.5 simulator runtime that wasn't installed (only 26.3 was), so xcodebuild had no eligible simulator destination. After installing the iOS 26.5 platform the sims became eligible and the suite ran green on the iOS 26.3 sim. Pin the destination by UDID (`id=…`) — `name=iPhone 17 Pro` is ambiguous (three exist) and `OS=26.3` doesn't match the `26.3.1` runtime string.

---

## Context — the second customer field session

Onsite with a customer, the iPhone was **fully offline from the Databricks App the entire meeting** — not airplane mode this time, but the **workspace IP allow-list blocked the device's IP**, so every call to the App failed. Two distinct failures surfaced, both new relative to the #82 work (which fixed *audio durability/orphan recovery*, not the *live state machine*):

### Failure A — could not create a project offline
The customer engagement needed a fresh project on a whim. Offline, **project creation is impossible** — the user had to fall back to an existing project. Not a regression; the offline path was simply never built.

### Failure B — could not start a second session, could not continue the first (the wedge) ⭐
1. Started session #1 offline; it ran **>1 hour**.
2. At lunch, **stopped** session #1.
3. After lunch, tried to **start session #2** → on-screen error *"A capture is already in progress."*
4. Also could **not continue session #1** — once stopped, there is no resume.

The device was wedged out of its own core function for the rest of the day. Only getting back online (so the uploads drain) would have freed it — and even a force-quit/relaunch would **not** have helped (see root cause).

**Desired outcome (the principle):** everything works on iOS even when completely offline. Projects, sessions, captures all succeed locally and reconcile to the App later — whether via reconnect, a fresh pairing, or the apps coming back online. Offline is a first-class mode, not a degraded one.

---

## Root cause — Failure B (the wedge)

The live capture state machine treats *"a past recording's uploads haven't flushed yet"* as *"busy recording,"* and offline those uploads can never flush. Confirmed chain (all `iOS/App/Captures/LiveCaptureService.swift`):

1. `stopCapture()` enqueues each audio chunk as a `PendingUpload`, then snapshots the still-non-terminal uploads for the session (`:993`–`:999`). **Offline, none can drain**, so `pendingIDs` is non-empty.
2. It transitions `current → .finalizing(context, pendingUploadIDs:)` and spawns a watcher (`:1032`–`:1034`).
3. `watchUploads` only reaches the completion branch when **every** pending upload hits `.succeeded` (`pending.isEmpty` at `:1582`). There is **no offline bail and no timeout** — offline, `current` sits in `.finalizing` for the whole offline window.
4. Starting session #2 calls `ensureCanStart()`, which throws `alreadyCapturing` for **both `.recording` and `.finalizing`** (`:1315`–`:1316`) → the on-screen *"A capture is already in progress."*
5. No resume API: `stopCapture` requires `.recording` (`:846`), and after stop the recorder is torn down.

**Why force-quit wouldn't help:** cold-start recovery (`recoverForeground`, `:310`) re-enters `.finalizing` for the most-recent session and **reattaches the watcher** (`:358`, `:402`–`:406`). So `ensureCanStart` would still throw on relaunch. The only offline-day escape was reconnecting.

**Why this is the real root:** `current` is a **single in-memory slot** gating all new captures, and it conflates two orthogonal facts — *"the mic is actively recording"* (at most one, a real hardware constraint) vs. *"a finished recording's uploads are still draining"* (can be many, fully background). Only the first should block a new recording. This is exactly the single-watcher lifecycle rework that #82's Part 3 **explicitly deferred** as "a delicate rewrite" — it's now load-bearing.

## Root cause — Failure A (offline project create)

- `ProjectService.create(...)` (`iOS/App/Projects/ProjectService.swift:168`) is a **direct online** call to `api.create`. Offline it throws (network-unavailable mapped through `ProjectErrorMapper`). No queue, no local mint.
- The `OperationQueue` already **reserves** `createProject` / `updateProject` variants (`PendingOperation.swift:114`, comment: *"Phase 2 lets the user create projects offline"*), but the executor **parks them as permanent**: *"variant not wired in Phase 3"* (`OperationExecutor.swift:84`–`:100`).
- So the plumbing was anticipated but never connected — Phase 3 only wired capture ops.

**The contract crux (why this needs Genie):** an offline capture session is enqueued against a `projectID` FK (`startCapture` `:732`). If we mint a **local** project UUID offline and the server later assigns a **different** id, every capture created against the local id is orphaned. We need the project create to be **Option A** — `client_generated_id` *becomes* the project row id — exactly like captures (migration 018). The capture precedent already proves the pattern; the `createProject` payload already sends `client_generated_id` (`CreateProjectPayload.swift`), but it's currently only idempotency, not necessarily row-id authority. This is the question going to Genie in the paired `hi_genie` note.

---

## Branch strategy — decided

**New feature branch off the current #82 tip, both fixes here, verify the whole stack as a unit, merge bottom-up #77 → #81 → #82 → #83.** Rationale:

- Both fixes live in code the stack introduced (`LiveCaptureService` finalize/recovery for B; #77's reserved `createProject` variant for A) — branching off `main` and rebasing later would be pure pain.
- **#82 cannot pass its own merge gate offline.** The existing device checklist's **Scenario 9** starts session #2 *in the same run, before the force-quit* — run offline, that step hits this exact wedge and throws `alreadyCapturing`. So Bug B isn't a feature bolted on top of #82; it's the missing piece that makes #82's offline multi-session story actually true. Merging the stack "as-is" would ship a claimed-but-broken capability.
- Keeping #82 intact (rather than reopening it) preserves the already-pushed review history; the wedge fix rides in #83 and the stack is device-verified together.

---

## Plan of record (this session's deliverables, in order)

1. **This session summary.** ✅
2. **`hi_genie` note** — `architecture/hi_genie/2026-06-23_offline-project-create-and-multisession-finalize.md`. Asks Genie to confirm/ship Option-A semantics for `POST /api/v1/projects` (client_generated_id == project row id), confirm the project→capture FIFO drain ordering holds (create project → create captures → uploads), and confirm the existing capture-`notFound`-is-transient softening covers the project-still-draining dependency.
3. **Implementation plan** (EnterPlanMode) for both bugs — see below for shape.

## What landed (this session)

### Bug B — finalize de-wedge (shipped, tested)
Chose the proper **keyed-finalizers** approach over the interim. `LiveCaptureService`:
- New `backgroundFinalizers: [String: Task]` keyed by `captureSessionID`.
- `ensureCanStart()` now **demotes** a `.finalizing` session (cancel its foreground watcher, `current → .idle`, spawn a background finalizer) instead of throwing `alreadyCapturing`. Only a genuine `.recording` blocks a new start.
- `watchUploadsInBackground` mirrors `watchUploads` minus every `current`-mutating side effect; subscribes its own stream, reconciles the inherited pending set against the queue (handles uploads auto-retired during handoff), and on drain calls `completeBackgroundFinalizer` (PATCH `.completed` + clear snapshot + drop from the map).
- The `.finalizing` snapshot stays on disk during the background drain, so a force-quit mid-drain is still recovered by #82's older-session path. The UI-facing `CaptureServiceState` enum and #82's recovery code are untouched — purely additive.
- Tests (`LiveCaptureServiceTests`): `startWhileFinalizingDemotesAndStarts` (the exact onsite repro) + `demotedSessionCompletesInBackground`. The existing `cannotStartWhileRecording` (start blocked while genuinely `.recording`) still passes.

### Bug A — offline project create (scaffolded behind a gate, tested)
Wired end-to-end but **gated OFF** (`ProjectService.offlineCreateEnabled`, default `false`) until Genie confirms Option-A:
- `OperationExecutor` `.createProject` case → `projects.submitQueuedCreate(...)`, classified by a new `throwClassifiedProject` (same create-bias as captures: only definitive client errors park). `.updateProject` still parked.
- `ProjectService`: `submitQueuedCreate` (POSTs with the local id as `client_generated_id`, raw `ProjectAPIError` for the executor to classify, upserts the canonical row on success); `createOffline` (mint local UUIDv7 → local `ProjectMetadata` upserted into cache/picker → enqueue `.createProject` → return immediately); `create()` routes to `createOffline` only when `offlineCreateEnabled && operationQueue != nil`. Queue late-attached via `attachOperationQueue` (avoids the queue↔executor↔projects construction cycle).
- Tests (`OperationExecutorTests`): 7 `createProject` classification cases (success-routes-to-submit + transient/permanent matrix). `StubProjectServicing` gained a scriptable `submitQueuedCreate`.

**Why gated:** with the gate on, `create()` returns a locally-minted id the caller starts captures against — correct only if the server adopts `client_generated_id` as the project row id (Option A). Flip the default to `true` the moment Genie confirms (see the `hi_genie` note). Production behaviour is unchanged until then (online create path).

## Test result
Full suite **"Test Succeeded", 0 failures** on iPhone 17 Pro sim (iOS 26.3). The 9 new tests confirmed executed + green.

---

## Files & key call sites (evidence)

| Concern | File:line |
|---|---|
| Finalize wedge — single-slot `current`, no offline bail | `iOS/App/Captures/LiveCaptureService.swift:993`, `:1032`, `:1582` |
| `ensureCanStart` rejects `.finalizing` | `iOS/App/Captures/LiveCaptureService.swift:1315` |
| No resume — `stopCapture` requires `.recording` | `iOS/App/Captures/LiveCaptureService.swift:846` |
| Cold-start re-enters `.finalizing` + reattaches watcher | `iOS/App/Captures/LiveCaptureService.swift:310`, `:402` |
| Project create is online-only | `iOS/App/Projects/ProjectService.swift:168` |
| Offline-serving project list (cache + disk) | `iOS/App/Projects/ProjectService.swift:80` |
| Reserved-but-unwired queue variants | `iOS/App/Common/Operations/PendingOperation.swift:114` |
| Executor parks createProject as permanent | `iOS/App/Common/Operations/OperationExecutor.swift:84` |
| Capture create FK on projectID (the dependency) | `iOS/App/Captures/LiveCaptureService.swift:732` |

— Isaac
