# Module 03 — IngestService + IngestProxyClient

**Product:** Lakeloom
**Status:** Design — pre-implementation
**Last updated:** 2026-05-06
**Depends on:** AuthService (bearer tokens), CaptureEngine (event stream), shared `ZeroBusSchema.swift`
**Depended on by:** AppCoordinator (status surfacing), Settings (diagnostics, manual retry)

---

## 1. Purpose

IngestService is the durable, network-aware bridge between CaptureEngine's event stream and Databricks ZeroBus. It owns:

- Subscribing to `CaptureEngine.events` and persisting every event to a local **outbox** before any network call
- Sending records to the Databricks App over **HTTPS POST** using OAuth bearer tokens from AuthService; the App forwards them to ZeroBus via its TypeScript Zerobus SDK
- Retry, backoff, and dead-letter handling
- Surviving app termination — pending records are sent on the next launch
- Surfacing per-session ingest status to the UI

IngestProxyClient is the HTTP transport layer. It knows how to authenticate (OAuth bearer in the `Authorization` header), how to construct a JSON batch body, and how to interpret HTTP responses. It is stateless and replaceable; the durable behavior lives in IngestService.

> **Architectural note.** iOS does not speak gRPC to ZeroBus directly. The Databricks App owns the Zerobus SDK call (TypeScript, server-side), exposing a small HTTP endpoint that iOS POSTs JSON batches to. This realizes lakeLoom's single-network-boundary rule: iOS only ever talks HTTPS to the Databricks App. Schema versioning, idempotency keys, and at-least-once semantics still apply end-to-end — they're just expressed over HTTP+JSON on the iOS hop and gRPC on the App→Zerobus hop.

IngestService does **not** own audio uploads (that's StorageService) or session state (that's CaptureEngine). It owns one thing: making sure every captured event lands in ZeroBus eventually, in order, exactly once from the silver pipeline's point of view.

---

## 2. Design Principles

1. **Outbox-first.** Every event is persisted to local storage before any network attempt. Memory-only is forbidden — a force-quit during transmission must not lose data.
2. **At-least-once delivery, deduped server-side.** Both hops (iOS → App, App → ZeroBus) are at-least-once. The silver pipeline dedupes on `record_uuid`. We never try to achieve exactly-once on the wire.
3. **Idempotent batches.** Every record carries a client-generated `record_uuid` (UUIDv7). Retrying an entire batch is safe; the App and silver layer dedupe on `(session_id, record_uuid)`.
4. **Ordering preserved best-effort, not strictly.** Records carry `sequence_number` per session and the silver pipeline orders on it. The wire path is allowed to deliver out of order under retry, but in steady state it sends in order — outbox queries pull batches `(sessionID, sequenceNumber)` ascending.
5. **The outbox survives anything short of a wiped device.** Process crash, OS jetsam, app update, reboot — pending records persist and resume.
6. **Auth is delegated.** IngestService never reads tokens from Keychain or refreshes them. It calls `AuthService.currentToken()` and reacts to typed `AuthError` results.
7. **Network-aware, not network-dependent.** No connectivity → records accumulate in the outbox. Connectivity returns → drain resumes automatically.
8. **Bounded retry with explicit dead-letter.** Records that fail permanently move to a dead-letter state, not silently dropped, and surface in Settings.
9. **One serialized writer.** Exactly one outbox-drain task runs at a time per app process. Concurrency is for buffering, not for parallelism on the wire.
10. **Failure is observable.** Every attempt is logged with structured fields. A diagnostics surface exposes counters per workspace/session.
11. **Schema-version-aware on send.** The `schema_version` field is set on every record from a single constant; mismatched App-side expectations surface as a typed error (HTTP 400 with a known reason code) rather than silent rejection.
12. **Single network boundary.** iOS speaks HTTPS to one host: the Databricks App. No direct gRPC to ZeroBus, no direct Postgres to Lakebase. The App fans out to backend services on iOS's behalf.

---

## 3. Public Surface

### 3.1 Protocol

```swift
protocol IngestServicing: Sendable {
    /// Begin processing the CaptureEngine event stream. Idempotent.
    /// Should be called once at app launch by AppCoordinator.
    func start() async

    /// Stop processing and gracefully drain in-flight work. Persisted records remain.
    func stop() async

    /// Stream of ingest status changes (per-session, per-record state transitions).
    /// UI subscribes to render the Sessions list.
    var status: AsyncStream<IngestStatusEvent> { get }

    /// Snapshot of current per-session ingest status. Cheap; reads from cache.
    func sessionStatus(sessionID: String) async -> SessionIngestStatus?

    /// Snapshot of all sessions with non-terminal ingest state.
    func pendingSessions() async -> [SessionIngestStatus]

    /// Force a retry of dead-lettered records for a session. User-initiated.
    func retryDeadLettered(sessionID: String) async throws

    /// Diagnostics for the Settings screen.
    func diagnostics() async -> IngestDiagnostics
}
```

### 3.2 Value Types

```swift
struct SessionIngestStatus: Sendable, Equatable {
    let sessionID: String
    let projectID: String
    let workspaceID: String
    let totalRecords: Int            // includes lifecycle + chunks
    let sentRecords: Int
    let pendingRecords: Int
    let failedRecords: Int
    let deadLetteredRecords: Int
    let lastSentAt: Date?
    let lastError: String?
    let state: SessionIngestState
}

enum SessionIngestState: String, Sendable {
    case sending                     // active drain in progress
    case waitingForNetwork
    case waitingForAuth              // refresh failed, user must re-login
    case complete                    // all records sent; session is closed
    case partiallyFailed             // some dead-lettered; needs user attention
}

enum IngestStatusEvent: Sendable {
    case sessionUpdated(SessionIngestStatus)
    case recordSent(recordUUID: String, sessionID: String)
    case recordFailed(recordUUID: String, sessionID: String, error: IngestError, willRetry: Bool)
    case drainerStateChanged(DrainerState)
}

enum DrainerState: Sendable {
    case idle
    case draining
    case waitingForNetwork
    case waitingForAuth
    case backingOff(until: Date)
}

enum IngestError: Error, Sendable, Equatable {
    case networkUnavailable
    case authFailed(reason: String)              // refresh failed; user must re-login
    case rejectedByServer(httpStatus: Int, reason: String)   // 4xx other than 401
    case serverUnavailable(reason: String)        // 5xx
    case schemaMismatch(reason: String)          // App rejected our schema_version
    case payloadTooLarge(reason: String)         // HTTP 413
    case rateLimited(retryAfter: Duration?)      // HTTP 429
    case timeout
    case unknown(reason: String)
}

struct IngestDiagnostics: Sendable {
    let totalRecordsSentLifetime: Int64
    let totalRecordsFailedLifetime: Int64
    let outboxDepth: Int
    let deadLetterDepth: Int
    let lastSuccessfulSendAt: Date?
    let avgSendLatencyMs: Double?
    let perWorkspace: [String: WorkspaceIngestStats]
}

struct WorkspaceIngestStats: Sendable {
    let workspaceID: String
    let recordsSent: Int64
    let recordsFailed: Int64
    let lastSendAt: Date?
}
```

---

## 4. Internal Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                       IngestService (actor)                 │
└─────────────────────────────────────────────────────────────┘
       │                │                │                │
       ▼                ▼                ▼                ▼
┌─────────────┐  ┌─────────────┐  ┌──────────────┐  ┌────────────┐
│  Outbox     │  │  Drainer    │  │ IngestProxy- │  │ Network    │
│  (Core Data │  │  (single    │  │ Client       │  │ Reachabili-│
│   actor)    │  │   task,     │  │ (URLSession, │  │ ty (NWPath │
│             │  │   state     │  │  Sendable)   │  │  Monitor)  │
│             │  │   machine)  │  │              │  │            │
└─────────────┘  └──────┬──────┘  └──────┬───────┘  └─────┬──────┘
                        │                │                │
                        └─ pulls from Outbox              │
                        └─ awaits Reachability ───────────┘
                        └─ calls IngestProxyClient.postBatch(...)
                        └─ updates Outbox on success/failure
                        └─ emits IngestStatusEvent

           ┌────────────────────────────────────────────────┐
           │  Databricks App (TypeScript, server-side)      │
           │  POST /api/v1/ingest/snippets                  │
           │  → Zerobus TS SDK → bronze table              │
           └────────────────────────────────────────────────┘
```

### 4.1 Concurrency Model

- `IngestService` is a Swift `actor`. Public method calls serialize through it.
- The **Outbox** is a separate actor wrapping Core Data. All reads/writes are async.
- The **Drainer** is a long-running `Task` owned by IngestService. There is exactly one drainer task per app process. It runs a state machine loop that pulls work from the outbox, sends it via ZeroBusClient, and updates the outbox.
- **Reachability** is a small actor wrapping `NWPathMonitor`. It exposes `currentPath: NetworkPath` and `pathChanges: AsyncStream<NetworkPath>`.
- **IngestProxyClient** is a `Sendable` struct (or final class with no mutable state). Stateless. Each `postBatch` call constructs a fresh `URLRequest` and uses an injected `URLSession`.

### 4.2 The Drainer State Machine

```
                   ┌──────┐
              ┌───►│ idle ├────── outbox empty ──────┐
              │    └──┬───┘                          │
              │       │ work appears                 │
              │       ▼                              │
              │  ┌──────────┐                        │
              │  │ draining │──── all sent ──────────┘
              │  └────┬─────┘
              │       │
              │       │ network lost
              │       ▼
              │  ┌─────────────────────┐
              ├──┤ waitingForNetwork   │
              │  └─────────────────────┘
              │       ▲
              │       │ network returns
              │       │
              │       │ auth refresh failed
              │       ▼
              │  ┌─────────────────────┐
              ├──┤ waitingForAuth      │
              │  └─────────────────────┘
              │       ▲
              │       │ user re-login
              │       │
              │       │ 5xx / transient
              │       ▼
              │  ┌─────────────────────┐
              └──┤ backingOff          │
                 └─────────────────────┘
                       │
                       │ backoff elapses
                       └─►  draining
```

Transitions are driven by events: outbox change notifications, reachability path changes, auth events from AuthService, and timer fires for backoff. The drainer runs as `for await event in mergedEventStream` and reacts.

---

## 5. Outbox Design

The outbox is the durability boundary. It must be:
- Cheap to write (<1 ms per record on a modern iPhone)
- Cheap to query for the next batch
- Safe under crash (Core Data with WAL journaling on SQLite is the default and adequate)
- Independent of CaptureEngine and ZeroBusClient — only IngestService and Outbox know about it

### 5.1 Core Data Entity

```
OutboxRecord
├── recordUUID: String              [primary key, UUIDv7]
├── sessionID: String                [indexed]
├── workspaceID: String              [indexed]
├── projectID: String
├── sequenceNumber: Int32
├── eventType: String                [transcript_chunk | session_start | session_end | audio_uploaded]
├── deviceTimestamp: Date
├── chunkStartOffsetMs: Int64
├── chunkEndOffsetMs: Int64
├── captureMode: String
├── schemaVersion: String
├── headersJSON: String              [serialized variant headers]
├── payloadJSON: String              [serialized variant payload]
├── state: String                    [pending | inflight | sent | failed | dead_lettered]   [indexed]
├── retryCount: Int32
├── lastError: String?
├── lastAttemptedAt: Date?
├── nextEligibleAt: Date             [indexed; for backoff scheduling]
├── createdAt: Date
├── sentAt: Date?
└── deadLetteredAt: Date?
```

Indexes:
- `(state, nextEligibleAt)` — primary query for "what's the next batch to send"
- `(sessionID, sequenceNumber)` — for ordered drain within a session and UI status
- `(workspaceID, state)` — for workspace-scoped diagnostics

### 5.2 Outbox API (Actor)

```swift
actor OutboxStore {
    func enqueue(_ records: [OutboxRecord]) async throws
    func nextBatch(maxCount: Int, now: Date) async throws -> [OutboxRecord]
    func markInflight(_ recordUUIDs: [String], now: Date) async throws
    func markSent(_ recordUUIDs: [String], now: Date) async throws
    func markFailed(_ recordUUID: String, error: String, nextEligibleAt: Date, now: Date) async throws
    func markDeadLettered(_ recordUUID: String, error: String, now: Date) async throws
    func markPendingForRetry(sessionID: String, fromState: [String], now: Date) async throws -> Int
    func snapshot(sessionID: String) async throws -> SessionIngestStatus?
    func snapshot(allWithStates: [String]) async throws -> [SessionIngestStatus]
    func depth() async throws -> (pending: Int, deadLettered: Int)
    func purgeSent(olderThan: Date) async throws -> Int
    var changes: AsyncStream<OutboxChange> { get }   // notifications for drainer
}
```

Implementation notes:

- **Write coalescing.** `enqueue` accepts a batch and writes in a single Core Data save. CaptureEngine emits events one at a time, but in practice multiple events can pile up between drainer cycles; we batch them.
- **`nextBatch` query.** `state == 'pending' AND nextEligibleAt <= now` ordered by `(sessionID, sequenceNumber)` ascending, limited to `maxCount` (default 50). Records from the same session stay together to preserve order on the wire.
- **`markInflight`** is a defensive state. If the app crashes between `markInflight` and `markSent`, the next launch finds inflight records and reverts them to `pending` (see §10).
- **`changes` stream.** Yields whenever new records are enqueued or moved between states. The drainer subscribes to know when to wake up.

### 5.3 Retention

- Records in `sent` state are retained for **24 hours** to support diagnostic queries, then purged
- Records in `dead_lettered` state are retained until the user manually retries or the session is more than 30 days old
- Background cleanup runs once per app launch and on a 6-hour timer

---

## 6. The Drainer

The drainer is the heart of IngestService. It's a single long-running task with a state machine.

### 6.1 Top-Level Loop

```swift
private func runDrainerLoop() async {
    var state: DrainerState = .idle
    publishState(state)

    let merged = MergedEvents(
        outboxChanges: outbox.changes,
        networkPaths: reachability.pathChanges,
        authEvents: auth.events,
        backoffTimer: backoffTimerStream()
    )

    for await event in merged {
        if Task.isCancelled { break }
        state = await handle(event: event, currentState: state)
        publishState(state)
    }
}
```

`MergedEvents` is a small helper that interleaves four async sequences into one. Implemented with `AsyncMergeSequence` from swift-async-algorithms or hand-rolled with `withTaskGroup`.

### 6.2 Drain Cycle

When state transitions to `.draining`:

```swift
private func drainCycle() async -> DrainerState {
    while !Task.isCancelled {
        let now = Date()
        let batch: [OutboxRecord]
        do {
            batch = try await outbox.nextBatch(maxCount: batchSize, now: now)
        } catch {
            log.error("Outbox query failed: \(error)")
            return .backingOff(until: now.addingTimeInterval(5))
        }

        if batch.isEmpty { return .idle }

        // Network check
        guard reachability.currentPath.isReachable else {
            return .waitingForNetwork
        }

        // Auth check
        let token: AccessToken
        do {
            token = try await auth.currentToken()
        } catch AuthError.refreshFailed {
            return .waitingForAuth
        } catch AuthError.networkUnavailable {
            return .waitingForNetwork
        } catch {
            return .backingOff(until: now.addingTimeInterval(10))
        }

        // Mark inflight
        try? await outbox.markInflight(batch.map(\.recordUUID), now: now)

        // Send
        let result = await sendBatch(batch, token: token)
        await applyResult(result, batch: batch)

        if result.shouldPause {
            return result.pauseState
        }

        // Loop and pull next batch
    }
    return .idle
}
```

### 6.3 Sending a Batch

The Databricks App accepts a JSON batch in a single HTTP POST. The drainer issues one POST per batch:

```swift
private func sendBatch(_ batch: [OutboxRecord], token: AccessToken) async -> BatchResult {
    let workspaceID = batch.first!.workspaceID
    // All records in a batch belong to the same workspace (the outbox query
    // groups by sessionID, and a session belongs to one workspace).

    let endpoint = try? await endpointResolver.resolve(workspaceID: workspaceID)
    guard let endpoint else {
        return .pause(.backingOff(until: Date().addingTimeInterval(30)))
    }

    let body = IngestBatchBody(
        schemaVersion: SchemaVersion.current,
        records: batch.map { $0.toJSONRecord() }
    )

    do {
        let acks = try await proxy.postBatch(endpoint: endpoint, token: token, body: body)
        let acceptedUUIDs = Set(acks.accepted)
        let rejected = acks.rejected
        return .partialOrFullSuccess(accepted: acceptedUUIDs,
                                     rejected: rejected,
                                     batch: batch)
    } catch let error as IngestProxyError {
        return mapProxyError(error, batch: batch)
    } catch {
        return .failure(error: .unknown(reason: error.localizedDescription), batch: batch)
    }
}
```

The App's response distinguishes per-record outcomes (`accepted` / `rejected`) so a single bad record in a batch doesn't poison the rest. Rejected records are dead-lettered with their per-record reason; accepted records advance to `sent`.

### 6.4 Error Mapping and Retry Logic

```swift
private func mapProxyError(_ error: IngestProxyError, batch: [OutboxRecord]) -> BatchResult {
    switch error {
    case .unauthorized:                           // HTTP 401
        // Try one force-refresh-and-retry inline before declaring auth failure.
        return .retryWithForceRefresh

    case .timeout, .serverUnavailable, .badGateway:    // 502/503/504 + URLError timeouts
        // Transient. Back off, retry the same batch.
        return .pause(.backingOff(until: nextBackoffDate()))

    case .rateLimited(let retryAfter):            // HTTP 429
        // Honor server-supplied delay, otherwise standard backoff.
        return .pause(.backingOff(until: retryAfter ?? nextBackoffDate()))

    case .badRequest(let detail):                 // HTTP 400
        // Malformed payload — permanent for these records. Dead-letter.
        return .deadLetter(reason: "bad_request: \(detail)", batch: batch)

    case .schemaMismatch(let detail):             // HTTP 400 with reason="schema_mismatch"
        // Schema mismatch. App needs an update or iOS does. Dead-letter and surface loudly.
        return .deadLetter(reason: "schema_mismatch: \(detail)", batch: batch)

    case .forbidden:                              // HTTP 403
        // User's token is valid but lacks ZeroBus write permission for this workspace.
        // The App returns this when its downstream authorization to ZeroBus / UC fails.
        // Dead-letter; user-actionable through Databricks admin.
        return .deadLetter(reason: "forbidden", batch: batch)

    case .payloadTooLarge:                        // HTTP 413
        // Should not happen with our 50-record/256KB-per-record cap, but if it does
        // we split the batch in half and retry the halves.
        return .splitAndRetry(batch: batch)

    case .internalServerError(let detail):        // HTTP 500
        // Server bug. Back off harder; retry.
        return .pause(.backingOff(until: nextBackoffDate(multiplier: 2)))

    case .canceled:
        // We canceled (e.g., app backgrounded, drainer stop). Revert to pending.
        return .revert(batch: batch)

    case .networkUnavailable:
        return .pause(.waitingForNetwork)
    }
}
```

### 6.5 Backoff

Exponential with jitter and cap:

```
baseDelay = 1s
maxDelay  = 60s
jitter    = ±25%

delay(attempt) = min(maxDelay, baseDelay * 2^min(attempt, 6)) * (1 ± random(0..0.25))
```

Per-record `retryCount` drives the backoff calculation. After 8 attempts a record moves to `dead_lettered` regardless of error type. The retry budget is intentionally generous because Quick Capture chunks are small and we'd rather over-retry than lose data.

### 6.6 Auth Refresh Inline Retry

The auth-failed-refresh-once-and-retry path is special-cased so transient 401s (clock skew, server-side rotation) don't bounce out to the `waitingForAuth` state:

```swift
case .retryWithForceRefresh:
    do {
        let freshToken = try await auth.currentToken(forceRefresh: true)
        let result = await sendBatch(batch, token: freshToken)
        // Map the second result; do NOT recurse into another force-refresh.
        return result.collapsedAfterForceRefresh()
    } catch {
        return .pause(.waitingForAuth)
    }
```

If the second attempt also gets `.unauthorized`, we treat it as `waitingForAuth` (genuine refresh failure, user must re-login).

---

## 7. IngestProxyClient — HTTP Implementation

### 7.1 Why HTTP, Not gRPC

iOS clients do not speak gRPC to ZeroBus directly. The Databricks App owns the Zerobus SDK call (TypeScript, server-side); iOS POSTs JSON to the App. Reasons:

- **Single network boundary on iOS.** The app talks HTTPS to one host (the Databricks App). Easier to reason about auth, certificate trust, network monitoring, and proxy-friendliness on enterprise networks.
- **Decoupling.** ZeroBus IDL changes server-side without rebuilding the iOS app. Schema additions in the variant fields don't ripple into a generated `.proto` Swift binding.
- **Tooling cost.** No `grpc-swift` + `swift-protobuf` dependency, no codegen step, no proto file vendoring. Smaller binary, faster builds, simpler tests.
- **Operational consistency.** The same network primitive (URLSession) handles ingest, audio upload, and project/Lakebase reads.

The iOS-side stack is `URLSession` + `URLRequest` + `JSONEncoder`/`JSONDecoder`. The wire is `Content-Type: application/json` with `Authorization: Bearer <user-OAuth-token>` and a small set of typed request/response shapes.

### 7.2 Endpoint Resolution

The Databricks App's base URL is per-workspace and stable across sessions:

```
{appBaseURL} = {workspaceURL}/serving-endpoints/lakeloom-app/invocations   // or App-deployment URL
```

Exact URL convention is whatever Genie Code chooses for the App deployment — see `architecture/hi_genie/` for the contract document. For lakeLoom v1 we expect either a `/serving-endpoints/<name>/invocations`-style URL or a Databricks Apps URL (`https://<app-name>-<workspace>.databricksapps.com`).

`EndpointResolver` is a small actor that:
- Caches the resolved App base URL per `workspaceID` (7-day TTL; refresh on workspace credential update)
- On first use, derives the URL from a Settings-stored config or workspace-conf lookup (open item; see §16)

The full ingest URL is:

```
POST {appBaseURL}/api/v1/ingest/snippets
```

### 7.3 Authentication

OAuth bearer token in the `Authorization` header on every request:

```swift
request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
request.setValue(token.workspaceID, forHTTPHeaderField: "X-Databricks-Workspace-Id")
request.setValue(SchemaVersion.current, forHTTPHeaderField: "X-Lakeloom-Schema-Version")
```

The `X-Databricks-Workspace-Id` header lets the App route the call to the right downstream Zerobus stream when one App instance serves multiple workspaces. The `X-Lakeloom-Schema-Version` header is redundant with the body field but lets the App reject incompatible client versions early (HTTP 400) without parsing the full payload.

### 7.4 Wire Schema (JSON)

Each record on the wire mirrors the Zerobus columns (§3 of the architecture doc) but as JSON. The `headers` and `payload` VARIANTs are nested JSON objects (the App serializes them to JSON strings before handing to the Zerobus SDK).

**Request body** (`POST /api/v1/ingest/snippets`):

```json
{
  "schema_version": "1.0.0",
  "records": [
    {
      "record_uuid": "01975e4f-3a7c-7890-b1c2-d4e5f6a7b8c9",
      "session_id": "01975e4f-3a7c-7890-b1c2-d4e5f6a7b8aa",
      "project_id": "proj_01975e4f3a7c",
      "workspace_id": "1234567890123456",
      "username": "jhammond@acme.com",
      "user_uuid": "1234567890123456",
      "device_timestamp": "2026-05-06T18:14:22.331Z",
      "chunk_start_offset_ms": 0,
      "chunk_end_offset_ms": 6420,
      "capture_mode": "quick_capture",
      "sequence_number": 1,
      "event_type": "transcript_chunk",
      "headers": { /* variant headers per architecture §3.2 */ },
      "payload": { /* variant payload per architecture §3.3-3.6 */ }
    }
  ]
}
```

**Response body** (HTTP 200 / 207):

```json
{
  "accepted": ["01975e4f-3a7c-7890-b1c2-d4e5f6a7b8c9"],
  "rejected": [
    {
      "record_uuid": "01975e4f-3a7c-7890-b1c2-d4e5f6a7b8aa",
      "reason": "duplicate_record_uuid"
    }
  ],
  "ingest_timestamp": "2026-05-06T18:14:23.001Z"
}
```

HTTP status codes used:
- `200` — all records accepted
- `207 Multi-Status` — partial success; check the body
- `400` — request malformed or schema mismatch (body has `reason` field)
- `401` — token invalid/expired
- `403` — token valid but App rejects (downstream Zerobus permission denied)
- `413` — batch too large
- `429` — rate-limited (App returns `Retry-After` header)
- `500` — App bug
- `502/503/504` — App or downstream unavailable; transient

### 7.5 Batch POST API (Swift)

```swift
struct IngestProxyClient: Sendable {
    let urlSession: URLSession
    let encoder: JSONEncoder
    let decoder: JSONDecoder

    func postBatch(
        endpoint: AppEndpoint,
        token: AccessToken,
        body: IngestBatchBody
    ) async throws -> IngestBatchAck {
        let url = endpoint.url.appendingPathComponent("api/v1/ingest/snippets")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue(token.workspaceID, forHTTPHeaderField: "X-Databricks-Workspace-Id")
        request.setValue(SchemaVersion.current, forHTTPHeaderField: "X-Lakeloom-Schema-Version")
        request.timeoutInterval = 30
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw IngestProxyError.unknown("non-HTTP response")
        }

        switch http.statusCode {
        case 200, 207:
            return try decoder.decode(IngestBatchAck.self, from: data)
        case 400:
            let detail = decodeReason(data) ?? "bad_request"
            if detail.contains("schema") {
                throw IngestProxyError.schemaMismatch(detail)
            }
            throw IngestProxyError.badRequest(detail)
        case 401: throw IngestProxyError.unauthorized
        case 403: throw IngestProxyError.forbidden
        case 413: throw IngestProxyError.payloadTooLarge
        case 429: throw IngestProxyError.rateLimited(retryAfter: parseRetryAfter(http))
        case 500: throw IngestProxyError.internalServerError(decodeReason(data) ?? "")
        case 502, 503, 504: throw IngestProxyError.serverUnavailable
        default:
            throw IngestProxyError.unknown("http_\(http.statusCode)")
        }
    }
}

struct IngestBatchBody: Sendable, Codable {
    let schemaVersion: String
    let records: [IngestRecordJSON]
}

struct IngestBatchAck: Sendable, Codable {
    let accepted: [String]                    // record_uuids
    let rejected: [RejectedRecord]
    let ingestTimestamp: Date?

    struct RejectedRecord: Sendable, Codable {
        let recordUUID: String
        let reason: String
    }
}
```

The HTTP model means:
- A whole batch goes over a single POST. No streaming — Zerobus's streaming nature is hidden inside the App.
- Per-record acks are returned synchronously in the response body. Partial accept is the common case under high concurrency; the drainer handles it natively.
- A connection error fails the whole batch; records revert to pending and retry.
- A `cancel` from the OS (app backgrounded mid-flight) propagates as a `CancellationError`, which the drainer maps to `.canceled` and reverts the batch.

### 7.6 IngestProxyError Type

```swift
enum IngestProxyError: Error, Sendable, Equatable {
    case unauthorized                          // HTTP 401
    case forbidden                             // HTTP 403
    case badRequest(String)                    // HTTP 400
    case schemaMismatch(String)                // HTTP 400 with schema reason
    case payloadTooLarge                       // HTTP 413
    case rateLimited(retryAfter: Date?)        // HTTP 429
    case internalServerError(String)           // HTTP 500
    case serverUnavailable                     // HTTP 502/503/504
    case timeout                               // URLError.timedOut
    case badGateway                            // HTTP 502 specifically
    case networkUnavailable                    // URLError.notConnectedToInternet
    case canceled                              // CancellationError or URLError.cancelled
    case unknown(String)
}
```

Mapping from `URLError` and HTTP status codes is a single helper — kept inside `LiveIngestProxyClient` so tests can scriptably return any of these cases.

### 7.7 Timeouts and Limits

- Per-batch request timeout: 30 seconds (URLSession `timeoutIntervalForRequest`)
- Per-batch resource timeout: 60 seconds (URLSession `timeoutIntervalForResource`)
- Batch size: 50 records (tunable; small enough to retry cheaply, large enough to amortize connection cost)
- Per-record body size cap: 256 KB (enforced client-side; over-sized records are dead-lettered before send)
- Per-batch body size cap: 5 MB (defensive; in practice batches are tens of KB)

URLSession is configured once at IngestService startup with `URLSessionConfiguration.default`, `httpMaximumConnectionsPerHost = 4`, `waitsForConnectivity = true`, and default cookie policy disabled (we authenticate per-request via header).

---

## 8. Network Reachability

```swift
actor Reachability {
    private let monitor = NWPathMonitor()
    private(set) var currentPath: NetworkPath
    let pathChanges: AsyncStream<NetworkPath>

    init() {
        let (stream, continuation) = AsyncStream<NetworkPath>.makeStream()
        pathChanges = stream
        currentPath = NetworkPath.unknown
        monitor.pathUpdateHandler = { [weak self] path in
            let np = NetworkPath(path)
            Task { await self?.update(np, continuation: continuation) }
        }
        monitor.start(queue: .global(qos: .utility))
    }
}

struct NetworkPath: Sendable, Equatable {
    let isReachable: Bool
    let isConstrained: Bool
    let isExpensive: Bool
    let interfaceType: InterfaceType
    enum InterfaceType: String, Sendable { case wifi, cellular, wired, other, none }
}
```

IngestService treats *any* reachable path (Wi-Fi, cellular, wired) as good for sending transcript records. Audio uploads (StorageService) gate on Wi-Fi only — that's a separate decision in that module. Transcripts are tiny and we want them ingested promptly even on cellular.

---

## 9. CaptureEngine Integration

### 9.1 Subscription Pattern

At app launch, `IngestService.start()`:

1. Subscribes to `CaptureEngine.events`
2. Subscribes to `CaptureEngine` instance lifecycle (a fresh CaptureEngine after a workspace switch resets the subscription)
3. Spawns the drainer task

```swift
func start() async {
    if started { return }
    started = true
    Task { await self.subscribeToCaptureEvents() }
    Task { await self.runDrainerLoop() }
    Task { await self.runRetentionLoop() }
}

private func subscribeToCaptureEvents() async {
    for await event in capture.events {
        await handleCaptureEvent(event)
    }
}
```

### 9.2 Mapping Capture Events to Outbox Records

```swift
private func handleCaptureEvent(_ event: CaptureEvent) async {
    switch event {
    case .sessionStarted(let s):
        let record = OutboxRecord.fromSessionStarted(s)
        try? await outbox.enqueue([record])

    case .chunkFinalized(let chunk):
        let record = OutboxRecord.fromChunk(chunk)
        try? await outbox.enqueue([record])

    case .sessionEnded(let s):
        let record = OutboxRecord.fromSessionEnded(s)
        try? await outbox.enqueue([record])

    case .audioFileFinalized:
        // IngestService doesn't ingest audio bytes; StorageService handles upload.
        // The audio_uploaded event is emitted later by StorageService directly into IngestService.
        return

    case .warning, .error:
        // Logged for diagnostics; not forwarded to ZeroBus (could be a v1.x decision).
        return
    }
}
```

### 9.3 The `audio_uploaded` Event Injection

When StorageService completes an audio upload, it calls a dedicated entry point on IngestService:

```swift
extension IngestServicing {
    func enqueueAudioUploaded(_ event: AudioUploadedEvent) async
}
```

The implementation builds a `transcript_chunk`-shaped record with `event_type = "audio_uploaded"` and the appropriate payload, then enqueues to the outbox. Same drainer, same retry semantics, same ordering by `sequence_number`. The `sequence_number` for `audio_uploaded` events is allocated by IngestService at enqueue time as `(max sequence in session) + 1` to preserve the strict-monotonic invariant.

---

## 10. Crash Recovery

On `start()`, IngestService runs a recovery pass before activating the drainer:

```swift
private func runRecoveryPass() async {
    let now = Date()

    // 1. Revert any inflight records to pending (we lost the in-flight stream).
    let revertedCount = try? await outbox.markPendingForRetry(
        sessionID: nil,
        fromState: ["inflight"],
        now: now
    )
    log.info("Recovery: reverted \(revertedCount ?? 0) inflight records to pending")

    // 2. For sessions where session_start was sent but session_end was never enqueued,
    //    do nothing here — the silver pipeline will time out the session window if needed.
    //    CaptureEngine's own recovery may synthesize a session_end event with reason
    //    .interrupted, which we'll receive normally through the events subscription.

    // 3. Purge sent records older than retention.
    _ = try? await outbox.purgeSent(olderThan: now.addingTimeInterval(-86_400))
}
```

Inflight reversion is the critical piece: a force-quit during a gRPC write leaves records in `inflight` state. Without reversion they would never be retried. The dedup at the silver layer ensures double-sends are harmless.

---

## 11. UI Status Surfacing

### 11.1 Sessions List

The Sessions list view subscribes to `IngestService.status` and renders a row per session. Each row shows:
- Session start time, duration
- Project name
- Ingest status badge: `Sending` / `Waiting for Network` / `Sign in required` / `Complete` / `Needs attention`
- Counts: e.g., "47/48 sent"

A session row is "actionable" when `state == .partiallyFailed` — tapping reveals the dead-lettered records and a "Retry all" button that calls `retryDeadLettered(sessionID:)`.

### 11.2 Status Snapshot on Demand

`sessionStatus(sessionID:)` is a cheap synchronous-ish read backed by an in-actor cache that the drainer keeps current. The Sessions list uses snapshots for initial render and `status` events for live updates.

### 11.3 Diagnostics Screen

Settings → Diagnostics shows `IngestDiagnostics`:
- Lifetime sent / failed counts
- Current outbox depth, dead-letter depth
- Last successful send time
- Per-workspace stats
- A "Force flush" button that triggers an immediate drain cycle

---

## 12. Threading and Reentrancy

### 12.1 Single Drainer

There is exactly one drainer task. Concurrent calls to `start()` are no-ops after the first. The drainer task survives until `stop()` is called.

### 12.2 Outbox Concurrency

The outbox is a single actor. All writes serialize through it. CaptureEngine emits events on its own actor, but IngestService's subscriber task awaits the outbox actor for each enqueue. In practice this is fine because:
- Events arrive at most a few per second
- Core Data writes are sub-millisecond
- The outbox actor never holds locks across `await` points

### 12.3 Cancellation

`stop()` cancels the drainer task. In-flight gRPC calls are canceled cooperatively; any records in `inflight` revert to `pending` on next `start()` via the recovery pass.

---

## 13. Test Strategy

### 13.1 Unit Tests

- **OutboxStore:** enqueue/snapshot round trip; nextBatch ordering and batching; markInflight → markSent atomicity; markPendingForRetry semantics; concurrent writes
- **Drainer state machine:** transitions for each event type (network change, auth event, outbox change, backoff timer); idempotent state publishing
- **Backoff calculation:** monotonic growth, cap, jitter bounds
- **IngestProxy error mapping:** every `IngestProxyError` case maps to expected `BatchResult`; HTTP status code → error case lookup is exhaustive
- **Auth force-refresh inline retry:** second 401 → `.waitingForAuth`; second success → records sent
- **`audio_uploaded` enqueue:** sequence number assignment is strictly greater than all prior records in session

### 13.2 Integration Tests

- **End-to-end with mock App server:** real Core Data, a local HTTP test server scripted to return 200 / 207 / 401 / 503 / 429; verify records reach `sent` and counts match. Partial accept in 207 → some records `sent`, others dead-lettered.
- **Crash recovery:** kill the test process mid-batch (force-fault inside ZeroBusClient mock); on restart, verify inflight records revert to pending and are re-sent
- **Network flap:** toggle reachability mid-drain; drainer pauses on disconnect, resumes on reconnect, no duplicate sends within the same generation
- **Schema mismatch:** mock server returns HTTP 400 with `reason: "schema_mismatch"`; verify dead-letter and UI surfaces it
- **Auth expiry mid-drain:** access token expires between batches; AuthService refreshes silently; drainer continues without state hop

### 13.3 Test Seams

```swift
protocol OutboxStoring: Sendable { /* ... */ }
protocol IngestProxyClienting: Sendable { /* ... */ }
protocol Reachable: Sendable { /* ... */ }
protocol AuthServicing: Sendable { /* already defined in Module 01 */ }
protocol CaptureEventSource: Sendable { var events: AsyncStream<CaptureEvent> { get } }
```

Production: live implementations. Test: `InMemoryOutboxStore`, `ScriptedIngestProxyClient`, `ManualReachability` (test-driven path changes), `MockAuthService`, `ScriptedCaptureSource`.

---

## 14. Observability

- Structured logs at the boundary of every drain cycle: batch size, outcome, duration
- **No payload contents logged.** Headers/payload JSON is never logged; only counts and `record_uuid` prefixes
- Metrics counters surfaced via `IngestDiagnostics`:
  - `records.enqueued.total`
  - `records.sent.total`
  - `records.failed.total`
  - `records.dead_lettered.total`
  - `drain_cycles.total`
  - `auth.refresh.requested.total`
  - `auth.refresh.failed.total`
- Per-batch latency histogram (in-memory, 7-day retention) for the diagnostics screen
- A debug-only "ingest log" view in Settings that shows the last 100 drain cycles with their outcomes — turned off in release builds via compile-time flag

---

## 15. Out of Scope for v1

- **Compression of payloads on the wire.** ZeroBus may support gzip; a v1.x optimization. Records are small enough that bare TLS is fine.
- **Adaptive batch sizing.** Fixed at 50 in v1; tune from telemetry in v1.x.
- **Per-record priority lanes.** All records are equal priority. If a critical record needs to jump the queue, that's v1.x.
- **Cellular vs Wi-Fi-aware throttling for transcripts.** v1 sends transcripts on any reachable network. (Audio uploads are Wi-Fi-gated, but those are StorageService's domain.)
- **End-to-end encryption beyond TLS.** Bearer-token-over-TLS is the only auth/confidentiality layer.

---

## 16. Open Items

| # | Item | Resolution Path |
|---|---|---|
| 1 | Exact App ingest endpoint URL pattern — `/serving-endpoints/<name>/invocations` vs `https://<app>-<workspace>.databricksapps.com` | Decide with Genie Code on the App deployment shape; document in `architecture/hi_genie/` |
| 2 | App's response shape on partial accept — exact field names for `accepted` / `rejected` and per-record `reason` enum values | Lock the JSON contract in `architecture/hi_genie/`; add fixture to test suite |
| 3 | The target table identifier (catalog.schema.table) — encoded into the App's config, not the iOS client | Coordinate with the silver-pipeline team |
| 4 | Whether the App returns a server-side ingest timestamp per-record or per-batch | v1: per-batch is sufficient (silver pipeline doesn't need per-record receipt time) |
| 5 | Whether `403` from the App should pause the whole workspace's ingest until the user signs out and back in | Default v1: pause + notify; refine after seeing real failure modes |
| 6 | Maximum allowed body size (per-batch) at the App layer | Confirm with App team; client-side cap stays at 5 MB per batch / 256 KB per record |
| 7 | Retention default for `sent` outbox records (24h proposed) | Validate against typical user behavior; may extend to 7 days for diagnostic value |
| 8 | Whether to forward `CaptureEvent.warning` and `.error` to a separate Databricks telemetry table | Decide after Module 09 (telemetry) is designed |
| 9 | TLS cert pinning for the App endpoint | Default v1: standard system trust; revisit if customer security teams require it |

---

## 17. File Layout (proposed)

```
App/Ingest/
├── IngestService.swift                      // actor, public surface
├── IngestServicing.swift                    // protocol + value types + IngestError
├── IngestStatusEvent.swift
├── IngestDiagnostics.swift
├── Outbox/
│   ├── OutboxStore.swift                    // protocol
│   ├── LiveOutboxStore.swift                // Core Data implementation
│   ├── InMemoryOutboxStore.swift            // test impl
│   ├── OutboxRecord.swift                   // Core Data NSManagedObject + DTO
│   ├── OutboxChange.swift
│   └── CoreDataStack.swift                  // shared with StorageService
├── Drainer/
│   ├── Drainer.swift
│   ├── DrainerState.swift
│   ├── BatchResult.swift
│   ├── BackoffPolicy.swift
│   └── MergedEvents.swift
├── IngestProxy/
│   ├── IngestProxyClient.swift              // protocol
│   ├── LiveIngestProxyClient.swift          // URLSession + JSONEncoder/Decoder
│   ├── IngestProxyError.swift
│   ├── AppEndpoint.swift
│   ├── EndpointResolver.swift
│   ├── IngestBatchBody.swift                // Codable request body
│   ├── IngestBatchAck.swift                 // Codable response body
│   └── OutboxRecord+JSONRecord.swift        // OutboxRecord → wire JSON mapping
├── Reachability/
│   ├── Reachability.swift                   // protocol
│   ├── LiveReachability.swift               // NWPathMonitor
│   ├── ManualReachability.swift             // test impl
│   └── NetworkPath.swift
└── Capture/
    └── CaptureEventBridge.swift             // CaptureEvent → OutboxRecord mapping
```

Tests mirror this layout under `AppTests/Ingest/`.
