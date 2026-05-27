# iOS Status & Pickup Notes

**Last updated:** 2026-05-27 (session pause-point)
**Branch on disk:** `mg-ios-pr21-phase3-cutover`
**Active blocker:** Genie's server-side `client_generated_id` handler fix (see "Active blockers" below)

This doc is the single point-in-time snapshot of where iOS work stands. Update it at the end of each session before stepping away. Module specs (`module-NN-*.md`) describe the durable architecture; this doc describes the *current* state of the world.

---

## Active blockers

### Server: `POST /api/projects/:id/captures` drops `client_generated_id`

Genie's 2026-05-25 reply (`hey_isaac/2026-05-25_client-generated-capture-id-implemented.md`) said the Phase 3 contract was deployed, but the handler at `lakeloom-ai/server/routes/captures/capture-routes.ts:77` only destructures `label / client_ts / device_id` from the request body — `client_generated_id` is silently dropped, and the INSERT doesn't reference the column. Migration 018 added the column; the handler change never landed.

**Symptom:** iOS Phase 3 cutover (PR #77) sanity check fails — every audio upload immediately after a successful create returns 404 (`No active capture session '<id>' was found`) because the row exists under the server-generated id, not the client-supplied one.

**Filed:** `architecture/hi_genie/2026-05-26_client-generated-id-not-honored-bug.md` (committed onto the PR #77 branch). Includes the exact diff location, full reproducing log, and a suggested fix shape (destructure + idempotency check + INSERT with the supplied id).

**Next step:** wait for Genie's deploy, then re-run the PR #77 device tests. Don't merge #77 until uploads succeed.

---

## Open PRs

| # | Title | Branch | State |
|---|---|---|---|
| 77 | iOS: Phase 3 cutover — offline-first record via OperationQueue | `mg-ios-pr21-phase3-cutover` | Open, **blocked on server fix above**. Code/tests/docs clean. 345/345 tests pass. |

---

## Recently merged (last ~24h, newest first)

| # | Summary | Merged at |
|---|---|---|
| 75 | Device re-pair from Account page (toolbar warning pill, `PairingStatus` value type, re-scan QR sheet) | 2026-05-27 02:00 UTC |
| 74 | Background audio + lock-screen Now Playing (UIBackgroundModes via Info.plist, interruption handling, pause icon transport) | 2026-05-27 02:00 UTC |
| 72 | Phase 2 scaffold — control-plane operation outbox (`PendingOperation`, `OperationQueueStore`, `LiveOperationQueue`); inert until #77 | 2026-05-26 19:47 UTC |
| 70 | Offline Phase 1 — project list persistence + reachability banner (+ fix on follow-up: `fetch()` now populates cache+disk on default-project resolution) | 2026-05-26 19:42 UTC |

---

## Known follow-ups (deferred polish, not blocking)

* **Branded artwork on lock-screen Now Playing widget.** `LakeloomMark` image set is already in `Assets.xcassets`. Both attempts to attach it via `MPMediaItemArtwork(boundsSize:requestHandler:)` crashed inside `MPNowPlayingInfoCenter/accessQueue` on iOS 18+ (raw 1024×1024 PNG; pre-rendered 256×256 with Sendable handler — same trap). The deprecated `MPMediaItemArtwork(image:)` would be the simplest path but the project's Swift settings treat deprecation as error. Skipped for now. Comment in `App/Captures/Audio/NowPlayingController.swift:start(...)` captures what was tried.
* **Diagnostic outbox UI for parked `OperationQueue` ops.** Phase 3 parks 4xx / auth-failure ops as `OperationPermanentFailure`; today there's no surface to retry / discard them. Tracked in Module 02 §25.5.
* **`PATCH /api/v1/captures/:id/label` queue-routing.** Today the label-edit affordance still calls `captureAPI.updateCaptureLabel` directly. Should route through `OperationQueue` like state PATCHes do post-Phase 3, for offline consistency. Small refactor.
* **`MPRemoteCommand` cleanup on app teardown.** We `removeTarget` per session, but if the app process dies mid-recording the remote command target persists in `MPRemoteCommandCenter.shared()` until next launch. Probably harmless but worth a defensive registration check on `start()`.

---

## Backlog (bigger upcoming pieces)

* **AppSync (Module 11) — change-feed endpoint.** iOS subscribes to server-side change events so a new browser-uploaded document shows up without a manual refresh. Blocked on Genie's change-feed endpoint design.
* **Offline project create / edit.** `PendingOperation` already has `.createProject` and `.updateProject` variants but they throw `OperationPermanentFailure` in the executor — no production caller enqueues them yet. Separate user flow + a different `ProjectServicing.create` signature that accepts a pre-generated id.
* **iPad / Apple Watch surfaces.** Future-future.
* **Multi-workspace from Account page.** The re-pair flow handles same-workspace refresh in place; different-workspace gets a confirm dialog and replaces. We don't currently support having two workspaces paired simultaneously — `AuthService.workspacesCache` is wired for it but no UI lets the user switch.

---

## Useful pointers (where things live)

* **Capture flow entry:** `App/Captures/LiveCaptureService.swift`
  * `startCapture` forks on `operationQueue` presence (Phase 3 path vs. legacy direct-call).
  * `patchCaptureState` is the shared queue-vs-direct fork used by stop / cancel / rollback.
* **OperationQueue family:** `App/Common/Operations/`
  * `PendingOperation.swift` — value type + Variant enum.
  * `OperationQueueStore.swift` — disk persistence.
  * `OperationQueue.swift` — actor + worker loop + executor protocol.
  * `OperationExecutor.swift` — factory that builds the closure routing variants to API clients.
* **App bootstrap:** `App/LakeloomApp.swift` builds the queue + executor + reachability→wake hook in the `.task` block.
* **Auth / pairing:** `App/Auth/Pairing/` — `PairingPayload`, `PairingStatus`, `QRScannerView`. `AppCoordinator+Repair.swift` owns the re-pair entry point.
* **Now Playing / background audio:** `App/Captures/Audio/NowPlayingController.swift` (Now Playing center wrapper). `EngineAudioRecordingEngine.swift` owns the AVAudioSession interruption observers.
* **Reachability:** `App/Common/Networking/ReachabilityMonitor.swift` — exposes `stateUpdates() -> AsyncStream<State>` for non-UI subscribers (the queue wake hook).
* **Test helpers:** `AppTests/Captures/Helpers/` — `FakeCaptureAPIClient`, `FakeAudioRecorder`, `FakeUploadCoordinator`, `FakeOperationQueue`, `FakeAudioInterruptionPublisher`, `SpyNowPlayingController`.

---

## Test count baseline

345 tests across 64 suites (last all-green run was 2026-05-27 on the `mg-ios-pr21-phase3-cutover` branch).

---

## Pickup checklist (when restarting)

1. `git fetch --all --prune` and check whether Genie's server fix has landed (`lakeloom-ai/server/routes/captures/capture-routes.ts` should destructure `client_generated_id` and reference it in the INSERT).
2. If yes: switch to `mg-ios-pr21-phase3-cutover`, rebase onto current `main` (Genie's fix will be merged separately, so the rebase pulls it in), run the sanity device test in the PR #77 description.
3. If no: still waiting. Move on to a follow-up from the "Known follow-ups" list, or pick up a backlog item.
4. If picking up a NEW PR: cut from `main` after the rebase above.
5. Always glance at `architecture/hey_isaac/` for any new replies before assuming Genie is silent.
