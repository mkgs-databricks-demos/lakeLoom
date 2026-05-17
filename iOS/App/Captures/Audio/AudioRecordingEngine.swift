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
    /// Returns the recorded duration in seconds.
    func stop() async throws -> Double

    /// Stop without keeping the file. Implementations must still
    /// deactivate `AVAudioSession`. The caller deletes the file.
    func cancel() async
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

    func stop() async throws -> Double {
        guard let recorder, let proxy = delegateProxy, let startedAt = recordingStartedAt else {
            throw AudioRecorderError.notRecording
        }
        let duration = recorder.currentTime
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
        if duration <= 0 {
            return max(0.001, Date().timeIntervalSince(startedAt))
        }
        return duration
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
