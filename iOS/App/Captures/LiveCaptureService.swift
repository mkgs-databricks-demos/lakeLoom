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
    /// Resolved per-device UUID, threaded into the create-capture body
    /// AND attached to each `PendingUpload` so multipart uploads carry
    /// it as a sibling form field. Optional so older tests that don't
    /// drive the identity-aware paths keep compiling.
    private let deviceIdentity: (any DeviceIdentityStore)?
    /// Optional on-device speech transcriber. When set together with
    /// `transcriptStreamer`, the finalize path kicks off a post-stop
    /// transcription Task that drains `final_transcript` events into
    /// ZeroBus while the audio file uploads in parallel. Both nil →
    /// no transcription, audio still uploads (back-compat with tests
    /// + the path where SpeechAnalyzer permission is denied).
    private let speechTranscriber: (any SpeechTranscriber)?
    /// Optional batching/retry pipe to ``TranscriptEventsClient``.
    /// Replaces the per-segment direct `sendEvent` calls from PR 8b
    /// with batched POSTs + retry classification. Same nil-tolerance
    /// as `speechTranscriber`.
    private let transcriptStreamer: (any TranscriptStreamer)?
    /// PR 9b: live during-recording speech recognizer. When wired
    /// alongside `audioBufferSource`, takes priority over the
    /// file-based `speechTranscriber` — segments emit as the user
    /// speaks rather than after stopCapture. The file-based path
    /// stays as a fallback when this is nil.
    private let streamingRecognizer: (any StreamingSpeechRecognizer)?
    /// PR 9b: source of live PCM buffers from the recorder. In
    /// production this is the same `EngineAudioRecordingEngine`
    /// instance that backs `LiveAudioRecorder`. Tests can leave it
    /// nil to use the file-based fallback.
    private let audioBufferSource: (any AudioBufferSource)?
    /// Workspace + paired-session resolver — the transcript events
    /// endpoint is `/api/sessions/<paired_session_id>/events`, so we
    /// need to know the active paired session at emit time without
    /// taking a dep on AppCoordinator. Production wiring supplies a
    /// closure; tests can omit (then transcript emission is skipped).
    private let pairedSessionIDProvider: (@Sendable () async -> String?)?
    private let logger: AppLogger
    private let nowProvider: @Sendable () -> Date
    private let uploadIDProvider: @Sendable () -> String
    private let fileHasher: @Sendable (URL) throws -> String
    /// Optional disk-persistent capture-context snapshot. Production
    /// wiring sets this; older tests that don't exercise the rehydrate
    /// path pass `nil` so they keep working unchanged.
    private let contextStore: CaptureContextStore?

    // MARK: State

    private var current: CaptureServiceState = .idle
    private var continuations: [UUID: AsyncStream<CaptureServiceState>.Continuation] = [:]
    private var watcherTask: Task<Void, Never>?
    private var didStart = false
    /// PR 9b: background Task draining the live recognizer's
    /// segment stream into TranscriptStreamer. Held so cancelCapture
    /// can cancel it and stopCapture can await it for an orderly
    /// drain before the upload is enqueued.
    private var liveStreamingTask: Task<Void, Never>?
    /// PR 9b: tracks whether live streaming was wired for the
    /// current capture. When true, we skip the file-based fallback
    /// in stopCapture (the live path already emitted segments).
    private var liveStreamingActive = false

    // MARK: Init

    public init(
        captureAPI: any CaptureAPIClient,
        recorder: any AudioRecorder,
        uploadCoordinator: any UploadCoordinator,
        contextStore: CaptureContextStore? = nil,
        deviceIdentity: (any DeviceIdentityStore)? = nil,
        speechTranscriber: (any SpeechTranscriber)? = nil,
        transcriptStreamer: (any TranscriptStreamer)? = nil,
        streamingRecognizer: (any StreamingSpeechRecognizer)? = nil,
        audioBufferSource: (any AudioBufferSource)? = nil,
        pairedSessionIDProvider: (@Sendable () async -> String?)? = nil,
        logger: AppLogger = AppLogger(category: .capture)
    ) {
        self.captureAPI = captureAPI
        self.recorder = recorder
        self.uploadCoordinator = uploadCoordinator
        self.contextStore = contextStore
        self.deviceIdentity = deviceIdentity
        self.speechTranscriber = speechTranscriber
        self.transcriptStreamer = transcriptStreamer
        self.streamingRecognizer = streamingRecognizer
        self.audioBufferSource = audioBufferSource
        self.pairedSessionIDProvider = pairedSessionIDProvider
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
        contextStore: CaptureContextStore? = nil,
        deviceIdentity: (any DeviceIdentityStore)? = nil,
        speechTranscriber: (any SpeechTranscriber)? = nil,
        transcriptStreamer: (any TranscriptStreamer)? = nil,
        streamingRecognizer: (any StreamingSpeechRecognizer)? = nil,
        audioBufferSource: (any AudioBufferSource)? = nil,
        pairedSessionIDProvider: (@Sendable () async -> String?)? = nil,
        logger: AppLogger = AppLogger(category: .capture),
        nowProvider: @Sendable @escaping () -> Date,
        uploadIDProvider: @Sendable @escaping () -> String,
        fileHasher: @Sendable @escaping (URL) throws -> String
    ) {
        self.captureAPI = captureAPI
        self.recorder = recorder
        self.uploadCoordinator = uploadCoordinator
        self.contextStore = contextStore
        self.deviceIdentity = deviceIdentity
        self.speechTranscriber = speechTranscriber
        self.transcriptStreamer = transcriptStreamer
        self.streamingRecognizer = streamingRecognizer
        self.audioBufferSource = audioBufferSource
        self.pairedSessionIDProvider = pairedSessionIDProvider
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
            // Rehydrate any in-flight capture from disk and reconcile
            // it against the upload queue (which has just rehydrated
            // inside `uploadCoordinator.start()`). Runs after the
            // queue is restored so we see the true terminal state of
            // each upload, not an empty queue.
            await recoverInFlightCapture()
        }
    }

    // MARK: - Recovery

    /// Reads the persisted snapshot (if any) and either patches the
    /// server-side session to its appropriate terminal state or
    /// re-attaches the upload watcher to drive the in-flight capture
    /// to completion.
    private func recoverInFlightCapture() async {
        guard let store = contextStore,
              let snapshot = await store.load() else {
            return
        }
        let context = CaptureContext(
            captureSessionID: snapshot.captureSessionID,
            projectID: snapshot.projectID,
            workspaceID: snapshot.workspaceID,
            startedAt: snapshot.startedAt
        )
        await logger.info(
            "capture.recover.start",
            metadata: [
                "capture_session_id": .uuidPrefix(context.captureSessionID),
                "phase": .string(snapshot.phase.rawValue),
                "pending_uploads": .int(Int64(snapshot.pendingUploadIDs.count))
            ]
        )
        switch snapshot.phase {
        case .recording:
            // App died with the recorder active. No uploads were
            // enqueued (the audio file may exist on disk but is
            // unfinalized and unsigned). Patch the server-side
            // session to `.cancelled` so the row never lingers
            // `.active` and clear the snapshot.
            await patchServerCancelled(context: context)
            await store.clear()
            await logger.info(
                "capture.recover.recording_orphan_cancelled",
                metadata: ["capture_session_id": .uuidPrefix(context.captureSessionID)]
            )

        case .finalizing:
            // App died after the recorder finalized + the uploads
            // were enqueued. The upload queue has rehydrated. Check
            // each persisted upload ID against the queue:
            //   - if all are `.succeeded` (or no longer present)
            //     → patch the server to `.completed`.
            //   - if any are still non-terminal → re-attach the
            //     watcher so the existing finalize flow drives the
            //     session to `.completed` once they drain.
            //   - if all remaining are terminally-failed → patch the
            //     server to `.completed` anyway and surface a
            //     warning; the user can retry the failed uploads
            //     manually from the smoke-test sheet / future UI.
            let allUploads = await uploadCoordinator.currentUploads()
            let stillInFlight = snapshot.pendingUploadIDs.filter { id in
                guard let upload = allUploads.first(where: { $0.id == id }) else {
                    // Queue store doesn't know about it anymore —
                    // treat as terminal (likely discarded).
                    return false
                }
                return !upload.state.isTerminal
            }
            if stillInFlight.isEmpty {
                await patchServerCompleted(context: context)
                await store.clear()
                await logger.info(
                    "capture.recover.finalizing_all_done_completed",
                    metadata: ["capture_session_id": .uuidPrefix(context.captureSessionID)]
                )
            } else {
                let pending = Set(stillInFlight)
                let stream = await uploadCoordinator.stateUpdates()
                transition(to: .finalizing(context, pendingUploadIDs: pending))
                await persistFinalizingIfNeeded(context: context, pending: pending)
                spawnWatcher(stream: stream, for: context, pendingUploadIDs: pending)
                await logger.info(
                    "capture.recover.finalizing_reattached_watcher",
                    metadata: [
                        "capture_session_id": .uuidPrefix(context.captureSessionID),
                        "remaining_uploads": .int(Int64(pending.count))
                    ]
                )
            }
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

        // Resolve device identity once. Used on the create body AND
        // attached to the audio PendingUpload at finalize. Failure
        // here is non-fatal (Genie's schema accepts nil) — we just
        // proceed without the field.
        let deviceID: String? = await resolvedDeviceID()

        let session: CaptureSession
        do {
            session = try await captureAPI.createCaptureSession(
                workspaceID: workspaceID,
                projectID: projectID,
                label: label,
                clientTimestamp: nowProvider(),
                deviceID: deviceID
            )
        } catch let error as CaptureAPIError {
            // Surface the network-unavailable case specifically so
            // the UI can render an offline-aware banner rather than
            // a stringified reason; everything else stays under the
            // generic `createSessionFailed`.
            switch error {
            case .networkUnavailable:
                transition(to: .failed(reason: "create: networkUnavailable"))
                throw CaptureServiceError.createSessionNetworkUnavailable
            default:
                transition(to: .failed(reason: "create: \(String(describing: error))"))
                throw CaptureServiceError.createSessionFailed(reason: String(describing: error))
            }
        } catch {
            transition(to: .failed(reason: "create: \(error.localizedDescription)"))
            throw CaptureServiceError.createSessionFailed(reason: error.localizedDescription)
        }

        // Server-side session exists from here. Any failure in the
        // remainder of `startCapture` must roll it back to .cancelled.
        do {
            _ = try await recorder.start(captureSessionID: session.id)
        } catch let error as AudioRecorderError {
            // Pull the permission-denied case out of the generic
            // bucket so the UI can render an "Open Settings"
            // affordance instead of a re-tap-the-Record-button
            // retry (which would fail with the same error).
            await rollbackServerSession(
                workspaceID: workspaceID,
                captureSessionID: session.id,
                because: "recorder.start: \(String(describing: error))"
            )
            switch error {
            case .permissionDenied:
                transition(to: .failed(reason: "recorder.start: permissionDenied"))
                throw CaptureServiceError.microphonePermissionDenied
            default:
                transition(to: .failed(reason: "recorder.start: \(String(describing: error))"))
                throw CaptureServiceError.recorderStartFailed(reason: String(describing: error))
            }
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
        await persistRecording(context: context)
        await logger.info(
            "capture.start.ok",
            metadata: [
                "capture_session_id": .uuidPrefix(session.id)
            ]
        )

        // PR 9b: kick off live during-recording transcription if a
        // streaming recognizer + buffer source are wired. Falls
        // through if either is nil — the existing file-based
        // transcribeAudioInBackground path fires from stopCapture
        // instead.
        await startLiveStreamingTranscription(context: context, deviceID: deviceID)
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
            // `cancelCapture` to clean up. Clear the snapshot so the
            // next launch doesn't try to recover an unrecoverable
            // state.
            transition(to: .failed(reason: "recorder.stop: \(String(describing: error))"))
            await contextStore?.clear()
            throw CaptureServiceError.recorderStopFailed(reason: String(describing: error))
        } catch {
            transition(to: .failed(reason: "recorder.stop: \(error.localizedDescription)"))
            await contextStore?.clear()
            throw CaptureServiceError.recorderStopFailed(reason: error.localizedDescription)
        }

        let sha: String
        do {
            sha = try fileHasher(recording.fileURL)
        } catch {
            transition(to: .failed(reason: "hash: \(error.localizedDescription)"))
            await contextStore?.clear()
            throw CaptureServiceError.hashingFailed(reason: error.localizedDescription)
        }

        let audioDeviceID = await resolvedDeviceID()
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
            deviceID: audioDeviceID,
            createdAt: nowProvider()
        )

        // Subscribe to the upload coordinator's state stream BEFORE
        // calling `enqueue`. The coordinator's `stateUpdates()` is
        // not buffered — once `enqueue` fires its initial `.queued`
        // event (and the worker loop continues straight into
        // `.uploading` / `.succeeded`), any of those transitions
        // delivered into an empty subscriber set are gone for good.
        //
        // The original v1 ordering subscribed *after* enqueue AND
        // after `await liveStreamingTask?.value`. For a fast upload
        // overlapping a slower recognizer drain (~1.5 s sleep), the
        // upload could land in `.succeeded` before the subscription
        // existed — the watcher would then wait forever, the server
        // never got patched to `completed`, the user's "uploading…"
        // UI never cleared, and the upload stayed in the queue
        // forever (re-restored every cold launch, eventually
        // accumulating into the double-digit `upload.queue.restored`
        // counts we observed on real device).
        let uploadStream = await uploadCoordinator.stateUpdates()

        do {
            try await uploadCoordinator.enqueue(pending)
        } catch let error as UploadCoordinatorError {
            transition(to: .failed(reason: "enqueue: \(String(describing: error))"))
            await contextStore?.clear()
            throw CaptureServiceError.enqueueFailed(reason: String(describing: error))
        } catch {
            transition(to: .failed(reason: "enqueue: \(error.localizedDescription)"))
            await contextStore?.clear()
            throw CaptureServiceError.enqueueFailed(reason: error.localizedDescription)
        }

        // Transcription handoff. PR 9b: when the live recognizer was
        // wired and started in startCapture (`liveStreamingActive`
        // == true), the recorder.stop() above has finished the
        // buffer stream, which causes the recognizer to call
        // request.endAudio() and deliver any final phrases. We
        // await the drain Task here so all live segments flush to
        // ZeroBus before stopCapture returns. The file-based
        // path is skipped in this case — the .m4a still uploads,
        // and Genie's Whisper pass produces the authoritative
        // transcript server-side.
        //
        // When live wasn't wired (older test paths, permission
        // denied at start, etc.), fall back to the file-based
        // transcribeAudioInBackground path the same way pre-9b
        // worked.
        if liveStreamingActive {
            await liveStreamingTask?.value
            liveStreamingTask = nil
            liveStreamingActive = false
        } else {
            transcribeAudioInBackground(
                fileURL: recording.fileURL,
                workspaceID: context.workspaceID,
                projectID: context.projectID,
                deviceID: audioDeviceID,
                startedAt: recording.startedAt
            )
        }

        transition(to: .finalizing(context, pendingUploadIDs: [pending.id]))
        await persistFinalizingIfNeeded(context: context, pending: [pending.id])
        spawnWatcher(stream: uploadStream, for: context, pendingUploadIDs: [pending.id])
    }

    public func cancelCapture() async throws {
        switch current {
        case .recording(let context):
            // PR 9b: tear down live transcription before cancelling
            // the recorder so the segment stream finishes cleanly
            // and the drain Task exits. Idempotent — calling stop()
            // multiple times is a no-op after the first.
            if liveStreamingActive {
                await streamingRecognizer?.stop()
                liveStreamingTask?.cancel()
                liveStreamingTask = nil
                liveStreamingActive = false
            }
            await recorder.cancel()
            await patchServerCancelled(context: context)
            transition(to: .cancelled(context))
            await contextStore?.clear()

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
            await contextStore?.clear()

        case .idle, .completed, .cancelled, .failed:
            throw CaptureServiceError.notRecording
        }
    }

    // MARK: - Private

    /// Fires a detached Task that transcribes the just-recorded
    /// `.m4a` and drains the resulting segment stream into the
    /// ``TranscriptStreamer``. The streamer handles batching, retry
    /// PR 9b: Starts live during-recording transcription. Returns
    /// without starting if any of the deps are nil — the file-based
    /// `transcribeAudioInBackground` path in stopCapture is the
    /// fallback. When this fires, `liveStreamingActive` is set so
    /// stopCapture skips the file-based path.
    private func startLiveStreamingTranscription(
        context: CaptureContext,
        deviceID: String?
    ) async {
        guard
            let streamingRecognizer,
            let audioBufferSource,
            let transcriptStreamer,
            let pairedSessionIDProvider
        else { return }

        guard let buffers = await audioBufferSource.buffers() else {
            await logger.warning(
                "speech.streaming.skipped",
                metadata: ["reason": .string("no buffer stream from recorder")]
            )
            return
        }

        guard let pairedSessionID = await pairedSessionIDProvider(), !pairedSessionID.isEmpty else {
            await logger.warning(
                "speech.streaming.skipped",
                metadata: ["reason": .string("no paired session id")]
            )
            return
        }

        let segments: AsyncThrowingStream<TranscriptSegment, Error>
        do {
            segments = try await streamingRecognizer.transcripts(buffers: buffers)
        } catch {
            await logger.warning(
                "speech.streaming.start_failed",
                metadata: ["reason": .string(String(describing: error))]
            )
            return
        }

        liveStreamingActive = true
        let recordingStartedAt = context.startedAt
        let workspaceID = context.workspaceID
        let projectID = context.projectID

        // Detached Task — drains segments through the
        // TranscriptStreamer (batches + retry) into ZeroBus. Stays
        // alive until the segment stream finishes naturally
        // (recognizer.endAudio() + final callback) or
        // cancelCapture cancels it.
        liveStreamingTask = Task { [logger] in
            await transcriptStreamer.stream(
                workspaceID: workspaceID,
                pairedSessionID: pairedSessionID,
                projectID: projectID,
                deviceID: deviceID,
                recordingStartedAt: recordingStartedAt,
                segments: segments,
                source: "on_device_live",
                model: "sf_speech_streaming_phrased",
                language: "en-US"
            )
            await logger.debug("speech.streaming.drain_complete")
        }
    }

    /// classification, and best-effort delivery — the capture
    /// service only owns the lifecycle (start, wait for end). Task
    /// is decoupled from the capture so transcription latency
    /// doesn't affect upload finalization.
    private func transcribeAudioInBackground(
        fileURL: URL,
        workspaceID: String,
        projectID: String,
        deviceID: String?,
        startedAt: Date
    ) {
        guard
            let speechTranscriber,
            let transcriptStreamer,
            let pairedSessionIDProvider
        else { return }

        let logger = self.logger

        Task { [logger] in
            guard let pairedSessionID = await pairedSessionIDProvider(),
                  !pairedSessionID.isEmpty else {
                await logger.warning(
                    "speech.transcribe.skipped",
                    metadata: ["reason": .string("no paired session id")]
                )
                return
            }

            let stream: AsyncThrowingStream<TranscriptSegment, Error>
            do {
                stream = try await speechTranscriber.transcribe(fileURL: fileURL, locale: nil)
            } catch {
                await logger.warning(
                    "speech.transcribe.start_failed",
                    metadata: ["reason": .string(String(describing: error))]
                )
                return
            }

            await transcriptStreamer.stream(
                workspaceID: workspaceID,
                pairedSessionID: pairedSessionID,
                projectID: projectID,
                deviceID: deviceID,
                recordingStartedAt: startedAt,
                segments: stream,
                source: "on_device",
                // Bumped from "sf_speech_recognizer" (PR 8b's
                // word-level emission) to "_phrased" so analytics on
                // transcript_events_raw can cleanly separate the
                // 25-events-per-recording word-level history from the
                // new pause-grouped phrase-level rows. Source stays
                // "on_device" — same engine, just different output
                // shape.
                model: "sf_speech_recognizer_phrased",
                language: "en-US"
            )
        }
    }

    /// Best-effort resolve of the stable device UUID. Failure logs
    /// but does not throw — the create-body and PendingUpload simply
    /// carry nil, which Genie's optional-during-rollout schema
    /// accepts. Returns nil only when the dep was omitted from init
    /// (older tests) or the keychain read fails.
    private func resolvedDeviceID() async -> String? {
        guard let deviceIdentity else { return nil }
        do {
            return try await deviceIdentity.deviceID()
        } catch {
            await logger.warning(
                "capture.device_id.resolve_failed",
                metadata: ["reason": .string(error.localizedDescription)]
            )
            return nil
        }
    }

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
                await persistFinalizingIfNeeded(context: context, pending: pending)
                if pending.isEmpty {
                    await patchServerCompleted(context: context)
                    transition(to: .completed(context))
                    await contextStore?.clear()
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

    // MARK: - Persistence helpers

    private func persistRecording(context: CaptureContext) async {
        guard let store = contextStore else { return }
        let snapshot = PersistedCaptureContext(
            captureSessionID: context.captureSessionID,
            projectID: context.projectID,
            workspaceID: context.workspaceID,
            startedAt: context.startedAt,
            phase: .recording,
            pendingUploadIDs: []
        )
        do {
            try await store.save(snapshot)
        } catch {
            await logger.warning(
                "capture.context.persist_failed",
                metadata: [
                    "phase": .string("recording"),
                    "reason": .string(error.localizedDescription)
                ]
            )
        }
    }

    private func persistFinalizingIfNeeded(
        context: CaptureContext,
        pending: Set<String>
    ) async {
        guard let store = contextStore else { return }
        let snapshot = PersistedCaptureContext(
            captureSessionID: context.captureSessionID,
            projectID: context.projectID,
            workspaceID: context.workspaceID,
            startedAt: context.startedAt,
            phase: .finalizing,
            // Stable order so the on-disk JSON byte representation
            // is deterministic across runs (helps when diffing or
            // hashing the snapshot file in tests).
            pendingUploadIDs: pending.sorted()
        )
        do {
            try await store.save(snapshot)
        } catch {
            await logger.warning(
                "capture.context.persist_failed",
                metadata: [
                    "phase": .string("finalizing"),
                    "reason": .string(error.localizedDescription)
                ]
            )
        }
    }
}
