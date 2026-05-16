import Foundation

/// Production ``CaptureService``. Owns:
///   - the in-flight capture context (one at a time)
///   - the AsyncStream fan-out for UI subscribers
///   - the background watcher Task that listens to the upload
///     coordinator and patches the server-side session to
///     `.completed` once every upload for the capture has
///     succeeded.
///
/// Failure semantics on `startCapture`: if either the server-side
/// session create or the recorder start throws, the actor restores
/// the state to `.failed` and (best-effort) patches the server-side
/// session to `.cancelled` so we never leave dangling `.active`
/// rows.
public actor LiveCaptureService: CaptureService {

    // MARK: Dependencies

    private let captureAPI: any CaptureAPIClient
    private let recorder: any AudioRecorder
    private let uploadCoordinator: any UploadCoordinator
    private let logger: AppLogger
    private let nowProvider: @Sendable () -> Date
    private let uploadIDProvider: @Sendable () -> String
    private let fileHasher: @Sendable (URL) throws -> String

    // MARK: State

    private var current: CaptureServiceState = .idle
    private var continuations: [UUID: AsyncStream<CaptureServiceState>.Continuation] = [:]
    private var watcherTask: Task<Void, Never>?
    private var didStart = false

    // MARK: Init

    public init(
        captureAPI: any CaptureAPIClient,
        recorder: any AudioRecorder,
        uploadCoordinator: any UploadCoordinator,
        logger: AppLogger = AppLogger(category: .capture)
    ) {
        self.captureAPI = captureAPI
        self.recorder = recorder
        self.uploadCoordinator = uploadCoordinator
        self.logger = logger
        self.nowProvider = Date.init
        self.uploadIDProvider = { UUID().uuidString }
        self.fileHasher = { url in try FileSHA256.hex(of: url) }
    }

    /// Test-friendly init. Lets unit tests pin the clock, generate
    /// deterministic upload IDs, and stub the hasher (so they don't
    /// have to write real fixture files).
    init(
        captureAPI: any CaptureAPIClient,
        recorder: any AudioRecorder,
        uploadCoordinator: any UploadCoordinator,
        logger: AppLogger = AppLogger(category: .capture),
        nowProvider: @Sendable @escaping () -> Date,
        uploadIDProvider: @Sendable @escaping () -> String,
        fileHasher: @Sendable @escaping (URL) throws -> String
    ) {
        self.captureAPI = captureAPI
        self.recorder = recorder
        self.uploadCoordinator = uploadCoordinator
        self.logger = logger
        self.nowProvider = nowProvider
        self.uploadIDProvider = uploadIDProvider
        self.fileHasher = fileHasher
    }

    // MARK: Public surface

    public var state: CaptureServiceState { current }

    public func stateUpdates() async -> AsyncStream<CaptureServiceState> {
        let (stream, continuation) = AsyncStream<CaptureServiceState>.makeStream()
        let id = UUID()
        continuations[id] = continuation
        // Replay the current state so a late subscriber doesn't sit
        // in `.idle` until the next transition.
        continuation.yield(current)
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.unsubscribe(id: id) }
        }
        return stream
    }

    public func start() async {
        if !didStart {
            await uploadCoordinator.start()
            didStart = true
        }
    }

    public func startCapture(
        workspaceID: String,
        projectID: String,
        label: String?
    ) async throws {
        try ensureCanStart()
        await start()

        await logger.info(
            "capture.start.attempt",
            metadata: [
                "workspace_id": .uuidPrefix(workspaceID),
                "project_id": .uuidPrefix(projectID)
            ]
        )

        let session: CaptureSession
        do {
            session = try await captureAPI.createCaptureSession(
                workspaceID: workspaceID,
                projectID: projectID,
                label: label,
                clientTimestamp: nowProvider()
            )
        } catch let error as CaptureAPIError {
            transition(to: .failed(reason: "create: \(String(describing: error))"))
            throw CaptureServiceError.createSessionFailed(reason: String(describing: error))
        } catch {
            transition(to: .failed(reason: "create: \(error.localizedDescription)"))
            throw CaptureServiceError.createSessionFailed(reason: error.localizedDescription)
        }

        // Server-side session exists from here. Any failure in the
        // remainder of `startCapture` must roll it back to .cancelled.
        do {
            _ = try await recorder.start(captureSessionID: session.id)
        } catch let error as AudioRecorderError {
            await rollbackServerSession(
                workspaceID: workspaceID,
                captureSessionID: session.id,
                because: "recorder.start: \(String(describing: error))"
            )
            transition(to: .failed(reason: "recorder.start: \(String(describing: error))"))
            throw CaptureServiceError.recorderStartFailed(reason: String(describing: error))
        } catch {
            await rollbackServerSession(
                workspaceID: workspaceID,
                captureSessionID: session.id,
                because: "recorder.start: \(error.localizedDescription)"
            )
            transition(to: .failed(reason: "recorder.start: \(error.localizedDescription)"))
            throw CaptureServiceError.recorderStartFailed(reason: error.localizedDescription)
        }

        let context = CaptureContext(
            captureSessionID: session.id,
            projectID: projectID,
            workspaceID: workspaceID,
            startedAt: nowProvider()
        )
        transition(to: .recording(context))
        await logger.info(
            "capture.start.ok",
            metadata: [
                "capture_session_id": .uuidPrefix(session.id)
            ]
        )
    }

    public func stopCapture() async throws {
        guard case .recording(let context) = current else {
            throw CaptureServiceError.notRecording
        }

        let recording: AudioRecording
        do {
            recording = try await recorder.stop()
        } catch let error as AudioRecorderError {
            // Recorder failed mid-stop. Leave the server-side session
            // `.active` and surface `.failed` — caller can invoke
            // `cancelCapture` to clean up.
            transition(to: .failed(reason: "recorder.stop: \(String(describing: error))"))
            throw CaptureServiceError.recorderStopFailed(reason: String(describing: error))
        } catch {
            transition(to: .failed(reason: "recorder.stop: \(error.localizedDescription)"))
            throw CaptureServiceError.recorderStopFailed(reason: error.localizedDescription)
        }

        let sha: String
        do {
            sha = try fileHasher(recording.fileURL)
        } catch {
            transition(to: .failed(reason: "hash: \(error.localizedDescription)"))
            throw CaptureServiceError.hashingFailed(reason: error.localizedDescription)
        }

        let pending = PendingUpload(
            id: uploadIDProvider(),
            workspaceID: context.workspaceID,
            captureSessionID: context.captureSessionID,
            kind: .audio,
            localFileURL: recording.fileURL,
            mimeType: recording.mimeType,
            sizeBytes: recording.sizeBytes,
            sha256Hex: sha,
            clientTimestamp: recording.startedAt,
            originalFilename: recording.fileURL.lastPathComponent,
            createdAt: nowProvider()
        )

        do {
            try await uploadCoordinator.enqueue(pending)
        } catch let error as UploadCoordinatorError {
            transition(to: .failed(reason: "enqueue: \(String(describing: error))"))
            throw CaptureServiceError.enqueueFailed(reason: String(describing: error))
        } catch {
            transition(to: .failed(reason: "enqueue: \(error.localizedDescription)"))
            throw CaptureServiceError.enqueueFailed(reason: error.localizedDescription)
        }

        // Subscribe to the upload coordinator's state stream
        // synchronously inside the actor BEFORE returning. That
        // guarantees the watcher has its subscription registered
        // by the time `stopCapture()` returns — otherwise the
        // upload coordinator could emit a `.succeeded` event into
        // an empty subscriber set and the watcher would wait
        // forever for a transition that already happened.
        let stream = await uploadCoordinator.stateUpdates()
        transition(to: .finalizing(context, pendingUploadIDs: [pending.id]))
        spawnWatcher(stream: stream, for: context, pendingUploadIDs: [pending.id])
    }

    public func cancelCapture() async throws {
        switch current {
        case .recording(let context):
            await recorder.cancel()
            await patchServerCancelled(context: context)
            transition(to: .cancelled(context))

        case .finalizing(let context, let pendingUploadIDs):
            // Stop the watcher first so it doesn't race with the
            // discards below.
            watcherTask?.cancel()
            watcherTask = nil
            for uploadID in pendingUploadIDs {
                await uploadCoordinator.discard(uploadID: uploadID)
            }
            await patchServerCancelled(context: context)
            transition(to: .cancelled(context))

        case .idle, .completed, .cancelled, .failed:
            throw CaptureServiceError.notRecording
        }
    }

    // MARK: - Private

    private func ensureCanStart() throws {
        switch current {
        case .idle, .completed, .cancelled, .failed:
            return
        case .recording, .finalizing:
            throw CaptureServiceError.alreadyCapturing
        }
    }

    private func transition(to newState: CaptureServiceState) {
        current = newState
        for continuation in continuations.values {
            continuation.yield(newState)
        }
    }

    private func unsubscribe(id: UUID) {
        continuations[id] = nil
    }

    private func rollbackServerSession(
        workspaceID: String,
        captureSessionID: String,
        because reason: String
    ) async {
        await logger.warning(
            "capture.start.rollback",
            metadata: [
                "capture_session_id": .uuidPrefix(captureSessionID),
                "reason": .string(reason)
            ]
        )
        _ = try? await captureAPI.updateCaptureSession(
            workspaceID: workspaceID,
            captureSessionID: captureSessionID,
            state: .cancelled,
            endedAt: nowProvider()
        )
    }

    private func patchServerCancelled(context: CaptureContext) async {
        do {
            _ = try await captureAPI.updateCaptureSession(
                workspaceID: context.workspaceID,
                captureSessionID: context.captureSessionID,
                state: .cancelled,
                endedAt: nowProvider()
            )
        } catch {
            await logger.warning(
                "capture.cancel.patch_failed",
                metadata: [
                    "capture_session_id": .uuidPrefix(context.captureSessionID),
                    "reason": .string(String(describing: error))
                ]
            )
        }
    }

    private func patchServerCompleted(context: CaptureContext) async {
        do {
            _ = try await captureAPI.updateCaptureSession(
                workspaceID: context.workspaceID,
                captureSessionID: context.captureSessionID,
                state: .completed,
                endedAt: nowProvider()
            )
        } catch {
            await logger.warning(
                "capture.complete.patch_failed",
                metadata: [
                    "capture_session_id": .uuidPrefix(context.captureSessionID),
                    "reason": .string(String(describing: error))
                ]
            )
        }
    }

    // MARK: - Watcher

    /// Spawn a Task that drains the already-subscribed upload state
    /// stream and removes upload IDs from `pendingUploadIDs` as they
    /// reach `.succeeded`. Once the set is empty, patches the
    /// server-side session to `.completed` and transitions to
    /// ``CaptureServiceState/completed(_:)``.
    ///
    /// The stream is established by the caller (``stopCapture``) so
    /// the subscription is in place before the caller's `await`
    /// returns; this prevents the race where the upload coordinator
    /// emits a `.succeeded` event before the watcher subscribes.
    private func spawnWatcher(
        stream: AsyncStream<UploadStateChange>,
        for context: CaptureContext,
        pendingUploadIDs initial: Set<String>
    ) {
        watcherTask?.cancel()
        watcherTask = Task { [weak self] in
            await self?.watchUploads(stream: stream, context: context, pendingUploadIDs: initial)
        }
    }

    private func watchUploads(
        stream: AsyncStream<UploadStateChange>,
        context: CaptureContext,
        pendingUploadIDs initial: Set<String>
    ) async {
        var pending = initial
        for await change in stream {
            if Task.isCancelled { return }
            guard pending.contains(change.uploadID) else { continue }
            switch change.state {
            case .succeeded:
                pending.remove(change.uploadID)
                refreshFinalizingState(context: context, pending: pending)
                if pending.isEmpty {
                    await patchServerCompleted(context: context)
                    transition(to: .completed(context))
                    return
                }
            case .failed(_, let permanent):
                // Permanent failures park the upload in the queue
                // for the user to retry/discard via UI. Stay in
                // `.finalizing` until they take action; the watcher
                // keeps listening so a manual `retry` that succeeds
                // still completes the session.
                if permanent {
                    refreshFinalizingState(context: context, pending: pending)
                }
            case .queued, .uploading:
                continue
            }
        }
    }

    /// Re-emit `.finalizing` with the latest `pendingUploadIDs` so UI
    /// subscribers see the count decrement live.
    private func refreshFinalizingState(context: CaptureContext, pending: Set<String>) {
        if case .finalizing(let ctx, _) = current, ctx == context {
            transition(to: .finalizing(context, pendingUploadIDs: pending))
        }
    }
}
