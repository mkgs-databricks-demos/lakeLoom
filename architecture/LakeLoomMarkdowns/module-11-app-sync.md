# Module 11 — AppSyncService (Brickster-side edits → iOS)

**Product:** Lakeloom
**Status:** Design — pre-implementation
**Last updated:** 2026-05-06
**Depends on:** AuthService (Module 01) for OAuth bearer tokens; AppCoordinator (Module 05) for active context; shared `EndpointResolver` (Module 03/06)
**Depended on by:** AppCoordinator (active-session-state updates); SessionsListViewModel (Module 08); future SessionDetailView annotations

---

## 1. Purpose

AppSyncService is the iOS client for **edits made on the Databricks App side** that need to surface back to the iOS app. After a capture session, a Databricks employee opens the lakeLoom App in a browser and may:

- Annotate a transcript chunk
- Mark a chunk as important / a requirement / out-of-scope
- Add session-level notes
- Edit the auto-generated requirements doc, architecture diagram, or Genie Code session plan
- Re-categorize the session under a different project
- Change a project's name or description

Some of these are user-facing on the iPhone (e.g., "this session has been marked complete by the Brickster on the web"); some affect what the iOS app should show in the Sessions list (project rename, annotations). AppSyncService is the single place that pulls these updates from the App and propagates them into the rest of the iOS app's state.

This module owns:

- Polling a Lakebase-backed cursor endpoint on the Databricks App (`GET /api/v1/sync/changes?since=...`)
- Translating change events into local-state updates (Sessions list, project cache, active session)
- Backoff and retry on transient failures
- A v1.x upgrade path to push (APNs + WebSocket)
- Cursor persistence so polling resumes from the right point across app launches

AppSyncService does **not** own:

- The schema or storage of the Brickster-side edits — that's the Databricks App's domain (Lakebase, per the lakeLoom rule of thumb)
- Sending iOS-originated changes to the App — that's IngestService for transcript events, ProjectService for project mutations, StorageService for audio
- UI rendering of changes — view-models subscribe to AppSyncService events and update their views

---

## 2. Design Principles

1. **Pull, not push, in v1.** Polling is simple, robust, and survives any network condition. Push (APNs + WebSocket) is a v1.x layer on top of the same model.
2. **Cursor-based, monotonically advancing.** Each change has a server-assigned `change_id` (or `(updated_at, change_id)` tuple) that the iOS client passes back as `since=`. The App returns only changes the client hasn't seen.
3. **Polling cadence respects foreground state.** Foreground: poll every 30 seconds (tunable). Background: rely on APNs nudges + opportunistic catch-up on next foreground. Locked: nothing.
4. **At-least-once delivery; idempotent application.** Every change carries a stable `change_id`; iOS deduplicates locally before applying. Replaying a change produces the same state.
5. **Lakebase is the App-side source of truth.** The Databricks App reads change-feed-style data out of Lakebase tables (e.g., `session_annotations`, `project_updates`) and serves them through this endpoint. iOS doesn't care which table or which Postgres feature — only the JSON contract.
6. **Bounded staleness, not freshness guarantees.** Worst case for v1: 30 seconds of staleness on the iPhone. The Brickster's view of the world is web-app-native; the iOS view exists for context, not authoritative editing. APNs/WebSocket close the gap to <1s in v1.x.
7. **Failure is invisible to the user when transient.** Polling failures back off and retry; the UI shows last-synced timestamp in Settings → Diagnostics but doesn't surface transient errors as banners.
8. **Resumes across app launches.** The cursor persists in `UserDefaults` per workspace. Cold launch resumes from where the prior session left off.
9. **Single network boundary.** Same rule as the rest of the app: HTTPS to the Databricks App. No direct Lakebase Postgres connection from iOS, no WebSocket to anything other than the App.
10. **Schema-version-aware.** The App returns `change_kind` enum values. Unknown kinds are logged and skipped (forward-compatible) rather than failing the whole poll.

---

## 3. Public Surface

### 3.1 Protocol

```swift
protocol AppSyncServicing: Sendable {
    /// Begin polling. Idempotent. Should be called once at app launch by AppCoordinator,
    /// or whenever AuthService transitions to a signed-in state.
    func start() async

    /// Stop polling and cancel any in-flight request. Cursor state is preserved.
    func stop() async

    /// Force an immediate poll, bypassing the cadence timer. Used by pull-to-refresh on
    /// Sessions list and on app foreground transitions.
    func pollNow() async

    /// Stream of decoded change events. Multicast — multiple subscribers (AppCoordinator,
    /// SessionsListViewModel, etc.) consume from this.
    var changes: AsyncStream<SyncChangeEvent> { get }

    /// Stream of poller-status changes (for diagnostics UI).
    var pollerStatus: AsyncStream<SyncPollerStatus> { get }

    /// Diagnostics for Settings.
    func diagnostics() async -> SyncDiagnostics

    /// Reset cursor for the active workspace. Useful after sign-out + sign-in cycles or
    /// for diagnostic recovery.
    func resetCursor(workspaceID: String) async
}
```

### 3.2 Value Types

```swift
enum SyncChangeEvent: Sendable, Equatable {
    /// A session was annotated (chunk-level note, importance flag, requirement tag).
    case sessionAnnotated(SessionAnnotationChange)

    /// A session's project assignment changed.
    case sessionRecategorized(sessionID: String,
                              fromProjectID: String,
                              toProjectID: String,
                              changedAt: Date)

    /// A session was marked complete / draft / archived by the Brickster.
    case sessionStatusChanged(sessionID: String,
                              status: SessionStatus,
                              changedAt: Date)

    /// A project's metadata was updated (name, description, archive state).
    case projectUpdated(ProjectMetadata)

    /// A new artifact was generated for a session (requirements doc, architecture
    /// diagram, Genie Code session plan).
    case artifactGenerated(ArtifactReference)

    /// A change with a kind we don't recognize. Logged for diagnostics, not surfaced.
    case unknown(kind: String, changeID: String)
}

struct SessionAnnotationChange: Sendable, Equatable {
    let sessionID: String
    let chunkRecordUUID: String?           // nil for session-level annotations
    let annotationKind: AnnotationKind
    let annotationText: String?
    let annotatedBy: String                // Databricks userName who made the edit
    let annotatedAt: Date
    let changeID: String
}

enum AnnotationKind: String, Sendable, Codable {
    case important
    case requirement
    case outOfScope
    case note
    case tag
}

enum SessionStatus: String, Sendable, Codable {
    case draft
    case inReview
    case complete
    case archived
}

struct ArtifactReference: Sendable, Equatable {
    let sessionID: String
    let projectID: String
    let artifactID: String
    let artifactKind: ArtifactKind
    let title: String
    let appURL: URL                         // deep link into the Databricks App's view
    let generatedAt: Date
    let changeID: String
}

enum ArtifactKind: String, Sendable, Codable {
    case requirementsDoc       = "requirements_doc"
    case architectureDiagram   = "architecture_diagram"
    case sessionPlan           = "session_plan"
}

enum SyncPollerStatus: Sendable, Equatable {
    case idle
    case polling
    case backingOff(until: Date, reason: String)
    case waitingForNetwork
    case waitingForAuth
    case stopped
}

struct SyncDiagnostics: Sendable {
    let cursorByWorkspace: [String: String?]
    let lastSuccessfulPollAt: Date?
    let lastErrorAt: Date?
    let lastErrorReason: String?
    let pollsLifetime: Int64
    let changesAppliedLifetime: Int64
    let avgPollLatencyMs: Double?
}

enum SyncError: Error, Sendable, Equatable {
    case authFailed(reason: String)
    case rejectedByServer(httpStatus: Int, reason: String)
    case serverUnavailable(reason: String)
    case networkUnavailable
    case timeout
    case schemaMismatch(reason: String)
    case unknown(reason: String)
}
```

---

## 4. Internal Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    AppSyncService (actor)                   │
└─────────────────────────────────────────────────────────────┘
       │                  │                  │
       ▼                  ▼                  ▼
┌─────────────┐  ┌────────────────┐  ┌─────────────────────┐
│  Cursor     │  │  Sync API      │  │  Poller             │
│  Store      │  │  Client        │  │  (cadence timer +   │
│  (User-     │  │  (URLSession,  │  │   state machine,    │
│   Defaults  │  │   OAuth        │  │   single Task)      │
│   per-ws)   │  │   Bearer)      │  │                     │
└─────────────┘  └────────┬───────┘  └─────────────────────┘
                          │
                          ▼
                ┌──────────────────────────────────────┐
                │  Databricks App (TypeScript)         │
                │  GET /api/v1/sync/changes?since=...  │
                │   ↳ reads Lakebase change-feed       │
                └──────────────────────────────────────┘
```

### 4.1 Concurrency Model

- `AppSyncService` is a Swift `actor`. Public method calls serialize through it.
- The **Poller** is a single long-running `Task` owned by the actor. Idle ↔ polling ↔ backingOff ↔ waitingForNetwork ↔ waitingForAuth — same shape as Module 03's drainer state machine.
- The **Sync API Client** is a `Sendable` struct with no mutable state.
- The **Cursor Store** is a thin wrapper around `UserDefaults`; reads/writes are sync but cheap.
- The `changes` and `pollerStatus` streams are `AsyncStream`s with multicast continuations owned by the actor.

### 4.2 The Poller State Machine

```
                   ┌──────┐
              ┌───►│ idle │───── poll cadence elapsed ────┐
              │    └──┬───┘                               │
              │       │ pollNow() called                  │
              │       ▼                                   │
              │  ┌──────────┐                             │
              │  │ polling  │── 200 OK + applied ─────────┘
              │  └────┬─────┘
              │       │
              │       │ network err / 5xx
              │       ▼
              │  ┌─────────────────────┐
              ├──┤ backingOff          │
              │  └─────────────────────┘
              │       ▲
              │       │ backoff elapses
              │
              │       │ network lost
              │       ▼
              │  ┌─────────────────────┐
              ├──┤ waitingForNetwork   │
              │  └─────────────────────┘
              │       ▲
              │       │ network returns
              │
              │       │ auth refresh failed
              │       ▼
              │  ┌─────────────────────┐
              └──┤ waitingForAuth      │
                 └─────────────────────┘
                       ▲
                       │ user re-login
```

Transitions are driven by: cadence-timer fires, `pollNow()` calls, reachability path changes, auth events, and HTTP responses.

### 4.3 Cadence

| App state | Cadence |
|---|---|
| Foreground, Sessions tab visible | every 15 s |
| Foreground, other tab visible | every 30 s |
| Foreground, capture in progress | paused (server is unlikely to have changes the user cares about *during* a capture) |
| Background | paused; rely on APNs + foreground catch-up (v1.x) |

Manual `pollNow()` always fires immediately and resets the cadence timer.

### 4.4 Backoff

Same backoff math as IngestService (Module 03 §6.5): 1s base, 60s cap, ±25% jitter, doubled per attempt up to 6th. Cleanest reuse — share the `BackoffPolicy` helper across modules.

---

## 5. The Sync Endpoint Contract

The Databricks App exposes a single endpoint for change polling.

### 5.1 Request

```http
GET {appBaseURL}/api/v1/sync/changes?workspace_id={ws}&since={cursor}&limit=100
Authorization: Bearer {accessToken}
X-Databricks-Workspace-Id: {ws}
X-Lakeloom-Schema-Version: 1.0.0
```

- `since` is the cursor returned by the previous successful poll. Empty / absent on first poll for a workspace — the App returns the most recent N changes (App's discretion; v1 default is "last 24 hours").
- `limit` caps the response page size. iOS uses 100; the App may return fewer.

### 5.2 Response

```json
{
  "changes": [
    {
      "change_id": "01975e4f-3a7c-7890-b1c2-d4e5f6a7b8c9",
      "change_kind": "session_annotated",
      "occurred_at": "2026-05-06T18:14:22.331Z",
      "workspace_id": "1234567890123456",
      "actor_user_id": "1234567890123456",
      "actor_username": "brickster@databricks.com",
      "payload": {
        "session_id": "01975e4f-3a7c-7890-b1c2-d4e5f6a7b8aa",
        "chunk_record_uuid": "01975e4f-3a7c-7890-b1c2-d4e5f6a7b8bb",
        "annotation_kind": "important",
        "annotation_text": "Customer wants this as a hard requirement"
      }
    }
  ],
  "next_cursor": "01975e4f-3a7c-7890-b1c2-d4e5f6a7b8c9",
  "has_more": false,
  "server_time": "2026-05-06T18:14:23.001Z"
}
```

- `change_id` is the per-change stable identifier (UUIDv7 from the App side).
- `change_kind` is one of: `session_annotated`, `session_recategorized`, `session_status_changed`, `project_updated`, `artifact_generated`. Unknown kinds are logged and skipped.
- `next_cursor` is what iOS sends back on the next poll. Treat opaquely — don't parse.
- `has_more` indicates the response was truncated by `limit`; iOS issues another poll immediately to drain.

### 5.3 Error Mapping

Same mapping as Module 06's ProjectAPIClient (HTTP status → typed error). `403` and `400` indicate a deeper issue (auth scope or schema mismatch); `5xx` and timeouts trigger backoff.

---

## 6. Cursor Persistence

Cursor state is stored in `UserDefaults`, keyed by workspace ID:

```
sync.cursor.<workspaceID> → "01975e4f-3a7c-7890-b1c2-d4e5f6a7b8c9"
sync.last_successful_at.<workspaceID> → "2026-05-06T18:14:23.001Z"
```

Cursor is updated atomically: write the new cursor *after* the change events for that page have been emitted to subscribers. If iOS crashes between the network response and the cursor write, the next poll re-fetches the same page — at-least-once delivery is the contract, and downstream view-models dedupe on `change_id`.

`resetCursor(workspaceID:)` clears the cursor; the next poll requests the App's default initial window (last 24 hours).

---

## 7. Applying Changes — Subscribers and Effects

AppSyncService doesn't apply changes itself; it emits them on the `changes` stream. Three primary subscribers:

### 7.1 AppCoordinator

Listens for:
- `sessionRecategorized` affecting the active session — surfaces a toast ("This session was moved to project X by the Brickster")
- `projectUpdated` for the active project — refreshes `activeContext.project`

### 7.2 SessionsListViewModel (Module 08)

Listens for:
- `sessionAnnotated` → updates the relevant row's annotation badges
- `sessionStatusChanged` → updates the row's status badge
- `sessionRecategorized` → moves the session under the new project's group
- `artifactGenerated` → adds a small "📎 Plan ready" indicator on the row

### 7.3 ProjectService (Module 06)

Listens for:
- `projectUpdated` → updates its in-memory cache so the picker reflects the new name on next open

### 7.4 Idempotency at the Subscriber Level

Each subscriber maintains a small set of recently-applied `change_id`s (last 1000 in memory) and short-circuits duplicates. This is belt-and-suspenders: AppSyncService already dedupes via the cursor, but app crashes between cursor write and subscriber-side persistence can replay a change.

---

## 8. v1.x Upgrade Path — Push

The polling design in v1 is the foundation. v1.x adds push without changing the contract.

### 8.1 APNs

The Databricks App registers an APNs key and sends a silent (`content-available: 1`) push to iOS whenever:
- A change occurs on a session the user has interacted with recently
- A change affects the user's currently-active session

iOS's APNs handler calls `appSync.pollNow()`. APNs is a *nudge*, not a payload-bearing event — it just tells iOS "wake up and poll." This means the same code path drains the change feed regardless of how the wake was triggered.

Latency: APNs typically delivers in <1 second; combined with the poll, end-to-end latency drops from "up to 30s" (v1) to "~1s" (v1.x).

### 8.2 WebSocket (later v1.x or v2)

Once we have telemetry on actual change rates per session, we can decide whether to upgrade from APNs+poll to a long-lived WebSocket while the app is foregrounded. The contract becomes:

```
WS {appBaseURL}/api/v1/sync/stream?workspace_id={ws}&since={cursor}
```

Server pushes change events as they occur. iOS still maintains the poll path as a fallback for cellular / backgrounded states.

### 8.3 What Doesn't Change

- The `change_id` cursor model
- The `SyncChangeEvent` shape
- Subscriber behavior

This is why the v1 design uses pull: it lets us ship without push infrastructure and upgrade to push later without breaking the consumer contract.

---

## 9. Integration Points

### 9.1 With AuthService

Standard pattern: `auth.currentToken()` before each poll. On 401, force-refresh and retry once. On `AuthError.refreshFailed` from the refresh attempt, transition to `waitingForAuth` and stop polling until the user re-authenticates.

### 9.2 With AppCoordinator

AppCoordinator owns the lifecycle:
- `bootstrap()` → `appSync.start()` (after services are running and a workspace is active)
- Workspace switch → `appSync.start()` is idempotent; the actor swaps the active workspace ID
- Sign-out → `appSync.stop()`; cursor persists for next sign-in to that workspace
- App backgrounded → poll cadence pauses (the actor checks `phase` from AppCoordinator)
- App foregrounded → `appSync.pollNow()` to catch up immediately

### 9.3 With Reachability

Same shared `Reachability` actor used by Modules 03 and 04. Polling pauses on no-network and resumes on connectivity. Cellular is fine for sync — payloads are small (KBs) and updates are infrequent.

---

## 10. Threading and Reentrancy

- `AppSyncService` actor serializes public methods.
- The poller is a single Task; concurrent `pollNow()` calls coalesce into the in-flight request.
- Cursor reads/writes are actor-isolated.
- Subscribers (AppCoordinator, ViewModels) consume `changes` on their own actors; the multicast continuation yields under sync-service isolation, so ordering of events is consistent across subscribers.
- Cancellation: `stop()` cancels the poller Task; in-flight requests are canceled cooperatively. The cursor is *not* advanced when a poll is canceled mid-flight — next poll re-fetches.

---

## 11. Test Strategy

### 11.1 Unit Tests

- **State machine transitions:** every edge in §4.2 exercised with scripted poller events
- **Cursor persistence:** crash mid-apply (simulated) → re-poll fetches same page; cursor advances only after subscriber emit
- **Backoff policy:** monotonic growth, cap, jitter bounds (shared with Module 03)
- **Error mapping:** every documented HTTP status maps to expected `SyncError`
- **Pagination:** `has_more: true` triggers immediate re-poll until drained
- **Unknown change kind:** logged, skipped, cursor still advances

### 11.2 Integration Tests

- **End-to-end with mock App server:** scripted change feed; verify subscribers receive events in order with correct dedup
- **Cursor reset on `resetCursor(workspaceID:)`** → next poll uses no `since` parameter
- **Workspace switch mid-poll** → in-flight request canceled, new workspace's cursor used on next poll

### 11.3 Test Seams

```swift
protocol SyncAPIClienting: Sendable { /* ... */ }
protocol CursorStoring: Sendable { /* ... */ }
protocol Reachable: Sendable { /* shared with Modules 03 and 04 */ }
```

Production: live implementations. Tests: `ScriptedSyncAPIClient`, `InMemoryCursorStore`, `ManualReachability`.

---

## 12. Observability

- Log every poll attempt at `debug` with workspace ID prefix, since-cursor prefix, response code, change count, duration
- **Never log change payload contents** — annotations may contain customer-specific info
- Counters in `SyncDiagnostics`:
  - `sync.polls.total`
  - `sync.polls.success`
  - `sync.polls.failed`
  - `sync.changes.received`
  - `sync.changes.applied`
  - `sync.changes.unknown_kind`
- Per-poll latency histogram for the diagnostics screen
- Settings → Diagnostics → "Sync" shows: last successful poll time, last error, current cursor (prefix), polls in last hour

---

## 13. Out of Scope for v1

- **APNs push.** Designed-in (§8.1), not implemented in v1.
- **WebSocket.** Designed-in (§8.2), not implemented in v1 or early v1.x.
- **Filtering changes by project.** v1 returns all changes for the user's workspace; iOS subscribers filter locally. v1.x: server-side `project_id=` query parameter.
- **iOS-originated edits to App-owned state.** This module is read-only for iOS. iOS-originated changes go through their owning module (IngestService for transcripts, ProjectService for projects).
- **Conflict resolution.** App is single-source-of-truth on its data; iOS reflects what it's told. No multi-master scenarios in v1.
- **Offline change queue.** No iOS-initiated changes flow through this module, so no offline queue is needed.

---

## 14. Open Items

| # | Item | Resolution Path |
|---|---|---|
| 1 | Exact `change_kind` enum vocabulary — final list of values for v1 | Lock in `architecture/hi_genie/`; iOS handles unknown kinds gracefully so additions are non-breaking |
| 2 | Cursor format — opaque string vs `(updated_at, change_id)` tuple | iOS treats it opaquely either way; App's internal choice |
| 3 | App-side change-feed implementation — Lakebase logical replication, polling Lakebase tables, or a maintained `change_log` table | App's implementation detail; document in `architecture/hi_genie/` |
| 4 | Initial-window default when `since` is empty (last 24h proposed) | Confirm with App team; tunable per deployment |
| 5 | Whether `pollNow()` from a foreground transition should always fire vs respect a minimum-spacing throttle | v1: always fire; revisit if it produces excess load |
| 6 | Behavior when the app is foregrounded after a multi-day backgrounded state and the cursor is far behind — single huge response or paginated drain | Pagination via `has_more` handles this naturally; no special-case needed |
| 7 | Handling of `artifact_generated` changes — should iOS preview the artifact or just deep-link to the App? | v1: deep-link only via `appURL`. v1.x: preview rendering of architecture diagrams (Mermaid) and requirements markdown |
| 8 | Whether `session_recategorized` events should also trigger a refresh of the corresponding session's transcript view | v1: yes, invalidate detail view. Cheap. |

---

## 15. File Layout (proposed)

```
App/AppSync/
├── AppSyncService.swift                    // actor, public surface
├── AppSyncServicing.swift                  // protocol + value types + SyncError
├── SyncChangeEvent.swift
├── SyncPollerStatus.swift
├── SyncDiagnostics.swift
├── Poller/
│   ├── Poller.swift
│   ├── PollerState.swift
│   └── CadencePolicy.swift
├── API/
│   ├── SyncAPIClient.swift                 // protocol
│   ├── LiveSyncAPIClient.swift             // URLSession-backed
│   ├── ScriptedSyncAPIClient.swift         // test impl
│   ├── SyncChangesResponse.swift           // Codable response body
│   └── SyncErrorMapper.swift
├── Cursor/
│   ├── CursorStore.swift                   // protocol
│   ├── LiveCursorStore.swift               // UserDefaults-backed
│   └── InMemoryCursorStore.swift           // test impl
└── Push/                                    // v1.x; stubs in v1
    ├── APNsRegistration.swift
    └── PushNudgeHandler.swift
```

Tests mirror this layout under `AppTests/AppSync/`.
