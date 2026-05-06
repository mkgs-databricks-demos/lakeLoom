# Module 04 — StorageService

**Product:** Lakeloom
**Status:** Design — pre-implementation
**Last updated:** 2026-05-02
**Depends on:** AuthService (bearer tokens for upload + presigned URLs), CaptureEngine (audio file events), IngestService (to publish `audio_uploaded`), Core Data stack (shared with IngestService)
**Depended on by:** AppCoordinator (Sessions list rendering), Settings (storage diagnostics, manual purge)

---

## 1. Purpose

StorageService is the durable, network-aware manager of session audio files. It owns:

- The local filesystem layout under `<AppSupport>/sessions/`
- The upload state machine: `pending → wifi_waiting → uploading → uploaded → (deleted_after_grace)`, with `failed` and `dead_lettered` branches
- Wi-Fi gating via `NWPathMonitor`
- Background `URLSession` upload to Databricks Unity Catalog Volumes (or an equivalent presigned destination)
- Computing and verifying SHA-256 hashes
- Calling back to IngestService to enqueue the `audio_uploaded` ZeroBus event after successful upload
- Local retention policy and manual purge
- Recovery after app termination

StorageService does **not** own transcript ingestion (that's IngestService) or audio capture (that's CaptureEngine). It picks up `AudioFileEvent` from CaptureEngine, pushes the bytes to Databricks when Wi-Fi appears, and tells IngestService when it's done.

---

## 2. Design Principles

1. **Disk-first, network-second.** A captured audio file exists on disk before any upload is attempted. Files survive app crashes, OS jetsam, and indefinite offline periods.
2. **Wi-Fi gating is a hard rule, not advice.** Cellular uploads are blocked at the URLSession level (`allowsCellularAccess = false`), not just at the policy level. Even a bug elsewhere can't accidentally send audio over LTE.
3. **The platform owns retry timing.** `URLSession` with `isDiscretionary = true` lets iOS choose when to upload — it waits for Wi-Fi, plug-in power, low system load. We don't fight the OS scheduler.
4. **User override exists but is explicit.** A per-session "Upload over cellular now" action is the only path to bypass Wi-Fi. No global toggle that sets it as default in v1.
5. **Hash before upload, verify after.** SHA-256 is computed during recording (already by CaptureEngine) and again after upload server-side acknowledgment. Mismatches are dead-letter conditions.
6. **Idempotent upload.** The upload destination path is deterministic from `session_id`. Re-uploading the same file overwrites with identical bytes — safe under retry.
7. **Session record is the source of truth.** Core Data's `SessionRecord` row is authoritative for upload state. The filesystem can be re-derived from it on recovery.
8. **Grace period before deletion.** Audio is retained locally for a configurable window after successful upload (default 7 days). Deletion is asynchronous and resumable.
9. **Failure is observable.** Upload failures surface to the Sessions list with retry affordances; never silently dropped.
10. **No PII in filenames or paths.** Paths use `session_id` (UUIDv7) only — never username, project name, or transcript text.

---

## 3. Public Surface

### 3.1 Protocol

```swift
protocol StorageServicing: Sendable {
    /// Begin processing audio file events and managing the upload queue. Idempotent.
    /// Should be called once at app launch by AppCoordinator.
    func start() async

    /// Stop processing and gracefully drain in-flight work. Persisted state remains.
    func stop() async

    /// Stream of upload status changes. UI subscribes to render Sessions list.
    var status: AsyncStream<UploadStatusEvent> { get }

    /// Snapshot of upload status for a given session.
    func uploadStatus(sessionID: String) async -> SessionUploadStatus?

    /// All sessions with pending or in-flight uploads.
    func pendingUploads() async -> [SessionUploadStatus]

    /// Force a retry of a failed or dead-lettered upload.
    func retryUpload(sessionID: String) async throws

    /// Force an upload over cellular for a single session, bypassing Wi-Fi gate.
    func forceUploadOverCellular(sessionID: String) async throws

    /// Manually delete a session's local audio (e.g., user-initiated purge).
    /// Does not affect the remote copy.
    func purgeLocal(sessionID: String) async throws

    /// Aggregate storage diagnostics for Settings.
    func diagnostics() async -> StorageDiagnostics
}
```

### 3.2 Value Types

```swift
struct SessionUploadStatus: Sendable, Equatable {
    let sessionID: String
    let projectID: String
    let workspaceID: String
    let state: UploadState
    let localPath: URL?
    let localSizeBytes: Int64?
    let remotePath: String?              // Volume path or presigned URI
    let bytesUploaded: Int64
    let totalBytes: Int64
    let progress: Double                 // 0.0 ... 1.0
    let attemptCount: Int
    let lastError: String?
    let lastAttemptedAt: Date?
    let uploadedAt: Date?
    let deleteAfter: Date?               // when local file becomes eligible for purge
}

enum UploadState: String, Sendable {
    case pending                         // file finalized, decision pending
    case wifiWaiting                     // queued, awaiting Wi-Fi
    case uploading                       // active upload in progress
    case verifying                       // server ack received, verifying hash
    case uploaded                        // verified; awaiting grace-period delete
    case purged                          // local file deleted; remote retained
    case failed                          // transient failure; will retry
    case deadLettered                    // permanent failure; needs user action
    case noAudio                         // session had no audio (e.g., capture aborted before write)
}

enum UploadStatusEvent: Sendable {
    case enqueued(SessionUploadStatus)
    case stateChanged(SessionUploadStatus)
    case progressUpdated(sessionID: String, bytesUploaded: Int64, totalBytes: Int64)
    case completed(SessionUploadStatus)
    case failed(sessionID: String, error: UploadError, willRetry: Bool)
    case purged(sessionID: String)
}

enum UploadError: Error, Sendable, Equatable {
    case fileMissing                     // local file gone before upload
    case fileCorrupt(reason: String)     // hash mismatch on read
    case authFailed(reason: String)
    case networkUnavailable
    case wifiUnavailable                 // no Wi-Fi and not forced
    case rejectedByServer(httpStatus: Int, reason: String)
    case serverUnavailable(reason: String)
    case hashMismatch                    // server-computed hash differs from local
    case timeout
    case canceled
    case quotaExceeded                   // remote storage quota
    case unknown(reason: String)
}

struct StorageDiagnostics: Sendable {
    let localStorageUsedBytes: Int64
    let pendingUploadCount: Int
    let inFlightUploadCount: Int
    let deadLetteredCount: Int
    let totalUploadedLifetime: Int64
    let totalBytesUploadedLifetime: Int64
    let lastSuccessfulUploadAt: Date?
    let avgUploadDurationMs: Double?
    let perWorkspace: [String: WorkspaceStorageStats]
}

struct WorkspaceStorageStats: Sendable {
    let workspaceID: String
    let uploadsCompleted: Int64
    let bytesUploaded: Int64
    let lastUploadAt: Date?
}
```

---

## 4. Internal Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      StorageService (actor)                 │
└─────────────────────────────────────────────────────────────┘
       │             │            │             │             │
       ▼             ▼            ▼             ▼             ▼
┌───────────┐ ┌─────────────┐ ┌──────────┐ ┌──────────┐ ┌───────────┐
│ SessionRec│ │ FileVault   │ │ Reach-   │ │ Upload-  │ │ Retention │
│ ordStore  │ │ (filesystem │ │ ability  │ │ Coordin- │ │ Sweeper   │
│ (Core     │ │  layout)    │ │ (NWPath  │ │ ator     │ │           │
│  Data)    │ │             │ │  Wifi-   │ │ (URL-    │ │           │
│           │ │             │ │  gated)  │ │  Session │ │           │
│           │ │             │ │          │ │  back-   │ │           │
│           │ │             │ │          │ │  ground) │ │           │
└───────────┘ └─────────────┘ └──────────┘ └──────────┘ └───────────┘
       │
       └── shared CoreDataStack with IngestService
```

### 4.1 Concurrency Model

- `StorageService` is a Swift `actor`. Public method calls serialize through it.
- **SessionRecordStore** is a separate actor wrapping Core Data, sharing the persistent container with IngestService's outbox.
- **FileVault** is a value type (no mutable state) — it's a pure path/IO helper. Disk reads/writes are dispatched to a serial executor for ordered file ops within a session.
- **Reachability** is shared with IngestService (the Wi-Fi-aware variant) — same `NWPathMonitor` instance, two consumer policies.
- **UploadCoordinator** wraps a background `URLSession`. URLSession has its own delegate-driven thread; we bridge with continuations.
- **RetentionSweeper** runs as a low-priority `Task` on a 1-hour timer plus app-launch hook.

### 4.2 The Upload Coordinator

The most subtle piece. iOS background URLSessions have specific constraints:

- A background session is identified by a stable string identifier
- Only **one** background session per identifier per app — creating a second silently shadows the first
- Tasks survive app suspension and even termination (system restarts the app to deliver completion)
- Must implement `URLSessionDelegate.urlSessionDidFinishEvents(forBackgroundURLSession:)` to call the saved app-delegate background completion handler

Identifier: `com.<your-org>.lakeloom.storage.uploads`

URLSession configuration:
```swift
let config = URLSessionConfiguration.background(withIdentifier: identifier)
config.allowsCellularAccess = false                 // hard Wi-Fi gate
config.isDiscretionary = true                       // OS picks timing
config.sessionSendsLaunchEvents = true              // wake app on completion
config.shouldUseExtendedBackgroundIdleMode = false  // we're not a streaming app
config.timeoutIntervalForRequest = 60               // per-request
config.timeoutIntervalForResource = 24 * 3600       // 24h whole-resource
config.httpMaximumConnectionsPerHost = 2
config.waitsForConnectivity = true                  // wait, don't fail, on no-network
```

For force-cellular uploads, a *separate* foreground URLSession is used (not background) — it only runs while the app is open and explicitly bypasses the Wi-Fi gate.

### 4.3 The Upload State Machine

```
                    ┌─────────────┐
                    │   pending   │  ← AudioFileEvent received
                    └──────┬──────┘
                           │ Wi-Fi check
            ┌──────────────┼──────────────┐
            │ Wi-Fi yes    │              │ Wi-Fi no
            ▼              │              ▼
      ┌──────────┐         │      ┌──────────────┐
      │uploading │         │      │ wifiWaiting  │
      └────┬─────┘         │      └──────┬───────┘
           │               │             │ Wi-Fi appears
           │               │             ▼
           │               │       (loop back to uploading)
           │               │
           │ server ack    │
           ▼               │
      ┌─────────┐          │
      │verifying│          │
      └────┬────┘          │
           │               │
           │ hash ok       │ network err / 5xx
           ▼               ▼
      ┌─────────┐    ┌─────────┐
      │uploaded │    │ failed  │── retry budget exhausted ──► deadLettered
      └────┬────┘    └────┬────┘
           │              │ retry timer
           │              └──── back to wifiWaiting
           │ grace period
           ▼
      ┌─────────┐
      │ purged  │
      └─────────┘
```

Retries are bounded: 8 attempts with exponential backoff (same algorithm as IngestService — 1s base, 60s cap, ±25% jitter, doubled per attempt up to 6th). Beyond that, dead-letter.

---

## 5. SessionRecordStore — Persistent State

### 5.1 Core Data Entity

`SessionRecord` (the same entity referenced in the architecture doc, fleshed out):

```
SessionRecord
├── sessionID: String                [primary key, UUIDv7]
├── projectID: String                [indexed]
├── workspaceID: String              [indexed]
├── userUUID: String
├── username: String
├── captureMode: String              [quick_capture | meeting]
├── startedAt: Date                  [indexed]
├── endedAt: Date?
├── chunkCount: Int32
├── audioLocalRelativePath: String?  [path under sessions/, nil if no audio]
├── audioFormat: String?             [opus | aac]
├── audioSampleRate: Int32?
├── audioBitrate: Int32?
├── audioDurationMs: Int64?
├── audioSizeBytes: Int64?
├── audioSha256: String?
├── uploadState: String              [matches UploadState raw value]
├── uploadAttemptCount: Int32
├── uploadLastError: String?
├── uploadLastAttemptedAt: Date?
├── uploadStartedAt: Date?
├── uploadedAt: Date?
├── uploadBytesSent: Int64           [for progress reporting]
├── uploadTaskIdentifier: Int64?     [URLSession task ID, for resume]
├── remoteVolumePath: String?        [final UC Volume path]
├── deleteAfter: Date?               [grace period expiry]
├── purgedAt: Date?
└── deadLetteredAt: Date?
```

Indexes:
- `(uploadState, startedAt)` — primary query for the upload coordinator
- `(workspaceID, uploadState)` — diagnostics
- `(projectID)` — Sessions list grouping
- `(deleteAfter)` — retention sweep

### 5.2 Why a Separate Entity from OutboxRecord

`OutboxRecord` (Module 03) tracks transcript-event ingest. `SessionRecord` (this module) tracks session-level metadata and audio upload. They share `sessionID` but have different lifecycles:
- An OutboxRecord is per-event (many per session) and short-lived (purged 24h after sent)
- A SessionRecord is per-session (one per session) and long-lived (kept for 30+ days for the Sessions list)

A `SessionRecord` is created on `sessionStarted` and updated on `audioFileFinalized`, `sessionEnded`, and each upload state transition.

### 5.3 SessionRecordStore API

```swift
actor SessionRecordStore {
    func upsertOnSessionStart(_ event: SessionStartedEvent) async throws
    func updateOnAudioFinalized(_ event: AudioFileEvent) async throws
    func updateOnSessionEnd(_ event: SessionEndedEvent) async throws
    func transitionUploadState(
        sessionID: String,
        from: [UploadState],
        to: UploadState,
        mutating: ((inout SessionRecord) -> Void)?
    ) async throws -> SessionRecord
    func recordsInState(_ states: [UploadState]) async throws -> [SessionRecord]
    func record(sessionID: String) async throws -> SessionRecord?
    func purgeExpiredLocal(now: Date) async throws -> [SessionRecord]
    var changes: AsyncStream<SessionRecordChange> { get }
}
```

The `transitionUploadState` method is the workhorse — it enforces valid state transitions atomically and returns the updated record. Invalid transitions throw, surfacing programming errors loudly.

---

## 6. FileVault — Filesystem Layout

### 6.1 Directory Structure

```
<AppSupport>/
└── sessions/
    ├── <session_id_1>/
    │   ├── audio.opus               # finalized (or audio.opus.tmp during write)
    │   └── meta.json                # CaptureEngine-written metadata (state machine recovery)
    ├── <session_id_2>/
    │   └── ...
    └── recovery/                    # quarantined files from failed recovery passes
```

`<AppSupport>` is `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!`. The app creates this directory on first launch.

### 6.2 File Attributes

Every file written by FileVault has:
- `URLResourceValues.isExcludedFromBackup = true` — audio doesn't bloat iCloud backups
- File protection class `.completeUntilFirstUserAuthentication` — encrypted at rest, accessible after first unlock (matches token Keychain accessibility)

### 6.3 FileVault API

```swift
struct FileVault: Sendable {
    let baseURL: URL                        // <AppSupport>/sessions/

    func directoryURL(sessionID: String) -> URL
    func audioURL(sessionID: String) -> URL
    func tempAudioURL(sessionID: String) -> URL
    func metaURL(sessionID: String) -> URL

    func ensureDirectory(sessionID: String) throws
    func fileExists(sessionID: String) -> Bool
    func fileSize(sessionID: String) throws -> Int64
    func computeSHA256(sessionID: String) async throws -> String
    func deleteFile(sessionID: String) throws
    func deleteDirectory(sessionID: String) throws

    func listAllSessions() throws -> [String]
    func listOrphanedDirectories(knownSessionIDs: Set<String>) throws -> [String]
    func totalBytesUsed() throws -> Int64
    func quarantine(sessionID: String, reason: String) throws
}
```

### 6.4 Hash Verification

`computeSHA256` reads the file in 64 KB chunks, feeds them to `CryptoKit.SHA256`. Async to avoid blocking the actor on large files (a 30-min meeting at 16 kbps is ~3.6 MB — fast, but still better off the actor).

When CaptureEngine writes the file it produces a SHA-256 and stores it on the SessionRecord. StorageService re-verifies before upload (cheap insurance against bit rot) and the server returns its computed hash on success for end-to-end verification.

---

## 7. UploadCoordinator — Background URLSession

### 7.1 Initialization

The background URLSession must be created **at app launch**, before any `application(_:didFinishLaunchingWithOptions:)` background-launch dispatch arrives. iOS launches the app silently to deliver background URLSession events; if the session isn't recreated by the time delegate methods are called, those events are lost.

```swift
@main
struct LakeloomApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // ...
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: ...) -> Bool {
        // Eager create — this MUST happen on every launch, including background launches.
        _ = StorageService.shared
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        StorageService.shared.handleBackgroundURLSessionEvents(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}
```

### 7.2 The URLSession Delegate

```swift
final class UploadDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {
    weak var coordinator: UploadCoordinator?
    var pendingBackgroundCompletion: (() -> Void)?

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        Task { await coordinator?.taskDidComplete(task, error: error) }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        Task {
            await coordinator?.taskDidProgress(
                task,
                bytesSent: totalBytesSent,
                expected: totalBytesExpectedToSend
            )
        }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        Task { await coordinator?.taskDidReceiveData(dataTask, data: data) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // System has delivered all pending events for this session. Call the saved
        // completion handler so iOS knows we're done processing background work.
        DispatchQueue.main.async { [weak self] in
            self?.pendingBackgroundCompletion?()
            self?.pendingBackgroundCompletion = nil
        }
    }
}
```

### 7.3 Task <-> Session Mapping

Because URLSession tasks can outlive process state and be re-delivered on next launch, we cannot rely on in-memory mappings. Mapping is via:

- `URLSessionUploadTask.taskIdentifier` (Int) stored on `SessionRecord.uploadTaskIdentifier`
- On launch, `session.getAllTasks { tasks in ... }` enumerates surviving tasks; we reconcile with Core Data
- A task without a corresponding `SessionRecord` is canceled (orphan)
- A `SessionRecord` in `uploading` state without a corresponding task is reverted to `wifiWaiting` for re-upload

### 7.4 Upload Request Construction

For each session in `wifiWaiting`:

```swift
private func makeUploadRequest(for record: SessionRecord) async throws -> URLRequest {
    let token = try await auth.currentToken()
    let endpoint = try await uploadEndpoint(for: record)
    var request = URLRequest(url: endpoint)
    request.httpMethod = "PUT"
    request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
    request.setValue("audio/ogg; codecs=opus", forHTTPHeaderField: "Content-Type")
    request.setValue(record.audioSha256!, forHTTPHeaderField: "X-Content-SHA256")
    request.setValue(record.sessionID, forHTTPHeaderField: "X-Session-Id")
    request.setValue(record.workspaceID, forHTTPHeaderField: "X-Databricks-Workspace-Id")
    request.timeoutInterval = 60
    return request
}
```

### 7.5 Upload Endpoint

The audio destination is a Unity Catalog Volume path. The exact API surface depends on whether we use:

**Option A — Files API direct PUT.** `PUT /api/2.0/fs/files{path}` with body bytes. Simple, supported by background URLSession.

**Option B — Presigned URL.** App calls a Databricks endpoint to get a short-lived presigned URL, then uploads to that URL. Adds a round trip but decouples the upload from auth header constraints.

v1 ships **Option A** — direct PUT to the Files API. Simpler, fewer moving parts, works with the OAuth bearer we already have.

The destination path is deterministic:
```
/Volumes/{catalog}/{schema}/session_audio/{yyyy}/{mm}/{dd}/{session_id}.opus
```

`{catalog}.{schema}` is configured per workspace (open item — see §15) but defaults to `main.lakeloom`. Date partitioning helps the silver pipeline scan recent uploads efficiently.

### 7.6 Response Handling

```swift
private func taskDidComplete(_ task: URLSessionTask, error: Error?) async {
    guard let sessionID = sessionID(for: task) else { return }
    if let error {
        await handleNetworkError(sessionID: sessionID, error: error)
        return
    }
    guard let response = task.response as? HTTPURLResponse else {
        await markFailed(sessionID: sessionID, error: .unknown(reason: "no response"))
        return
    }
    switch response.statusCode {
    case 200, 201, 204:
        // Verify server-returned hash if present
        let serverHash = response.value(forHTTPHeaderField: "X-Content-SHA256")
        await handleUploadSuccess(sessionID: sessionID, serverHash: serverHash)
    case 401:
        await handleAuthFailure(sessionID: sessionID)
    case 403:
        await markDeadLettered(sessionID: sessionID,
                               error: .rejectedByServer(httpStatus: 403, reason: "forbidden"))
    case 413:
        await markDeadLettered(sessionID: sessionID,
                               error: .rejectedByServer(httpStatus: 413, reason: "payload too large"))
    case 429:
        await scheduleRetry(sessionID: sessionID,
                            delay: parseRetryAfter(response) ?? 60)
    case 500...599:
        await scheduleRetry(sessionID: sessionID, delay: nextBackoffDelay(sessionID))
    default:
        await markFailed(sessionID: sessionID,
                         error: .rejectedByServer(httpStatus: response.statusCode, reason: ""))
    }
}
```

### 7.7 Hash Verification After Upload

If the server returns `X-Content-SHA256` (or equivalent), compare to local. Mismatch → dead-letter with `.hashMismatch` (the file was corrupted somewhere in transit; safer to surface than silently retry).

If the server doesn't return a hash, we accept the success status code as authoritative. The client-side hash is still recorded on the SessionRecord for audit.

---

## 8. Wi-Fi Gating

### 8.1 Reachability Integration

StorageService subscribes to `Reachability.pathChanges`. The transition logic:

```swift
private func handlePathChange(_ path: NetworkPath) async {
    if path.interfaceType == .wifi && path.isReachable && !path.isConstrained {
        // Wi-Fi appeared — drain the queue
        await drainWifiWaiting()
    } else if !path.isReachable {
        // No network — pause (URLSession handles this internally with waitsForConnectivity,
        // but we still update UI state to wifiWaiting so users know)
        await markActiveUploadsAsWifiWaiting()
    }
    // Cellular without Wi-Fi: no action. The OS won't dispatch background tasks
    // because allowsCellularAccess = false, but URLSession queues them for when
    // Wi-Fi appears.
}
```

### 8.2 The `isConstrained` Check

iOS reports `isConstrained = true` for Low Data Mode and personal hotspots. We treat constrained Wi-Fi the same as cellular: don't upload. This is what users intuitively want — Low Data Mode means "don't sync big things."

### 8.3 Force Cellular Path

When the user taps "Upload now over cellular":

```swift
func forceUploadOverCellular(sessionID: String) async throws {
    guard let record = try await store.record(sessionID: sessionID) else {
        throw UploadError.unknown(reason: "session not found")
    }
    guard record.uploadState == .wifiWaiting || record.uploadState == .failed else {
        throw UploadError.unknown(reason: "session is not in a forceable state")
    }
    // Use the foreground URLSession (separate from the background one)
    try await foregroundUploader.upload(record: record, allowCellular: true)
}
```

The foreground uploader is a regular `URLSession.shared`-style configuration:
- `allowsCellularAccess = true`
- `isDiscretionary = false`
- Runs only while the app is foregrounded (we don't need background privileges for an explicit user action)
- Same delegate methods + state transitions as background uploader

If the app is backgrounded mid-cellular-upload, the task is canceled and the SessionRecord reverts to `wifiWaiting`. The user understands this — they tapped a button explicitly and expect immediate behavior.

---

## 9. Integration With Other Modules

### 9.1 CaptureEngine — Receiving Audio File Events

StorageService subscribes to `CaptureEngine.events` (a separate subscription from IngestService's; multicast supports it):

```swift
private func subscribeToCaptureEvents() async {
    for await event in capture.events {
        switch event {
        case .sessionStarted(let s):
            try? await store.upsertOnSessionStart(s)

        case .audioFileFinalized(let f):
            try? await onAudioFileFinalized(f)

        case .sessionEnded(let s):
            try? await store.updateOnSessionEnd(s)

        case .chunkFinalized, .warning, .error:
            // Not StorageService's concern.
            break
        }
    }
}

private func onAudioFileFinalized(_ event: AudioFileEvent) async throws {
    try await store.updateOnAudioFinalized(event)
    let path = NetworkPath.current
    if path.interfaceType == .wifi && path.isReachable && !path.isConstrained {
        try await beginUpload(sessionID: event.sessionID)
    } else {
        try await store.transitionUploadState(
            sessionID: event.sessionID,
            from: [.pending],
            to: .wifiWaiting,
            mutating: nil
        )
    }
}
```

### 9.2 IngestService — Publishing `audio_uploaded`

After a successful upload + hash verification, StorageService calls IngestService:

```swift
private func handleUploadSuccess(sessionID: String, serverHash: String?) async {
    let record = try await store.transitionUploadState(
        sessionID: sessionID,
        from: [.uploading, .verifying],
        to: .uploaded,
        mutating: { rec in
            rec.uploadedAt = Date()
            rec.deleteAfter = Date().addingTimeInterval(retentionGracePeriod)
        }
    )
    // Tell IngestService to enqueue the audio_uploaded ZeroBus event.
    let event = AudioUploadedEvent(
        sessionID: sessionID,
        audioURI: record.remoteVolumePath!,
        durationMs: record.audioDurationMs!,
        sizeBytes: record.audioSizeBytes!,
        sha256: record.audioSha256!,
        uploadedAt: record.uploadedAt!,
        uploadDurationMs: durationMs(record),
        uploadNetwork: "wifi"  // or "cellular" if forced
    )
    await ingest.enqueueAudioUploaded(event)
    publishStatus(.completed(snapshot(record)))
}
```

The `enqueueAudioUploaded` call is fire-and-forget from StorageService's perspective. IngestService takes it from there with its own outbox + retry. If IngestService fails to deliver the `audio_uploaded` event, that's its problem — the audio bytes are already in Databricks, and the event will eventually drain.

### 9.3 AuthService — Token and Workspace Routing

StorageService calls `auth.currentToken()` before each upload request. On 401, it calls `auth.currentToken(forceRefresh: true)` and retries once — same pattern as IngestService. On `AuthError.refreshFailed`, the upload moves to `failed` with reason "auth_failed" and the user is prompted to sign in.

Workspace pinning: an upload is bound to the workspace that was active when the audio was captured (stored on `SessionRecord.workspaceID`). Switching workspaces does **not** redirect pending uploads — they upload to the original workspace. The token used is whatever `auth.currentToken(workspaceID:)` returns for that workspace.

> Note: `auth.currentToken()` in Module 01 takes no workspace parameter (returns the active workspace's token). We need to either add a workspace-pinned variant or have StorageService temporarily switch the active workspace per upload. Open item — see §15.

---

## 10. Crash Recovery

### 10.1 Recovery Pass at Launch

`StorageService.start()` runs a recovery pass before activating subscriptions:

```swift
private func runRecoveryPass() async {
    let now = Date()

    // 1. Reconcile background URLSession tasks with SessionRecord state.
    let surviving = await uploadCoordinator.allRunningTasks()
    let recordsByTaskID = try await store.recordsWithTaskIDs(surviving.map(\.taskIdentifier))
    for task in surviving {
        if recordsByTaskID[task.taskIdentifier] == nil {
            // Orphan task — cancel.
            task.cancel()
        }
    }

    // 2. Records in `.uploading` without a surviving task → revert to wifiWaiting.
    let stuckUploading = try await store.recordsInState([.uploading])
    let survivingTaskIDs = Set(surviving.map(\.taskIdentifier))
    for record in stuckUploading where !survivingTaskIDs.contains(record.uploadTaskIdentifier ?? -1) {
        try await store.transitionUploadState(
            sessionID: record.sessionID,
            from: [.uploading],
            to: .wifiWaiting,
            mutating: { $0.uploadTaskIdentifier = nil }
        )
    }

    // 3. Records in `.verifying` (we received ack but didn't finish post-processing) →
    //    re-verify hash and either complete or revert.
    let stuckVerifying = try await store.recordsInState([.verifying])
    for record in stuckVerifying {
        await reverifyAndComplete(record)
    }

    // 4. Reconcile filesystem with Core Data:
    //    a. Files on disk with no SessionRecord → quarantine for diagnostic review.
    //    b. SessionRecords expecting a file but file is missing → mark .failed with .fileMissing.
    let knownSessionIDs = try await store.allKnownSessionIDs()
    let orphanDirs = try fileVault.listOrphanedDirectories(knownSessionIDs: Set(knownSessionIDs))
    for orphan in orphanDirs {
        try fileVault.quarantine(sessionID: orphan, reason: "no SessionRecord")
    }
    let expectingFile = try await store.recordsExpectingLocalFile()
    for record in expectingFile where !fileVault.fileExists(sessionID: record.sessionID) {
        try await store.transitionUploadState(
            sessionID: record.sessionID,
            from: [record.uploadState],
            to: .failed,
            mutating: { $0.uploadLastError = "file_missing" }
        )
    }
}
```

The reconciliation is the most important property: filesystem state, Core Data state, and URLSession state must agree at the end of the pass.

### 10.2 Background Launch Path

When iOS launches the app silently to deliver background URLSession events:

1. `AppDelegate` synchronously creates `StorageService.shared` (which constructs the background URLSession with the same identifier — the OS hands us the queued events)
2. `application(_:handleEventsForBackgroundURLSession:completionHandler:)` saves the completion handler on the upload delegate
3. URLSession delivers `urlSession(_:task:didCompleteWithError:)` callbacks for finished tasks
4. StorageService processes each completion, updates Core Data
5. URLSession calls `urlSessionDidFinishEvents(forBackgroundURLSession:)` — we invoke the saved completion handler
6. iOS suspends the app

This whole flow must complete within ~30 seconds of background-launch wake. We do no synchronous heavy work and never block the main thread.

---

## 11. Retention and Purge

### 11.1 Grace Period

After successful upload, the local file is retained for `deleteAfter = uploadedAt + 7 days` (default; configurable in Settings). The grace period exists for two reasons:
1. Server-side reprocessing might need to re-pull
2. User might want to inspect or share the audio offline

### 11.2 Sweeper

`RetentionSweeper` runs:
- At app launch (after recovery pass)
- On a 6-hour timer while the app is foregrounded
- After every successful upload (opportunistic check)

It queries `SessionRecord` where `uploadState == .uploaded AND deleteAfter <= now`, deletes the local file, and transitions to `.purged`.

### 11.3 Manual Purge

`purgeLocal(sessionID:)` is exposed for user-initiated deletion. Behavior:
- If state is `uploaded` or `purged`: delete the file, transition to `purged`, no remote impact
- If state is `pending` or `wifiWaiting` or `failed`: deleting locally means the audio is gone — show a strong confirmation. After confirm, delete file and transition to `purged` (the audio is just lost — there's no remote copy yet)
- If state is `uploading`: cancel the task first, then delete

### 11.4 Storage-Pressure Override

If local storage usage exceeds a threshold (default 500 MB across all sessions), the sweeper aggressively purges `uploaded` records oldest-first, even before their grace period expires. This prevents the app from filling the user's disk during heavy use.

The 500 MB number is configurable in Settings → Storage.

---

## 12. UI Status Surfacing

### 12.1 Sessions List Row

Each session shows:
- Date, time, duration, project name
- Upload state badge:
  - `pending` / `wifiWaiting` → "Waiting for Wi-Fi" with cloud-outline icon
  - `uploading` → "Uploading 45%" with progress
  - `uploaded` / `purged` → "Synced" with cloud-check icon
  - `failed` → "Will retry" (transient) with retry icon
  - `deadLettered` → "Upload failed — tap to retry" with warning icon
  - `noAudio` → no badge

Tapping a `failed` or `deadLettered` row reveals an action sheet with "Retry" / "Upload over cellular now" / "Delete local file".

### 12.2 Per-Session Detail

Shows full `SessionUploadStatus`:
- Local file path, size, sha256
- Remote path (if uploaded)
- Attempt count, last error
- Upload progress (live for `uploading`)
- Local file age, time until grace-period deletion

### 12.3 Settings → Storage

`StorageDiagnostics` rendered as:
- Total local storage used (e.g., "127 MB across 23 sessions")
- Pending/in-flight/dead-lettered counts
- Lifetime totals
- "Purge all uploaded" button (with confirmation)
- Retention grace period control (1, 7, 30 days, or "until upload confirmed")
- Storage-pressure threshold control

---

## 13. Threading and Reentrancy

- `StorageService` actor serializes public methods
- URLSession delegate callbacks happen on URLSession's internal queue; they hop into the actor via `Task { ... }`
- URLSession `getAllTasks(_:)` is async-callback-based; we wrap in `withCheckedContinuation`
- `start()` is idempotent; concurrent calls coalesce
- Grace-period sweep runs as a low-priority detached task; it doesn't block other actor work
- File I/O for hash computation is dispatched to a serial executor (not the actor's default executor) to avoid actor contention on a multi-MB read

---

## 14. Test Strategy

### 14.1 Unit Tests

- **SessionRecordStore:** state transitions for each valid path; invalid transitions throw; concurrent transitions serialize correctly
- **FileVault:** ensure-directory creates with correct attributes; SHA-256 matches reference values; orphaned-directory detection; quarantine moves files correctly
- **UploadCoordinator (with mock URLSession):** request construction includes correct headers; 401 triggers force-refresh path; 5xx schedules backoff; 4xx (other than 401, 429) dead-letters; progress updates flow to status stream
- **State machine:** every transition in §4.3 is exercised; retry budget enforces 8 attempts; backoff calculation matches IngestService's
- **Recovery pass:** orphaned tasks cancel; stuck `.uploading` reverts; missing files mark `.failed`
- **Wi-Fi gating:** `isConstrained = true` blocks; cellular blocks; force-cellular path uses foreground session

### 14.2 Integration Tests

- **End-to-end with mock UC Files API:** real Core Data, real FileVault on tmpdir, scripted HTTP server returning success / 401 / 503 / hash-mismatch; verify state progression and IngestService callback
- **Background launch simulation:** create background tasks, force-quit the test process, simulate iOS-redelivered events on relaunch; verify completion processing and completion handler invocation
- **Storage pressure:** populate >500 MB of fake `uploaded` records; verify sweeper purges oldest first
- **Force cellular:** set Wi-Fi state to unavailable; tap force; verify upload completes via foreground session
- **Crash mid-upload:** kill process during simulated upload; verify recovery reverts to `wifiWaiting` and re-uploads on next opportunity
- **Hash mismatch:** mock server returns wrong hash; verify dead-letter

### 14.3 Test Seams

```swift
protocol SessionRecordStoring: Sendable { /* ... */ }
protocol UploadCoordinating: Sendable { /* ... */ }
protocol FileVaulting: Sendable { /* ... */ }
protocol Reachable: Sendable { /* shared with IngestService */ }
```

Production: live implementations. Test: `InMemorySessionRecordStore`, `MockUploadCoordinator`, `EphemeralFileVault` (uses `URL.temporaryDirectory`).

---

## 15. Observability

- Structured logs at every state transition: `sessionID`, `from`, `to`, `attempt`, outcome
- **No file contents logged.** Path, size, hash prefix only
- Counters in `StorageDiagnostics`:
  - `uploads.started.total`
  - `uploads.completed.total`
  - `uploads.failed.total`
  - `uploads.dead_lettered.total`
  - `bytes.uploaded.total`
  - `recovery.orphans.cleaned`
  - `purges.local.total`
- Per-upload latency histogram for the diagnostics screen

---

## 16. Out of Scope for v1

- **Resumable uploads.** A 3.6 MB file uploads in seconds on Wi-Fi; resume support adds complexity for marginal benefit. v1.x if real-world data shows truncated uploads on flaky Wi-Fi.
- **Compression.** Opus is already heavily compressed. No additional gzip/zstd wrapping.
- **Client-side encryption.** TLS in transit + Databricks-side encryption at rest is sufficient for v1.
- **Concurrent multi-session uploads.** `httpMaximumConnectionsPerHost = 2` allows 2 concurrent, but in practice users won't have many sessions queued. Not a tuning priority.
- **Offline conflict resolution.** Audio files are write-once; no conflict scenarios.
- **CloudKit / iCloud sync.** Local-only by design; sessions sync via Databricks, not Apple.

---

## 17. Open Items

| # | Item | Resolution Path |
|---|---|---|
| 1 | Exact upload API: UC Files API direct PUT vs presigned URL flow | Test both against a Databricks workspace; pick simpler |
| 2 | UC Volume path convention (catalog.schema, partitioning) | Coordinate with silver-pipeline team |
| 3 | Whether server returns SHA-256 in response for verification | Verify with Databricks Files API docs; fall back to client-only hash if not |
| 4 | `auth.currentToken(workspaceID:)` API extension on AuthService for cross-workspace token retrieval | Add to Module 01 protocol; non-breaking |
| 5 | Whether file protection class `.completeUntilFirstUserAuthentication` is correct vs `.complete` | Test under locked-device scenarios; the former is more permissive (right for background uploads) |
| 6 | Default retention grace period (7 days proposed) | Validate with users; consider per-workspace policy |
| 7 | Storage-pressure threshold (500 MB proposed) | Telemetry-driven tuning post-v1 |
| 8 | Whether to support audio playback in v1 | Out of scope; revisit for Sessions detail UI in v1.x |
| 9 | Behavior when local file is corrupted (hash mismatch on read before upload) | v1: dead-letter immediately; alternative is to quarantine and surface to user |

---

## 18. File Layout (proposed)

```
App/Storage/
├── StorageService.swift                    // actor, public surface
├── StorageServicing.swift                  // protocol + value types + UploadError
├── UploadStatusEvent.swift
├── StorageDiagnostics.swift
├── SessionRecordStore/
│   ├── SessionRecordStore.swift            // protocol
│   ├── LiveSessionRecordStore.swift        // Core Data
│   ├── InMemorySessionRecordStore.swift    // test impl
│   ├── SessionRecord.swift                 // Core Data NSManagedObject + DTO
│   └── SessionRecordChange.swift
├── FileVault/
│   ├── FileVault.swift
│   ├── PathLayout.swift
│   └── HashComputer.swift
├── UploadCoordinator/
│   ├── UploadCoordinator.swift             // protocol
│   ├── LiveUploadCoordinator.swift
│   ├── BackgroundURLSessionFactory.swift
│   ├── ForegroundUploader.swift            // for force-cellular
│   ├── UploadDelegate.swift                // URLSession delegate
│   ├── UploadRequestBuilder.swift
│   ├── UploadEndpointResolver.swift
│   └── ResponseClassifier.swift
├── Retention/
│   ├── RetentionSweeper.swift
│   └── StoragePressureMonitor.swift
└── Recovery/
    └── StorageRecoveryPass.swift
```

Tests mirror this layout under `AppTests/Storage/`.
