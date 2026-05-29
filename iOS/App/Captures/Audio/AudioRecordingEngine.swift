import AVFoundation
import Foundation

/// Thin testable seam over `AVAudioRecorder` + `AVAudioSession` +
/// `AVAudioApplication.requestRecordPermission`. ``LiveAudioRecorder``
/// owns one of these and stays focused on the state machine + file
/// management; the live impl owns the CoreAudio specifics.
///
/// Tests inject a fake to assert state transitions and error mapping
/// without spinning up real audio hardware.
protocol AudioRecordingEngine: Sendable {

    /// Current microphone permission as iOS reports it, *without*
    /// prompting. `nil` means the user has not been asked yet (the
    /// caller must invoke ``requestPermission()`` next).
    func currentPermission() async -> Bool?

    /// Prompt for mic permission if undetermined; otherwise return
    /// the current status immediately.
    func requestPermission() async -> Bool

    /// Configure `AVAudioSession` for `.record` and start writing
    /// AAC/M4A to `url`. The engine is responsible for installing
    /// any session-interruption observers it needs internally — the
    /// recorder above doesn't see them in PR 2 (handled in a later
    /// PR with the capture flow's pause/resume).
    func start(writingTo url: URL) async throws

    /// Stop recording, finalize the file, deactivate the session.
    /// Returns a finalized artifact: the URL the audio actually
    /// landed at (which may differ from the URL passed to `start()`
    /// if the engine fell back to a raw intermediate format), the
    /// duration, and the MIME / extension for the upload contract.
    func stop() async throws -> EngineStopArtifact

    /// Stop without keeping the file. Implementations must still
    /// deactivate `AVAudioSession`. The caller deletes the file.
    func cancel() async
}

/// Finalized output of an engine `stop()` call. Carries every chunk
/// the engine produced for this recording, along with the total
/// duration of the session.
///
/// **Chunk model:** today, every engine produces exactly one chunk
/// per recording — `chunks.count == 1`, `chunks[0].chunkIndex == 0`,
/// behavior identical to pre-chunking. PR A piece 4's `AVAudioFile`
/// rotation will produce multi-chunk artifacts (chunks 0..N-1) when
/// the engine is configured with a chunk duration. The array always
/// has at least one element; an engine that produces nothing throws
/// `AudioRecorderError.notRecording` instead.
///
/// **CAF fallback contract:** when an engine that transcodes
/// CAF→M4A internally (currently ``EngineAudioRecordingEngine``)
/// hits a permanent transcode failure, it falls back to producing
/// the raw `.caf` intermediate as the chunk artifact rather than
/// throwing — losing the user's audio is never acceptable. Genie's
/// server-side handler accepts `audio/x-caf` and stores the CAF on
/// UC Volume; silver/gold pipeline transcodes later. See
/// `architecture/hey_isaac/2026-05-28_offline-guarantee-answers.md` §Q1.
public struct EngineStopArtifact: Sendable, Equatable, Hashable {
    public let chunks: [Chunk]
    public let totalDuration: Double

    public init(chunks: [Chunk], totalDuration: Double) {
        precondition(!chunks.isEmpty, "EngineStopArtifact must have at least one chunk")
        self.chunks = chunks
        self.totalDuration = totalDuration
    }

    /// Convenience init for the single-chunk happy path. Builds a
    /// one-element `chunks` array with `chunkIndex = 0`. Behavior
    /// identical to the pre-refactor single-file shape.
    public init(fileURL: URL, duration: Double, mimeType: String, fileExtension: String) {
        self.init(
            chunks: [Chunk(
                fileURL: fileURL,
                chunkIndex: 0,
                duration: duration,
                mimeType: mimeType,
                fileExtension: fileExtension
            )],
            totalDuration: duration
        )
    }

    public struct Chunk: Sendable, Equatable, Hashable {
        public let fileURL: URL
        public let chunkIndex: Int
        public let duration: Double
        public let mimeType: String
        public let fileExtension: String

        public init(
            fileURL: URL,
            chunkIndex: Int,
            duration: Double,
            mimeType: String,
            fileExtension: String
        ) {
            self.fileURL = fileURL
            self.chunkIndex = chunkIndex
            self.duration = duration
            self.mimeType = mimeType
            self.fileExtension = fileExtension
        }
    }
}

/// Production engine — wraps `AVAudioRecorder` configured with iOS's
/// default `.m4a` AAC settings.
actor LiveAudioRecordingEngine: AudioRecordingEngine {

    private var recorder: AVAudioRecorder?
    private var delegateProxy: RecorderDelegateProxy?
    /// Captured the moment we hit `record()` because
    /// `AVAudioRecorder.currentTime` jumps to 0 after `stop()`.
    private var recordingStartedAt: Date?

    init() {}

    func currentPermission() async -> Bool? {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:    return true
        case .denied:     return false
        case .undetermined: return nil
        @unknown default: return nil
        }
    }

    func requestPermission() async -> Bool {
        if let known = await currentPermission() { return known }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start(writingTo url: URL) async throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true, options: [])
        } catch {
            throw AudioRecorderError.sessionConfigurationFailed(reason: error.localizedDescription)
        }

        // iOS default AAC/M4A. Sample rate and channels match what
        // `AVAudioRecorder` would pick for `.m4a` files; documenting
        // explicitly so the wire-format contract is grep-able.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        let avRecorder: AVAudioRecorder
        do {
            avRecorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            throw AudioRecorderError.engineFailure(reason: "AVAudioRecorder init: \(error.localizedDescription)")
        }
        // Install a delegate proxy so `stop()` can await
        // `audioRecorderDidFinishRecording` and only return once
        // Core Audio has flushed the file to disk. Without this,
        // callers can read the file before `AVAudioRecorder` is
        // finished closing it — which is exactly the
        // "Waiting for Stop to be signaled timed out. Forcing Stop"
        // log the iOS Simulator surfaces under load.
        let proxy = RecorderDelegateProxy()
        avRecorder.delegate = proxy
        avRecorder.prepareToRecord()
        guard avRecorder.record() else {
            throw AudioRecorderError.engineFailure(reason: "AVAudioRecorder.record() returned false")
        }
        self.recorder = avRecorder
        self.delegateProxy = proxy
        self.recordingStartedAt = Date()
    }

    func stop() async throws -> EngineStopArtifact {
        guard let recorder, let proxy = delegateProxy, let startedAt = recordingStartedAt else {
            throw AudioRecorderError.notRecording
        }
        let rawDuration = recorder.currentTime
        let recorderURL = recorder.url
        // Subscribe to the delegate's finalize stream BEFORE calling
        // stop(), so we never miss the delegate yield if it fires
        // synchronously inside `stop()`.
        var iterator = proxy.finishedStream.makeAsyncIterator()
        recorder.stop()
        _ = await iterator.next()

        self.recorder = nil
        self.delegateProxy = nil
        self.recordingStartedAt = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        // Fallback in case `currentTime` was 0 (e.g., very short
        // recording) — use wall clock so we never report a negative
        // or zero duration for a recording that did happen.
        let duration: Double = rawDuration > 0
            ? rawDuration
            : max(0.001, Date().timeIntervalSince(startedAt))
        return EngineStopArtifact(
            fileURL: recorderURL,
            duration: duration,
            mimeType: "audio/mp4",
            fileExtension: "m4a"
        )
    }

    func cancel() async {
        // Cancel is a fire-and-forget tear-down. We don't await the
        // delegate because the caller is discarding the file anyway —
        // they don't need the post-flush guarantee. Cleanup happens
        // best-effort.
        recorder?.stop()
        recorder = nil
        delegateProxy = nil
        recordingStartedAt = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

/// Bridges `AVAudioRecorderDelegate` (an Obj-C protocol requiring an
/// `NSObject` subclass) into the Swift-concurrency world. Each delegate
/// callback yields onto an `AsyncStream<Bool>`; the engine's `stop()`
/// awaits one element from that stream so callers see a fully-flushed
/// file when `stop()` returns.
///
/// `@unchecked Sendable` because the proxy is single-use and only ever
/// produces values from inside Core Audio's callback queue — the actor
/// retains it for the lifetime of one recording and drops it after
/// consuming the stream.
private final class RecorderDelegateProxy: NSObject, AVAudioRecorderDelegate, @unchecked Sendable {

    let finishedStream: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    override init() {
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.finishedStream = stream
        self.continuation = continuation
        super.init()
    }

    deinit {
        continuation.finish()
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        continuation.yield(flag)
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        // Encode failure still yields so `stop()` doesn't hang; the
        // engine reports the resulting duration based on wall clock.
        continuation.yield(false)
    }
}
