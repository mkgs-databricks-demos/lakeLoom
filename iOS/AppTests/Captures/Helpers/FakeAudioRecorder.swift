import Foundation

@testable import LakeloomApp

/// Scriptable ``AudioRecorder`` for ``CaptureService`` tests. Tracks
/// start/stop/cancel calls and returns canned URLs / recordings.
public actor FakeAudioRecorder: AudioRecorder {

    public enum Call: Sendable, Equatable {
        case start(String)
        case stop
        case cancel
    }

    public private(set) var calls: [Call] = []

    private var fakeURL: URL = URL(fileURLWithPath: "/tmp/fake-audio.m4a")
    private var startError: Error?
    private var stopError: Error?
    private var fakeRecording: AudioRecording?
    private var internalState: AudioRecorderState = .idle

    public init() {}

    public func setFakeURL(_ url: URL) {
        fakeURL = url
    }
    public func setStartError(_ error: Error?) {
        startError = error
    }
    public func setStopError(_ error: Error?) {
        stopError = error
    }
    public func setFakeRecording(_ recording: AudioRecording) {
        fakeRecording = recording
    }

    public var state: AudioRecorderState { internalState }

    public func start(captureSessionID: String) async throws -> URL {
        calls.append(.start(captureSessionID))
        if let startError { throw startError }
        internalState = .recording(captureSessionID: captureSessionID, startedAt: Date())
        return fakeURL
    }

    public func stop() async throws -> AudioRecording {
        calls.append(.stop)
        if let stopError { throw stopError }
        internalState = .idle
        if let fakeRecording { return fakeRecording }
        return AudioRecording(
            captureSessionID: "unknown",
            fileURL: fakeURL,
            startedAt: Date(),
            endedAt: Date(),
            durationSeconds: 1.0,
            sizeBytes: 1024,
            mimeType: "audio/mp4",
            fileExtension: "m4a"
        )
    }

    public func cancel() async {
        calls.append(.cancel)
        internalState = .idle
    }
}
