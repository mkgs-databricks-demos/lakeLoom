# Module 03 — IngestService + ZeroBus Client

**Product:** Lakeloom
**Status:** Design — pre-implementation
**Last updated:** 2026-05-02
**Depends on:** AuthService (bearer tokens), CaptureEngine (event stream), shared `ZeroBusSchema.swift`
**Depended on by:** AppCoordinator (status surfacing), Settings (diagnostics, manual retry)

---

## 1. Purpose

IngestService is the durable, network-aware bridge between CaptureEngine's event stream and Databricks ZeroBus. It owns:

- Subscribing to `CaptureEngine.events` and persisting every event to a local **outbox** before any network call
- Sending records to ZeroBus over gRPC using OAuth bearer tokens from AuthService
- Retry, backoff, and dead-letter handling
- Surviving app termination — pending records are sent on the next launch
- Surfacing per-session ingest status to the UI

ZeroBusClient is the gRPC transport layer. It knows how to authenticate, how to format a write request, and how to interpret success/failure. It is stateless and replaceable; the durable behavior lives in IngestService.

IngestService does **not** own audio uploads (that's StorageService) or session state (that's CaptureEngine). It owns one thing: making sure every captured event lands in ZeroBus eventually, in order, exactly once from the silver pipeline's point of view.

---

## 2. Design Principles

1. **Outbox-first.** Every event is persisted to local storage before any network attempt. Memory-only is forbidden — a force-quit during transmission must not lose data.
2. **At-least-once delivery, deduped server-side.** ZeroBus is at-least-once. The silver pipeline dedupes on `record_uuid`. We never try to achieve exactly-once on the wire.
3. **Ordering preserved best-effort, not strictly.** Records carry `sequence_number` per session and the silver pipeline orders on it. The wire path is allowed to deliver out of order under retry, but in steady state it sends in order.
4. **The outbox survives anything short of a wiped device.** Process crash, OS jetsam, app update, reboot — pending records persist and resume.
5. **Auth is delegated.** IngestService never reads tokens from Keychain or refreshes them. It calls `AuthService.currentToken()` and reacts to typed `AuthError` results.
6. **Network-aware, not network-dependent.** No connectivity → records accumulate in the outbox. Connectivity returns → drain resumes automatically.
7. **Bounded retry with explicit dead-letter.** Records that fail permanently move to a dead-letter state, not silently dropped, and surface in Settings.
8. **One serialized writer.** Exactly one outbox-drain task runs at a time per app process. Concurrency is for buffering, not for parallelism on the wire.
9. **Failure is observable.** Every attempt is logged with structured fields. A diagnostics surface exposes counters per workspace/session.
10. **Schema-version-aware on send.** The `schema_version` field is set on every record from a single constant; mismatched server expectations surface as a typed error rather than silent rejection.

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
    case schemaMismatch(reason: String)          // server rejected our schema_version
    case payloadTooLarge(reason: String)
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
┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌────────────┐
│  Outbox     │  │  Drainer    │  │ ZeroBusCli- │  │ Network    │
│  (Core Data │  │  (single    │  │ ent (gRPC,  │  │ Reachabili-│
│   actor)    │  │   task,     │  │  Sendable)  │  │ ty (NWPath │
│             │  │   state     │  │             │  │  Monitor)  │
│             │  │   machine)  │  │             │  │            │
└─────────────┘  └──────┬──────┘  └──────┬──────┘  └─────┬──────┘
                        │                │               │
                        └─ pulls from Outbox             │
                        └─ awaits Reachability ──────────┘
                        └─ calls ZeroBusClient.write(...)
                        └─ updates Outbox on success/failure
                        └─ emits IngestStatusEvent
```

### 4.1 Concurrency Model

- `IngestService` is a Swift `actor`. Public method calls serialize through it.
- The **Outbox** is a separate actor wrapping Core Data. All reads/writes are async.
- The **Drainer** is a long-running `Task` owned by IngestService. There is exactly one drainer task per app process. It runs a state machine loop that pulls work from the outbox, sends it via ZeroBusClient, and updates the outbox.
- **Reachability** is a small actor wrapping `NWPathMonitor`. It exposes `currentPath: NetworkPath` and `pathChanges: AsyncStream<NetworkPath>`.
- **ZeroBusClient** is a `Sendable` struct (or final class with no mutable state). Stateless. Each `write` call constructs a fresh gRPC call.

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

ZeroBus accepts records one at a time over a streaming gRPC call. The drainer opens one stream per batch:

```swift
private func sendBatch(_ batch: [OutboxRecord], token: AccessToken) async -> BatchResult {
    let workspaceID = batch.first!.workspaceID
    // All records in a batch belong to the same workspace (the outbox query
    // groups by sessionID, and a session belongs to one workspace).

    let endpoint = try? await endpointResolver.resolve(workspaceID: workspaceID)
    guard let endpoint else {
        return .pause(.backingOff(until: Date().addingTimeInterval(30)))
    }

    do {
        try await zerobus.writeStream(endpoint: endpoint, token: token) { writer in
            for record in batch {
                try await writer.send(record.toIngestRecord())
            }
        }
        return .success(sentRecordUUIDs: batch.map(\.recordUUID))
    } catch let error as ZeroBusError {
        return mapZeroBusError(error, batch: batch)
    } catch {
        return .failure(error: .unknown(reason: error.localizedDescription), batch: batch)
    }
}
```

### 6.4 Error Mapping and Retry Logic

```swift
private func mapZeroBusError(_ error: ZeroBusError, batch: [OutboxRecord]) -> BatchResult {
    switch error {
    case .unauthenticated:
        // Try one force-refresh-and-retry inline before declaring auth failure.
        return .retryWithForceRefresh

    case .deadlineExceeded, .unavailable, .resourceExhausted:
        // Transient. Back off, retry the same batch.
        return .pause(.backingOff(until: nextBackoffDate()))

    case .invalidArgument(let detail):
        // Permanent for these records. Dead-letter them.
        return .deadLetter(reason: "invalid_argument: \(detail)", batch: batch)

    case .failedPrecondition(let detail) where detail.contains("schema"):
        // Schema mismatch. App needs an update. Dead-letter and surface loudly.
        return .deadLetter(reason: "schema_mismatch: \(detail)", batch: batch)

    case .permissionDenied:
        // User's token is valid but lacks ZeroBus write permission for this workspace.
        // Dead-letter; user-actionable through Databricks admin.
        return .deadLetter(reason: "permission_denied: \(error)", batch: batch)

    case .internalError(let detail):
        // Server bug. Back off harder; retry.
        return .pause(.backingOff(until: nextBackoffDate(multiplier: 2)))

    case .canceled:
        // We canceled (e.g., app backgrounded). Revert to pending.
        return .revert(batch: batch)
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

If the second attempt also gets `.unauthenticated`, we treat it as `waitingForAuth` (genuine refresh failure, user must re-login).

---

## 7. ZeroBusClient Implementation

### 7.1 gRPC Choice

Apple's official `grpc-swift` v2 (or v1, depending on minimum iOS version compatibility — v2 is iOS 17+, fine for iOS 26 target). HTTP/2 over TLS, certificate pinning to Databricks roots optional but not required for v1.

### 7.2 Endpoint Resolution

ZeroBus endpoints are workspace-specific. Format (subject to confirmation against Databricks docs):

```
{workspace_host}/zerobus/v1/streams/{table_path}
```

…or a separate gRPC host like `{workspace_host}` on port 443 with the path encoded in metadata. The exact wire format is one of the open items; the design here is shape-correct regardless.

`EndpointResolver` is a small actor that:
- Caches the resolved gRPC endpoint per workspace (refresh on workspace credential update or 7-day TTL)
- On first use, may call a discovery endpoint or compute the URL deterministically from `workspaceURL`

### 7.3 Authentication

OAuth bearer token in gRPC call metadata:

```swift
metadata.add(name: "authorization", value: "Bearer \(token.value)")
metadata.add(name: "x-databricks-workspace-id", value: token.workspaceID)
```

The workspace-id metadata header may or may not be required by the ZeroBus service — confirm during implementation. Including it is harmless if unused.

### 7.4 Wire Schema

ZeroBus accepts records into a registered table. The table schema mirrors §3 of the architecture doc. The wire representation in gRPC is a `WriteRecord` message with one field per top-level column plus serialized JSON strings for the variant fields.

Conceptual proto (exact field numbers TBD against ZeroBus IDL):

```proto
message WriteRecord {
  string record_uuid             = 1;
  string session_id              = 2;
  string project_id              = 3;
  string workspace_id            = 4;
  string username                = 5;
  string user_uuid               = 6;
  google.protobuf.Timestamp device_timestamp = 7;
  int64  chunk_start_offset_ms   = 8;
  int64  chunk_end_offset_ms     = 9;
  string capture_mode            = 10;
  int32  sequence_number         = 11;
  string event_type              = 12;
  string schema_version          = 13;
  string headers_variant_json    = 14;   // VARIANT serialized as JSON
  string payload_variant_json    = 15;   // VARIANT serialized as JSON
}

message WriteRequest {
  string table = 1;                       // catalog.schema.table
  WriteRecord record = 2;
}

message WriteResponse {
  string record_uuid = 1;
  google.protobuf.Timestamp ingest_timestamp = 2;
}

service ZeroBus {
  rpc Write(stream WriteRequest) returns (stream WriteResponse);
}
```

### 7.5 Streaming Write API (Swift)

```swift
struct ZeroBusClient: Sendable {
    let connection: GRPCChannel
    let table: String                        // "main.lakeloom.transcript_events"

    func writeStream(
        endpoint: ZeroBusEndpoint,
        token: AccessToken,
        body: @Sendable (StreamWriter) async throws -> Void
    ) async throws -> [WriteAck] {
        let metadata = buildMetadata(token: token)
        let acks = try await zerobusStub.write(metadata: metadata) { writer in
            let streamWriter = StreamWriter(grpc: writer, table: table)
            try await body(streamWriter)
            try await writer.finish()
        } onResponse: { response in
            // Collect acks
        }
        return acks
    }
}

actor StreamWriter {
    func send(_ record: WriteRecord) async throws { /* ... */ }
}
```

The streaming model means:
- A whole batch goes over a single gRPC call
- Acks come back as a stream — we collect them and validate `record_uuid` matches what we sent
- A single connection error fails the whole batch; records revert to pending and retry

### 7.6 ZeroBus Error Type

```swift
enum ZeroBusError: Error, Sendable {
    case unauthenticated                       // 401 / UNAUTHENTICATED
    case permissionDenied                      // PERMISSION_DENIED
    case invalidArgument(String)               // INVALID_ARGUMENT (schema/payload error)
    case failedPrecondition(String)            // FAILED_PRECONDITION (schema mismatch, etc.)
    case resourceExhausted                     // throttling
    case deadlineExceeded                      // timeout
    case unavailable                           // 5xx-equivalent
    case internalError(String)                 // server bug
    case canceled
    case unknown(String)
}
```

Standard gRPC status codes map to these one-to-one via a small helper.

### 7.7 Timeouts

- Per-record send: 10 seconds
- Whole-batch deadline: 60 seconds
- Batch size: 50 records (tunable; small enough to retry cheaply, large enough to amortize connection cost)

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
- **ZeroBus error mapping:** every `ZeroBusError` case maps to expected `BatchResult`
- **Auth force-refresh inline retry:** second 401 → `.waitingForAuth`; second success → records sent
- **`audio_uploaded` enqueue:** sequence number assignment is strictly greater than all prior records in session

### 13.2 Integration Tests

- **End-to-end with mock ZeroBus server:** real Core Data, mock gRPC server scripted to return success / 401 / 503; verify records reach `sent` and counts match
- **Crash recovery:** kill the test process mid-batch (force-fault inside ZeroBusClient mock); on restart, verify inflight records revert to pending and are re-sent
- **Network flap:** toggle reachability mid-drain; drainer pauses on disconnect, resumes on reconnect, no duplicate sends within the same generation
- **Schema mismatch:** mock server returns FAILED_PRECONDITION; verify dead-letter and UI surfaces it
- **Auth expiry mid-drain:** access token expires between batches; AuthService refreshes silently; drainer continues without state hop

### 13.3 Test Seams

```swift
protocol OutboxStoring: Sendable { /* ... */ }
protocol ZeroBusClienting: Sendable { /* ... */ }
protocol Reachable: Sendable { /* ... */ }
protocol AuthServicing: Sendable { /* already defined in Module 01 */ }
protocol CaptureEventSource: Sendable { var events: AsyncStream<CaptureEvent> { get } }
```

Production: live implementations. Test: `InMemoryOutboxStore`, `ScriptedZeroBusClient`, `ManualReachability` (test-driven path changes), `MockAuthService`, `ScriptedCaptureSource`.

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
| 1 | Exact ZeroBus gRPC IDL — proto field numbers, service definition, streaming semantics | Get Databricks ZeroBus proto file; align this design |
| 2 | Whether ZeroBus accepts streaming or unary writes for our volume | Likely streaming for batched throughput; confirm |
| 3 | Endpoint URL pattern for ZeroBus per workspace | Either deterministic from workspace host or discovery call; verify |
| 4 | The target table identifier (catalog.schema.table) and whether it's per-workspace or shared | Decide with the silver-pipeline team |
| 5 | Schema registration — does ZeroBus require pre-registering our top-level columns and accept variant freely? | Confirm; impacts whether `schemaVersion` gates evolution server-side |
| 6 | Whether `permission_denied` from ZeroBus should pause the whole workspace's ingest until the user signs out and back in | Default v1: pause + notify; refine after seeing real failure modes |
| 7 | Maximum allowed payload size (per-record + per-stream) | Confirm with ZeroBus docs; set conservative client-side cap (e.g., 256 KB per record) |
| 8 | Retention default for `sent` outbox records (24h proposed) | Validate against typical user behavior; may extend to 7 days for diagnostic value |
| 9 | Whether to forward `CaptureEvent.warning` and `.error` to a separate Databricks telemetry table | Decide after Module 06 (telemetry) is designed |

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
├── ZeroBusClient/
│   ├── ZeroBusClient.swift                  // protocol
│   ├── LiveZeroBusClient.swift              // grpc-swift implementation
│   ├── ZeroBusError.swift
│   ├── ZeroBusEndpoint.swift
│   ├── EndpointResolver.swift
│   ├── WriteRecord+Codable.swift            // OutboxRecord → WriteRecord mapping
│   └── proto/
│       └── zerobus.proto                    // generated Swift bindings
├── Reachability/
│   ├── Reachability.swift                   // protocol
│   ├── LiveReachability.swift               // NWPathMonitor
│   ├── ManualReachability.swift             // test impl
│   └── NetworkPath.swift
└── Capture/
    └── CaptureEventBridge.swift             // CaptureEvent → OutboxRecord mapping
```

Tests mirror this layout under `AppTests/Ingest/`.
