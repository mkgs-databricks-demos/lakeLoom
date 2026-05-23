import Foundation

@testable import LakeloomApp

/// Scriptable ``StreamingSpeechRecognizer`` for capture-service
/// tests. Drives a controllable AsyncThrowingStream so tests can
/// emit segments mid-recording, verify the streamer wiring, and
/// confirm `stop()` finishes the stream cleanly.
public actor FakeStreamingSpeechRecognizer: StreamingSpeechRecognizer {

    public private(set) var transcriptsCallCount = 0
    public private(set) var stopCallCount = 0
    public private(set) var failureOnTranscripts: Error?

    private var continuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation?

    public init() {}

    public func setFailureOnTranscripts(_ error: Error) {
        failureOnTranscripts = error
    }

    /// Yield a segment to whatever consumer is iterating the stream
    /// returned from `transcripts()`. Use to script the live
    /// emission pattern in tests.
    public func emit(_ segment: TranscriptSegment) {
        continuation?.yield(segment)
    }

    public func finish() {
        continuation?.finish()
        continuation = nil
    }

    public func finish(throwing error: Error) {
        continuation?.finish(throwing: error)
        continuation = nil
    }

    // MARK: - StreamingSpeechRecognizer

    public func transcripts() async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        transcriptsCallCount += 1
        if let failureOnTranscripts {
            throw failureOnTranscripts
        }
        let (stream, continuation) = AsyncThrowingStream<TranscriptSegment, Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    public func stop() async {
        stopCallCount += 1
        continuation?.finish()
        continuation = nil
    }
}
