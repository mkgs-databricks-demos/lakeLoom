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
        logger: AppLogger = AppLogger(category: .ingest)
    ) {
        self.lakeloomApp = lakeloomApp
        self.queueStore = queueStore
        self.logger = logger
        self.nowProvider = Date.init
        self.sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
        self.multipartBoundaryProvider = { MultipartFormBuilder.makeBoundary() }
        self.maxAttempts = 5
        self.backoff = [2, 4, 8, 16, 32]
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
        backoff: [TimeInterval] = [2, 4, 8, 16, 32]
    ) {
        self.lakeloomApp = lakeloomApp
        self.queueStore = queueStore
        self.logger = logger
        self.nowProvider = nowProvider
        self.sleep = sleep
        self.multipartBoundaryProvider = multipartBoundaryProvider
        self.maxAttempts = maxAttempts
        self.backoff = backoff
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
        wake()
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
        wake()
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
        }
        if workerTask == nil {
            workerTask = Task { [weak self] in
                await self?.workerLoop()
            }
        }
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

        await logger.info(
            "upload.attempt.start",
            metadata: [
                "upload_id": .uuidPrefix(uploadID),
                "attempt": .int(Int64(upload.attempts))
            ]
        )

        do {
            try await sendOnce(upload: upload)
            upload.state = .succeeded
            upload.nextAttemptAt = nil
            uploads[uploadID] = upload
            try? FileManager.default.removeItem(at: upload.localFileURL)
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
                sha256Hex: upload.sha256Hex
            )
        } catch {
            // File disappeared from under us between enqueue and
            // upload (background eviction, user-initiated delete).
            // Surface as a permanent failure so we don't loop.
            throw LakeloomAppError.transport(reason: "file unreadable: \(error.localizedDescription)")
        }
        let path = "/api/captures/\(upload.captureSessionID)/\(upload.kind.endpointSuffix)"
        let contentType = MultipartFormBuilder.contentTypeHeaderValue(boundary: boundary)
        let data = try await lakeloomApp.requestRaw(
            workspaceID: upload.workspaceID,
            method: .post,
            path: path,
            body: body,
            contentType: contentType
        )
        // Server returns the inserted `app.uploads` row; capture the
        // remote ID if present so the UI can deep-link.
        if let response = try? JSONDecoder().decode(UploadResponse.self, from: data),
           let remoteID = response.id {
            if var live = uploads[upload.id] {
                live.remoteUploadID = remoteID
                uploads[upload.id] = live
            }
        }
    }

    private func handleFailure(upload: PendingUpload, error: LakeloomAppError) async {
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
        case .httpError(let status, _):
            switch status {
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
        case .httpError(let status, _): return "http_\(status)"
        case .decodeFailed:            return "decode_failed"
        }
    }

    // MARK: - Wake / persist / broadcast

    private func wake() {
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

    // MARK: - Decoding

    private struct UploadResponse: Decodable {
        let id: String?
    }
}
