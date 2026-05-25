import Foundation

/// Orchestrates the user-visible capture lifecycle: create the
/// server-side capture session, drive the audio recorder, hand the
/// finalized recording to the upload coordinator, and patch the
/// session to `.completed` once all uploads drain.
///
/// `CaptureService` is the single-entry-point for capture-related
/// UI actions. The home view's "Record" button maps directly to
/// ``startCapture(workspaceID:projectID:label:)`` and the in-session
/// "Stop" / "Cancel" buttons to ``stopCapture()`` /
/// ``cancelCapture()``.
///
/// Concurrency: implementations are `Sendable`; the live impl is
/// an actor that owns the in-flight capture context and the
/// background watcher Task that listens for upload completion.
///
/// **Persistence scope (MVP):** capture context lives in memory.
/// If the app is killed mid-capture, the `AudioRecorder`'s recording
/// is still on disk and the `UploadCoordinator` queue is restored
/// on next launch — but the server-side `capture_sessions` row will
/// stay `.active` until a future PR adds capture-session
/// rehydration on launch. The Module 02 spec doc captures this gap.
public protocol CaptureService: Sendable {

    /// Begin a new capture. Creates a server-side session, then
    /// starts local audio recording. Throws if a capture is already
    /// in progress, or if either the server call or the recorder
    /// fails (the server-side session is best-effort cancelled in
    /// the failure path).
    func startCapture(
        workspaceID: String,
        projectID: String,
        label: String?
    ) async throws

    /// Stop the active capture: finalize the audio file, hash it,
    /// enqueue it on the upload coordinator, and transition to
    /// ``CaptureServiceState/finalizing(_:pendingUploadIDs:)``. The
    /// background watcher patches the server-side session to
    /// `.completed` once the queue drains.
    func stopCapture() async throws

    /// Discard the active capture: stop the recorder without
    /// uploading, and patch the server-side session to `.cancelled`.
    /// If called from ``CaptureServiceState/finalizing(_:pendingUploadIDs:)``,
    /// in-flight uploads for this session are dropped from the queue.
    func cancelCapture() async throws

    /// Latest snapshot of the state machine.
    var state: CaptureServiceState { get async }

    /// Subscribe to state changes. Each call returns an independent
    /// stream; UI typically holds one for the life of the screen.
    func stateUpdates() async -> AsyncStream<CaptureServiceState>

    /// Bootstrap on app launch. Calls ``UploadCoordinator/start()``
    /// (idempotent) so the queue rehydrates and resumes draining.
    /// No-op for the in-memory capture state — see the type
    /// docstring on the persistence scope decision.
    func start() async

    /// Subscribe to live transcript segments emitted by the on-device
    /// speech recognizer during a `.recording` session. Each yield is
    /// a phrase-level ``TranscriptSegment`` produced by
    /// ``StreamingSpeechRecognizer`` at utterance boundaries; the same
    /// segments are batched in parallel to
    /// ``TranscriptStreamer``/ZeroBus for the durable side, so this
    /// stream is purely for in-session UX (the recording fullScreenCover
    /// scrolls them as they arrive).
    ///
    /// Each call returns an independent stream; UI typically holds
    /// one for the life of the recording cover. The stream completes
    /// when the recognizer finishes (capture stops or cancels), or
    /// when the subscriber drops it.
    func transcriptSegmentUpdates() async -> AsyncStream<TranscriptSegment>

    /// Capture a single photo and attach it to the active capture
    /// session. Presents the camera (delegated to ``PhotoCapture``),
    /// hashes the resulting JPEG, and enqueues it on the
    /// ``UploadCoordinator`` as a `.photo` upload bound to the
    /// current `captureSessionID`. The user can take multiple
    /// photos per session; each call produces an independent
    /// `PendingUpload`.
    ///
    /// Throws ``CaptureServiceError/notRecording`` if there's no
    /// active recording, ``CaptureServiceError/photoCaptureFailed``
    /// for camera permission / hardware / capture failures, and the
    /// existing hashing / enqueue errors otherwise.
    ///
    /// Photos enqueued during a session are tracked in the watcher's
    /// pending set at ``stopCapture()`` time so the server-side
    /// `state=completed` PATCH waits for all in-flight photo uploads
    /// to drain before firing (the server rejects uploads against
    /// non-active captures).
    func capturePhoto() async throws
}

/// State machine surfaced to the UI. Each non-`.idle` case carries
/// the ``CaptureContext`` so views can render breadcrumbs (project
/// name, started-at) without going back to the API client.
public enum CaptureServiceState: Sendable, Equatable, Hashable {
    case idle
    /// Capture session created server-side and recorder is writing
    /// audio to disk. User can `stopCapture` or `cancelCapture`.
    case recording(CaptureContext)
    /// Recorder is stopped; one or more uploads are in flight for
    /// this capture. The server-side session is still `.active` so
    /// the upload route accepts the multipart bodies. The watcher
    /// patches to `.completed` when `pendingUploadIDs.isEmpty`.
    case finalizing(CaptureContext, pendingUploadIDs: Set<String>)
    /// Server-side session has been patched to `.completed` and
    /// every upload reached `.succeeded`. UI surfaces a "Done"
    /// affordance; the next call to `startCapture` resets to
    /// `.recording`.
    case completed(CaptureContext)
    /// Server-side session has been patched to `.cancelled`. Local
    /// audio file (if any) has been removed from disk.
    case cancelled(CaptureContext)
    /// Recoverable error during start or stop. The caller can
    /// retry by calling `startCapture` again — the service drops
    /// back to `.idle` on the next successful start.
    case failed(reason: String)
}

/// Per-capture metadata pinned for the lifetime of a single capture.
public struct CaptureContext: Sendable, Equatable, Hashable {
    public let captureSessionID: String
    public let projectID: String
    public let workspaceID: String
    public let startedAt: Date

    public init(
        captureSessionID: String,
        projectID: String,
        workspaceID: String,
        startedAt: Date
    ) {
        self.captureSessionID = captureSessionID
        self.projectID = projectID
        self.workspaceID = workspaceID
        self.startedAt = startedAt
    }
}

/// Typed errors surfaced by ``CaptureService``.
public enum CaptureServiceError: Error, Sendable, Equatable {
    /// `startCapture` was called while another capture was in
    /// progress (any state other than `.idle` / `.completed` /
    /// `.cancelled` / `.failed`).
    case alreadyCapturing

    /// `stopCapture` / `cancelCapture` was called outside an
    /// `.recording` (or `.finalizing` for cancel) state.
    case notRecording

    /// The server-side `createCaptureSession` call failed; the
    /// recorder was never started. Forwarded reason from
    /// ``CaptureAPIError``.
    case createSessionFailed(reason: String)

    /// `createCaptureSession` failed specifically because the
    /// device had no working network. Surfaced as its own case
    /// (vs the generic `createSessionFailed`) so the UI can render
    /// a "You're offline — try again when you have a signal"
    /// affordance rather than a stack-trace-flavored reason
    /// string.
    case createSessionNetworkUnavailable

    /// The recorder failed to start. The server-side session has
    /// been best-effort patched to `.cancelled`.
    case recorderStartFailed(reason: String)

    /// The user denied microphone access. The server-side session
    /// has been best-effort patched to `.cancelled`. The UI should
    /// surface an "Open Settings" deep-link affordance rather than
    /// a re-tap-the-Record-button retry, since `Record` will fail
    /// with the same error until the user grants permission in
    /// Settings.
    case microphonePermissionDenied

    /// The recorder failed to finalize (e.g., engine threw on stop).
    /// The server-side session remains `.active`; the caller can
    /// call `cancelCapture` to clean it up.
    case recorderStopFailed(reason: String)

    /// Hashing the file failed (filesystem unreadable).
    case hashingFailed(reason: String)

    /// Enqueueing the upload failed (file missing, persistence error).
    case enqueueFailed(reason: String)

    /// Photo capture failed during a `.recording` session — camera
    /// permission denied, hardware unavailable, or capture path
    /// errored. Carries a stringified `PhotoCaptureError` so the UI
    /// can route permission-denied to Settings while surfacing the
    /// rest as generic failures.
    case photoCaptureFailed(reason: String)

    /// Photo capture was requested but the active wiring doesn't
    /// include a ``PhotoCapture`` dependency. Production wiring
    /// always supplies one; this is the safety net for tests that
    /// omit it.
    case photoCaptureUnavailable
}
