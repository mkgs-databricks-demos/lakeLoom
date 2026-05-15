import Foundation

/// Local audio recorder for a single capture session.
///
/// Recording is the *first* leg of the capture pipeline. iOS records
/// to disk first (M4A/AAC), then the future ``UploadCoordinator``
/// reads the finalized file and ships it to the Databricks App's
/// upload endpoint. That split survives flaky networks: a recording
/// that completes while offline still lands on disk and uploads when
/// connectivity returns.
///
/// Lifecycle:
/// 1. Caller obtains a ``CaptureSession`` from ``CaptureAPIClient``.
/// 2. Caller invokes ``start(captureSessionID:)`` with that session's
///    `id`. The recorder activates `AVAudioSession`, requests mic
///    permission if not yet determined, and begins writing to disk.
/// 3. Caller invokes ``stop()`` to finalize. The returned
///    ``AudioRecording`` carries the URL + metadata the upload layer
///    needs.
/// 4. To abandon a recording, ``cancel()`` stops the engine and
///    deletes the partial file.
///
/// Concurrency: implementations must be `Sendable`; the live impl is
/// an actor.
public protocol AudioRecorder: Sendable {

    /// Start recording. Returns the URL the recording will be
    /// written to (useful for UI that wants to show a live file
    /// path or for testing). The file is incomplete until
    /// ``stop()`` returns.
    func start(captureSessionID: String) async throws -> URL

    /// Stop the active recording and finalize the file. Returns the
    /// closed ``AudioRecording`` for hand-off to the uploader.
    /// Throws ``AudioRecorderError/notRecording`` if no recording
    /// is in progress.
    func stop() async throws -> AudioRecording

    /// Stop without keeping the file. Deletes the partial recording
    /// on disk. No-op when idle.
    func cancel() async

    /// Current state — exposed for UI binding and for the capture
    /// flow to enforce "only one recording at a time."
    var state: AudioRecorderState { get async }
}

/// State machine for a recorder. Only two states because the
/// recorder is single-shot: callers create a new recording per
/// capture session.
public enum AudioRecorderState: Sendable, Equatable {
    case idle
    case recording(captureSessionID: String, startedAt: Date)
}

/// Finalized recording handed to the upload layer.
///
/// The fields here map 1:1 to the metadata the future
/// `POST /api/captures/:capture_session_id/uploads` endpoint will
/// need (per Genie's wire-format contract). Keep them in sync with
/// the server-side schema in
/// `lakeloom-ai/server/routes/captures/upload-routes.ts`.
public struct AudioRecording: Sendable, Equatable, Hashable {
    public let captureSessionID: String
    public let fileURL: URL
    public let startedAt: Date
    public let endedAt: Date
    public let durationSeconds: Double
    public let sizeBytes: Int64
    /// Always `"audio/mp4"` — AAC inside an M4A container. iOS's
    /// default `AVAudioRecorder` settings, which Genie's server-side
    /// accept-list explicitly allows.
    public let mimeType: String
    /// Always `"m4a"`. Matches the file extension on `fileURL`.
    public let fileExtension: String

    public init(
        captureSessionID: String,
        fileURL: URL,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: Double,
        sizeBytes: Int64,
        mimeType: String,
        fileExtension: String
    ) {
        self.captureSessionID = captureSessionID
        self.fileURL = fileURL
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.sizeBytes = sizeBytes
        self.mimeType = mimeType
        self.fileExtension = fileExtension
    }
}

/// Typed errors for the audio recorder. Callers (CaptureService,
/// AppCoordinator, UI layer) pattern-match these to decide whether
/// to surface a Settings deep-link (permission denied), retry
/// (engine failure), or fail fast.
public enum AudioRecorderError: Error, Sendable, Equatable {
    /// The user denied microphone access (either at first prompt
    /// or in Settings later). Caller should route to a
    /// "Open Settings" recovery UI.
    case permissionDenied

    /// `AVAudioSession` couldn't be configured for the `.record`
    /// category — typically a hardware contention with another app
    /// (phone call, Music recording).
    case sessionConfigurationFailed(reason: String)

    /// The recorder couldn't create the destination directory or
    /// open the file for writing.
    case fileSystemError(reason: String)

    /// `AVAudioRecorder.record()` returned `false`, or finalize
    /// failed with a non-nil error.
    case engineFailure(reason: String)

    /// ``AudioRecorder/stop()`` or ``AudioRecorder/cancel()`` was
    /// called while the recorder was idle. Programmer error
    /// surfaced as a typed throw so callers can ignore it
    /// gracefully if a UI race produced a duplicate stop tap.
    case notRecording

    /// ``AudioRecorder/start(captureSessionID:)`` was called while a
    /// recording was already in progress. The caller must `stop()`
    /// or `cancel()` first.
    case alreadyRecording
}
