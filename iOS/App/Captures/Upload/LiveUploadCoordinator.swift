import Foundation

/// Production ``UploadCoordinator``. Owns the in-memory queue, the
/// worker loop, and the AsyncStream fan-out. Persistence is delegated
/// to ``UploadQueueStore``; transport is delegated to ``LakeloomAppClient``.
///
/// Worker model: one background `Task` picks queued uploads in FIFO
/// order, runs them serially, sleeps `nextAttemptAt - now` between
/// transient retries, and waits on a continuation when the queue is
/// empty. Serial-by-design — Genie's UC Volume layer is the ultimate
/// bottleneck; parallel uploads would only multiply the auth header
/// machinery without improving throughput meaningfully.
///
/// Retry policy:
/// - max **5** attempts
/// - exponential backoff: 2s, 4s, 8s, 16s, 32s
/// - 4xx (except 408, 429) → permanent failure, no retry
/// - 408 / 429 / 5xx / network / timeout → transient, retry
public actor LiveUploadCoordinator: UploadCoordinator {

    // MARK: Dependencies

    private let lakeloomApp: any LakeloomAppClient
    private let queueStore: UploadQueueStore
    private let logger: AppLogger
    private let nowProvider: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let multipartBoundaryProvider: @Sendable () -> String
    private let maxAttempts: Int
    private let backoff: [TimeInterval]
    /// Called with a capture session id when an upload to that session
    /// is rejected with 404 `UPLOAD_CAPTURE_NOT_FOUND` — the signal that
    /// the session's create op never landed. Wired in production to
    /// `OperationQueueing.reviveCreate(forCaptureSessionID:)` so a
    /// stalled create is re-driven mid-session (not only on cold start),
    /// breaking the June-2 stranded-audio deadlock without a relaunch.
    private let onCaptureNotFound: (@Sendable (String) async -> Void)?
    /// Fixed retry delay used for "no network" failures so we don't
    /// burn the maxAttempts retry budget against pure offline-state.
    /// Short enough that the upload drains promptly after reachability
    /// returns; long enough not to thrash CPU while offline.
    private let networkRetryDelay: TimeInterval

    // MARK: State

    /// Single source of truth for queue contents. Persisted to
    /// disk inside `save()`.
    private var uploads: [String: PendingUpload] = [:]
    /// Enqueue order — preserves FIFO when iterating the dict.
    private var order: [String] = []

    private var continuations: [UUID: AsyncStream<UploadStateChange>.Continuation] = [:]
    private var workerTask: Task<Void, Never>?
    private var wakeContinuation: CheckedContinuation<Void, Never>?
    private var didLoadFromDisk = false

    public init(
        lakeloomApp: any LakeloomAppClient,
        queueStore: UploadQueueStore,
        logger: AppLogger = AppLogger(category: .ingest),
        onCaptureNotFound: (@Sendable (String) async -> Void)? = nil
    ) {
        self.lakeloomApp = lakeloomApp
        self.queueStore = queueStore
        self.logger = logger
        self.nowProvider = Date.init
        self.sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
        self.multipartBoundaryProvider = { MultipartFormBuilder.makeBoundary() }
        self.maxAttempts = 5
        self.backoff = [2, 4, 8, 16, 32]
        self.networkRetryDelay = 5
        self.onCaptureNotFound = onCaptureNotFound
    }

    /// Test-friendly init: lets unit tests stub the clock, the sleep
    /// primitive (so backoff doesn't wall-clock the test runner), and
    /// the boundary generator (deterministic multipart bodies).
    init(
        lakeloomApp: any LakeloomAppClient,
        queueStore: UploadQueueStore,
        logger: AppLogger = AppLogger(category: .ingest),
        nowProvider: @Sendable @escaping () -> Date = Date.init,
        sleep: @Sendable @escaping (TimeInterval) async throws -> Void,
        multipartBoundaryProvider: @Sendable @escaping () -> String = { MultipartFormBuilder.makeBoundary() },
        maxAttempts: Int = 5,
        backoff: [TimeInterval] = [2, 4, 8, 16, 32],
        networkRetryDelay: TimeInterval = 5,
        onCaptureNotFound: (@Sendable (String) async -> Void)? = nil
    ) {
        self.lakeloomApp = lakeloomApp
        self.queueStore = queueStore
        self.logger = logger
        self.nowProvider = nowProvider
        self.sleep = sleep
        self.multipartBoundaryProvider = multipartBoundaryProvider
        self.maxAttempts = maxAttempts
        self.backoff = backoff
        self.networkRetryDelay = networkRetryDelay
        self.onCaptureNotFound = onCaptureNotFound
    }

    // MARK: Public surface

    public func enqueue(_ pending: PendingUpload) async throws {
        guard FileManager.default.fileExists(atPath: pending.localFileURL.path) else {
            throw UploadCoordinatorError.fileNotFound(path: pending.localFileURL.path)
        }
        if uploads[pending.id] != nil {
            throw UploadCoordinatorError.alreadyQueued(uploadID: pending.id)
        }
        uploads[pending.id] = pending
        order.append(pending.id)
        try await persist()
        await logger.info(
            "upload.queue.enqueued",
            metadata: [
                "upload_id": .uuidPrefix(pending.id),
                "capture_session_id": .uuidPrefix(pending.captureSessionID),
                "kind": .string(pending.kind.rawValue),
                "bytes": .int(pending.sizeBytes)
            ]
        )
        broadcast(uploadID: pending.id, state: pending.state)
        resumeWake()
    }

    public func currentUploads() async -> [PendingUpload] {
        order.compactMap { uploads[$0] }
    }

    public func stateUpdates() async -> AsyncStream<UploadStateChange> {
        let (stream, continuation) = AsyncStream<UploadStateChange>.makeStream()
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.unsubscribe(id: id) }
        }
        return stream
    }

    public func retry(uploadID: String) async {
        guard var upload = uploads[uploadID] else { return }
        upload.state = .queued
        upload.attempts = 0
        upload.nextAttemptAt = nil
        upload.lastError = nil
        uploads[uploadID] = upload
        try? await persist()
        broadcast(uploadID: uploadID, state: .queued)
        resumeWake()
    }

    public func discard(uploadID: String) async {
        guard let upload = uploads.removeValue(forKey: uploadID) else { return }
        order.removeAll { $0 == uploadID }
        try? FileManager.default.removeItem(at: upload.localFileURL)
        try? await persist()
        await logger.info(
            "upload.queue.discarded",
            metadata: ["upload_id": .uuidPrefix(uploadID)]
        )
        // Re-broadcast the upload's pre-discard state so subscribers
        // that mirror `currentUploads().count` (the home-page
        // pending-upload pill) re-snapshot and observe the entry's
        // removal. We deliberately don't add a `.discarded` case to
        // the enum — listeners that care about *presence/absence*
        // already snapshot the queue on every yield, and the
        // in-flight `LiveCaptureService.watchUploads` watcher's
        // `switch` over `.queued`/`.uploading`/`.failed` is a no-op
        // / safe-refresh on each, so re-broadcasting the pre-discard
        // state can't trick it into completing a session
        // prematurely.
        broadcast(uploadID: uploadID, state: upload.state)
    }

    public func start() async {
        if !didLoadFromDisk {
            let restored = await queueStore.load()
            for upload in restored {
                if uploads[upload.id] == nil {
                    uploads[upload.id] = revive(upload)
                    order.append(upload.id)
                }
            }
            didLoadFromDisk = true
            if !restored.isEmpty {
                await logger.info(
                    "upload.queue.restored",
                    metadata: ["count": .int(Int64(restored.count))]
                )
            }
            // File-integrity sweep over the just-restored set.
            // Uploads whose on-disk file is missing or empty after
            // restore are unrecoverable — `Data(contentsOf:)` would
            // throw at every retry and burn the budget for nothing.
            // Mark them terminal-failed with a typed reason so the
            // user sees an actionable "Discard" affordance in
            // PendingUploadsView instead of a row that keeps trying
            // forever. This is the most-likely root cause of the
            // "unreadable (new error)" the user hit on the wedged
            // session — pre-PR-#77 fixes, an interrupted upload was
            // restored, its file had been GC'd somewhere along the
            // way, and the retry kept failing with
            // `transport(reason: "file unreadable: ...")` until the
            // user manually discarded.
            await sweepMissingFiles()
        }
        if workerTask == nil {
            workerTask = Task { [weak self] in
                await self?.workerLoop()
            }
        }
    }

    /// Walk every restored upload still in `.queued` and validate
    /// its on-disk file. Missing or empty files get parked as
    /// terminal-failed with a typed reason. Files that exist but
    /// have shrunk since enqueue (truncated mid-write?) are logged
    /// but kept queued — the server's SHA-256 verification will
    /// catch any actual tampering, and we'd rather attempt the
    /// upload than discard data the user might want.
    private func sweepMissingFiles() async {
        let candidates = uploads.values.filter {
            if case .queued = $0.state { return true }
            return false
        }
        guard !candidates.isEmpty else { return }
        var missing = 0
        var empty = 0
        var shrunk = 0
        for upload in candidates {
            let path = upload.localFileURL.path
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            if attrs == nil {
                missing += 1
                await markTerminalCorrupt(upload: upload, reason: "file_missing")
                continue
            }
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            if size == 0 {
                empty += 1
                await markTerminalCorrupt(upload: upload, reason: "file_empty")
                continue
            }
            if size < upload.sizeBytes {
                shrunk += 1
                await logger.warning(
                    "upload.restore.file_shrunk",
                    metadata: [
                        "upload_id": .uuidPrefix(upload.id),
                        "persisted_bytes": .int(upload.sizeBytes),
                        "current_bytes": .int(size)
                    ]
                )
            }
        }
        if missing + empty + shrunk > 0 {
            await logger.info(
                "upload.restore.integrity_sweep",
                metadata: [
                    "missing": .int(Int64(missing)),
                    "empty": .int(Int64(empty)),
                    "shrunk": .int(Int64(shrunk))
                ]
            )
        }
    }

    /// Park `upload` as terminal-failed permanent with a structured
    /// reason. Helper for ``sweepMissingFiles`` so the failure shape
    /// is uniform: same `permanent: true` so the worker won't retry,
    /// same typed reason string for support-bundle grep.
    private func markTerminalCorrupt(upload: PendingUpload, reason: String) async {
        var updated = upload
        updated.state = .failed(reason: reason, permanent: true)
        updated.nextAttemptAt = nil
        updated.lastError = reason
        uploads[upload.id] = updated
        try? await persist()
        broadcast(uploadID: upload.id, state: updated.state)
        await logger.error(
            "upload.restore.file_corrupt",
            metadata: [
                "upload_id": .uuidPrefix(upload.id),
                "reason": .string(reason),
                "path": .string(upload.localFileURL.lastPathComponent)
            ],
            errorCode: reason
        )
    }

    public func stop() async {
        workerTask?.cancel()
        workerTask = nil
        resumeWake()
    }

    // MARK: - Worker loop

    private func workerLoop() async {
        while !Task.isCancelled {
            guard let next = pickNextEligible() else {
                await waitForWake()
                continue
            }
            if let nextAttemptAt = next.nextAttemptAt {
                let interval = nextAttemptAt.timeIntervalSince(nowProvider())
                if interval > 0 {
                    try? await sleep(interval)
                    if Task.isCancelled { break }
                }
            }
            await attempt(uploadID: next.id)
        }
    }

    private func pickNextEligible() -> PendingUpload? {
        for id in order {
            guard let upload = uploads[id] else { continue }
            switch upload.state {
            case .queued: return upload
            case .uploading, .succeeded, .failed: continue
            }
        }
        return nil
    }

    private func attempt(uploadID: String) async {
        guard var upload = uploads[uploadID] else { return }
        upload.state = .uploading
        upload.attempts += 1
        upload.lastError = nil
        uploads[uploadID] = upload
        try? await persist()
        broadcast(uploadID: uploadID, state: .uploading)

        // Snapshot the file's current on-disk state at the start of
        // each attempt. Diagnostic for the "unreadable" failure mode
        // we're chasing — if the file goes missing or shrinks
        // between attempts, the next support-bundle grep on
        // `upload.attempt.start` shows exactly when.
        let attrs = try? FileManager.default.attributesOfItem(atPath: upload.localFileURL.path)
        let currentSize = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        await logger.info(
            "upload.attempt.start",
            metadata: [
                "upload_id": .uuidPrefix(uploadID),
                "attempt": .int(Int64(upload.attempts)),
                "file_exists": .bool(attrs != nil),
                "current_bytes": .int(currentSize),
                "persisted_bytes": .int(upload.sizeBytes)
            ]
        )

        do {
            try await sendOnce(upload: upload)
            // Full retire on success: delete the local file, remove
            // the entry from both `uploads` and `order`, persist the
            // shrunken queue, THEN broadcast `.succeeded` so any
            // watcher (`LiveCaptureService.watchUploads`, the
            // capture-detail and pending-uploads views) sees the
            // terminal signal. Broadcasting after removal means a
            // watcher that calls `currentUploads()` in response to
            // the event sees the upload already gone — that's the
            // right behavior, since a `.succeeded` upload has nothing
            // left to do here.
            //
            // The original code only set `state = .succeeded` and
            // left the entry in the dict. That accumulated `.succeeded`
            // orphans in the persisted queue forever (every cold
            // launch saw `upload.queue.restored count=N` growing by
            // one per successful session) and showed them as
            // "Uploaded" rows in PendingUploadsView until the user
            // manually discarded them.
            try? FileManager.default.removeItem(at: upload.localFileURL)
            uploads.removeValue(forKey: uploadID)
            order.removeAll { $0 == uploadID }
            try? await persist()
            broadcast(uploadID: uploadID, state: .succeeded)
            await logger.info(
                "upload.attempt.ok",
                metadata: ["upload_id": .uuidPrefix(uploadID)]
            )
        } catch let error as LakeloomAppError {
            await handleFailure(upload: upload, error: error)
        } catch {
            await handleFailure(
                upload: upload,
                error: .transport(reason: error.localizedDescription)
            )
        }
    }

    private func sendOnce(upload: PendingUpload) async throws {
        let boundary = multipartBoundaryProvider()
        let body: Data
        do {
            body = try MultipartFormBuilder.build(
                boundary: boundary,
                fileURL: upload.localFileURL,
                filename: upload.originalFilename ?? upload.localFileURL.lastPathComponent,
                mimeType: upload.mimeType,
                clientTimestamp: upload.clientTimestamp,
                clientFilename: upload.originalFilename,
                sha256Hex: upload.sha256Hex,
                deviceID: upload.deviceID,
                // Chunk metadata is only meaningful for audio recordings
                // (PR A piece 4). Photos / screenshots / documents are
                // single whole files — leave the fields off so their
                // multipart bodies stay byte-identical to today.
                chunkIndex: upload.kind == .audio ? upload.chunkIndex : nil,
                isFinalChunk: upload.kind == .audio ? upload.isFinalChunk : nil,
                totalChunks: upload.kind == .audio ? upload.totalChunks : nil
            )
        } catch {
            // File disappeared from under us between enqueue and
            // upload (background eviction, user-initiated delete).
            // Surface as a permanent failure so we don't loop.
            throw LakeloomAppError.transport(reason: "file unreadable: \(error.localizedDescription)")
        }
        guard let path = upload.endpointPath() else {
            // PendingUpload was constructed inconsistently — e.g.,
            // a .document upload without a projectID. Permanent
            // failure: retrying won't fix it.
            throw LakeloomAppError.transport(
                reason: "no endpoint path for \(upload.kind.rawValue) upload \(upload.id)"
            )
        }
        let contentType = MultipartFormBuilder.contentTypeHeaderValue(boundary: boundary)
        let data = try await lakeloomApp.requestRaw(
            workspaceID: upload.workspaceID,
            method: .post,
            path: path,
            body: body,
            contentType: contentType
        )
        // Server returns the inserted `app.uploads` row (same shape
        // as the `uploads` array element in
        // `GET /api/captures/:id?include=uploads`). Decode using
        // CaptureUpload — it owns the lenient sizeBytes decoder
        // and the `client_ts_source` field, so a contract evolution
        // on either path is captured in one place.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let response = try? decoder.decode(CaptureUpload.self, from: data) {
            if var live = uploads[upload.id] {
                live.remoteUploadID = response.id
                uploads[upload.id] = live
            }
        }
        // Genie's chunk dedup (migration 021) returns the existing row
        // with `dedup_sha_mismatch: true` when a *different* file already
        // occupies this (capture_session_id, chunk_index) slot — the
        // server keeps the first file and drops ours. The HTTP status is
        // still a success (idempotent by design, her 2026-05-29 reply,
        // option b), but a SHA divergence means two genuinely different
        // files claimed one chunk slot — a recovery bug we want loud, not
        // silent. Clean idempotent retries (same file) carry the flag as
        // false and log nothing.
        if let signal = try? JSONDecoder().decode(DedupSignal.self, from: data),
           signal.shaMismatch {
            await logger.error(
                "upload.dedup.sha_mismatch",
                metadata: [
                    "upload_id": .uuidPrefix(upload.id),
                    "capture_session_id": .uuidPrefix(upload.captureSessionID),
                    "chunk_index": .int(Int64(upload.chunkIndex)),
                    "local_sha256": .string(upload.sha256Hex)
                ]
            )
        }
    }

    private func handleFailure(upload: PendingUpload, error: LakeloomAppError) async {
        // 404 `UPLOAD_CAPTURE_NOT_FOUND` for a capture-routed upload
        // means the session's create op never landed (the June-2 field
        // bug). Nudge the operation queue to revive that create so it's
        // re-driven mid-session, not only on the next cold start. The
        // upload itself still falls through to its normal transient
        // backoff below; by the time it retries, the revived create may
        // have created the session. Fire-and-forget — revival is
        // idempotent and a no-op once the create lands.
        if case .httpError(let status, _, _) = error,
           status == 404,
           upload.kind != .document {
            await onCaptureNotFound?(upload.captureSessionID)
        }

        // "No network reached the server" failures shouldn't burn the
        // retry budget — otherwise an offline session longer than
        // (sum of `backoff`) seconds parks the upload terminal-failed
        // forever, and reachability returning doesn't recover it.
        // Decrement the attempt counter (it was incremented at the top
        // of `attempt()`) and use a fixed short backoff so we don't
        // CPU-thrash while offline. `wake()` (wired to reachability
        // .online in LakeloomApp) and `enqueue()` both prod the worker
        // for any queued-and-waiting uploads.
        if isNetworkError(error) {
            let reason = String(describing: error)
            var updated = upload
            updated.attempts = max(0, upload.attempts - 1)
            updated.state = .queued
            updated.nextAttemptAt = nowProvider().addingTimeInterval(networkRetryDelay)
            updated.lastError = reason
            uploads[upload.id] = updated
            try? await persist()
            broadcast(uploadID: upload.id, state: .queued)
            await logger.warning(
                "upload.attempt.failed_network",
                metadata: [
                    "upload_id": .uuidPrefix(upload.id),
                    "retry_in_s": .double(networkRetryDelay),
                    "reason": .string(reason)
                ]
            )
            return
        }
        let permanent = isPermanent(error: error)
        let reason = String(describing: error)
        var updated = upload
        if permanent || upload.attempts >= maxAttempts {
            updated.state = .failed(reason: reason, permanent: permanent || upload.attempts >= maxAttempts)
            updated.nextAttemptAt = nil
            updated.lastError = reason
            uploads[upload.id] = updated
            try? await persist()
            broadcast(uploadID: upload.id, state: updated.state)
            await logger.error(
                "upload.attempt.failed_terminal",
                metadata: [
                    "upload_id": .uuidPrefix(upload.id),
                    "attempts": .int(Int64(upload.attempts)),
                    "reason": .string(reason)
                ],
                errorCode: errorCodeName(for: error)
            )
        } else {
            let delay = backoff[min(upload.attempts - 1, backoff.count - 1)]
            updated.state = .queued
            updated.nextAttemptAt = nowProvider().addingTimeInterval(delay)
            updated.lastError = reason
            uploads[upload.id] = updated
            try? await persist()
            broadcast(uploadID: upload.id, state: .queued)
            await logger.warning(
                "upload.attempt.failed_transient",
                metadata: [
                    "upload_id": .uuidPrefix(upload.id),
                    "attempts": .int(Int64(upload.attempts)),
                    "retry_in_s": .double(delay),
                    "reason": .string(reason)
                ]
            )
        }
    }

    /// Errors that mean "no network reached the server" — distinct
    /// from server-returned transient failures (404 race, 5xx, etc.)
    /// because they shouldn't count against the retry budget. The
    /// upload sits in fixed-delay re-queue until reachability returns.
    ///
    /// `.transport` is **not** included even though some transport
    /// failures are genuinely network-layer (DNS, connection refused).
    /// The `.transport` case is overloaded in `sendOnce`: it's also
    /// thrown for "file unreadable on disk" and "no endpoint path",
    /// which are permanent failures the user needs to clear. Counting
    /// `.transport` toward `maxAttempts` lets those legitimate
    /// permanent failures park after 5 attempts instead of looping
    /// forever; the trade-off is that a truly transient transport
    /// failure (rare) eats a budget slot.
    private func isNetworkError(_ error: LakeloomAppError) -> Bool {
        switch error {
        case .networkUnavailable, .timeout:
            return true
        case .transport, .tokenExchangeFailed, .unauthorized,
             .httpError, .decodeFailed, .workspaceNotConfigured:
            return false
        }
    }

    private func isPermanent(error: LakeloomAppError) -> Bool {
        switch error {
        case .networkUnavailable, .timeout:
            return false
        case .transport:
            return false
        case .tokenExchangeFailed, .unauthorized:
            // Auth errors are usually transient from the user's POV
            // (re-pair restores them) but won't fix on retry without
            // user action. Mark permanent so the worker stops and
            // surfaces it; AppCoordinator picks up the auth-failed
            // signal separately and routes to the QR re-scan.
            return true
        case .httpError(let status, _, let code):
            // Honor server-typed error codes first when present —
            // they carry intent the status code alone can't.
            // Mapping locked in
            // `architecture/hey_isaac/2026-05-20_audio-uploads-working.md`.
            if let typed = code.flatMap(UploadErrorCode.init(rawValue:)) {
                return typed.isPermanent
            }
            // Fallback by status: 408/429/5xx are transient; other
            // 4xx and unknown statuses are permanent.
            //
            // 404 is the Phase 3 special case: when iOS records
            // offline, the capture-create operation lands in
            // `OperationQueue` first and uploads land on
            // `UploadCoordinator` second. Both worker loops drain
            // concurrently when the network returns, and a fast
            // upload can race ahead of the create — the server then
            // returns 404 because the capture row doesn't exist yet.
            // Treating that as transient lets the upload back off
            // and re-attempt once the create has drained.
            switch status {
            case 404:             return false
            case 408, 429:        return false
            case 500...599:       return false
            case 400...499:       return true
            default:              return true
            }
        case .decodeFailed, .workspaceNotConfigured:
            return true
        }
    }

    private func errorCodeName(for error: LakeloomAppError) -> String {
        switch error {
        case .workspaceNotConfigured:  return "workspace_not_configured"
        case .networkUnavailable:      return "network_unavailable"
        case .timeout:                 return "timeout"
        case .transport:               return "transport"
        case .tokenExchangeFailed:     return "token_exchange_failed"
        case .unauthorized(let kind, _): return "unauthorized_\(kind.rawValue)"
        case .httpError(let status, _, let code):
            if let code, !code.isEmpty { return "http_\(status)_\(code)" }
            return "http_\(status)"
        case .decodeFailed:            return "decode_failed"
        }
    }

    // MARK: - Wake / persist / broadcast

    /// External nudge — used by LakeloomApp's reachability subscription
    /// to retry queued uploads immediately when the device comes back
    /// online. Clears any pending `nextAttemptAt` so the worker doesn't
    /// honor a stale offline-era backoff timer.
    public func wake() async {
        var changed = false
        for id in order {
            guard var upload = uploads[id] else { continue }
            if case .queued = upload.state, upload.nextAttemptAt != nil {
                upload.nextAttemptAt = nil
                uploads[id] = upload
                changed = true
            }
        }
        if changed {
            try? await persist()
        }
        resumeWake()
    }

    private func resumeWake() {
        guard let continuation = wakeContinuation else { return }
        wakeContinuation = nil
        continuation.resume()
    }

    private func waitForWake() async {
        if Task.isCancelled { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // If a wake was requested between checks, resume immediately.
            if Task.isCancelled {
                continuation.resume()
                return
            }
            self.wakeContinuation = continuation
        }
    }

    private func persist() async throws {
        let snapshot = order.compactMap { uploads[$0] }
        try await queueStore.save(snapshot)
    }

    private func broadcast(uploadID: String, state: PendingUpload.State) {
        let change = UploadStateChange(uploadID: uploadID, state: state)
        for continuation in continuations.values {
            continuation.yield(change)
        }
    }

    private func unsubscribe(id: UUID) {
        continuations[id] = nil
    }

    /// Re-hydrated uploads come back from disk with whatever state
    /// they were in at last save. If we crashed mid-upload, that's
    /// `.uploading` — flip it back to `.queued` so the worker
    /// retries on restart instead of hanging on a state we'll never
    /// transition out of.
    private func revive(_ upload: PendingUpload) -> PendingUpload {
        var revived = upload
        switch upload.state {
        case .uploading:
            revived.state = .queued
            revived.lastError = "interrupted by app termination"
        case .queued, .succeeded, .failed:
            break
        }
        return revived
    }
}
