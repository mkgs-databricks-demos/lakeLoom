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

    /// Stop the active recording and finalize the file(s). Returns
    /// a ``CompletedRecording`` carrying one or more chunks (today
    /// always one; PR A piece 4's chunked-recording rotation will
    /// produce multi-chunk completions for long sessions).
    /// Throws ``AudioRecorderError/notRecording`` if no recording
    /// is in progress.
    func stop() async throws -> CompletedRecording

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

/// One finalized audio chunk handed to the upload layer. Multiple
/// chunks may belong to a single capture session — see
/// ``CompletedRecording`` for the session-level wrapper and PR A
/// piece 4's design (`architecture/hi_genie/2026-05-29_chunked-recording-design.md`)
/// for the chunked-recording rationale.
///
/// Wire fields map 1:1 to what the upload handler needs (per Genie's
/// contract). Keep them in sync with
/// `lakeloom-ai/server/routes/captures/upload-routes.ts`.
public struct AudioRecording: Sendable, Equatable, Hashable {
    public let captureSessionID: String
    public let fileURL: URL
    public let startedAt: Date
    public let endedAt: Date
    public let durationSeconds: Double
    public let sizeBytes: Int64
    /// `"audio/mp4"` for an M4A chunk (the happy path) or
    /// `"audio/x-caf"` for a CAF fallback chunk when on-device
    /// transcode failed. Genie's server-side accept-list allows both.
    public let mimeType: String
    /// `"m4a"` or `"caf"`. Matches the file extension on `fileURL`.
    public let fileExtension: String
    /// 0-based position of this chunk within its capture session.
    /// Today's single-chunk recordings always have `chunkIndex = 0`.
    /// Chunked recording (PR A piece 4) increments per rotation.
    public let chunkIndex: Int
    /// `true` iff this is the last chunk of the session — i.e.,
    /// recorded between the last rotation and `stopCapture()`. For
    /// single-chunk recordings, the only chunk is final by definition.
    public let isFinalChunk: Bool

    public init(
        captureSessionID: String,
        fileURL: URL,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: Double,
        sizeBytes: Int64,
        mimeType: String,
        fileExtension: String,
        chunkIndex: Int = 0,
        isFinalChunk: Bool = true
    ) {
        self.captureSessionID = captureSessionID
        self.fileURL = fileURL
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.sizeBytes = sizeBytes
        self.mimeType = mimeType
        self.fileExtension = fileExtension
        self.chunkIndex = chunkIndex
        self.isFinalChunk = isFinalChunk
    }
}

/// Closed-out recording, one per `AudioRecorder.stop()` call. Wraps
/// the ordered list of chunks the engine produced — always at least
/// one, exactly one for single-chunk recordings (today's default).
///
/// `final` is a convenience for callers that only care about the
/// last chunk's metadata (e.g. logging, UI summary). `chunks` is the
/// authoritative ordered list — iterate it to enqueue each chunk as
/// its own upload. Init enforces non-empty so `final` / `first` are
/// always safe.
public struct CompletedRecording: Sendable, Equatable, Hashable {
    public let chunks: [AudioRecording]

    public init(chunks: [AudioRecording]) {
        precondition(!chunks.isEmpty, "CompletedRecording must have at least one chunk")
        self.chunks = chunks
    }

    /// Convenience for the common single-chunk case.
    public init(_ recording: AudioRecording) {
        self.init(chunks: [recording])
    }

    /// The last chunk (the one being recorded when `stop()` was
    /// called). For single-chunk recordings, this is the only chunk.
    public var final: AudioRecording { chunks.last! }

    /// The first chunk. Useful when the caller needs the session
    /// `startedAt` — every chunk carries its own start time, but the
    /// first chunk's is the session's true start.
    public var first: AudioRecording { chunks.first! }
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
