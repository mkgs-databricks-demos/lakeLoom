import Foundation

@testable import LakeloomApp

/// Scriptable ``SpeechTranscriber`` for ``LiveCaptureService`` tests.
/// Records each `transcribe(...)` call and yields a canned segment
/// sequence so we can verify the segment → TranscriptEvent forwarding
/// without standing up a real SFSpeechRecognizer.
public actor FakeSpeechTranscriber: SpeechTranscriber {

    public struct TranscribeCall: Sendable, Equatable {
        public let fileURL: URL
        public let localeIdentifier: String?
    }

    public private(set) var calls: [TranscribeCall] = []

    private var nextResult: Result<[TranscriptSegment], Error> = .success([])

    public init() {}

    public func enqueueSegments(_ segments: [TranscriptSegment]) {
        nextResult = .success(segments)
    }

    public func enqueueFailure(_ error: Error) {
        nextResult = .failure(error)
    }

    public func transcribe(
        fileURL: URL,
        locale: Locale?
    ) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        calls.append(TranscribeCall(
            fileURL: fileURL,
            localeIdentifier: locale?.identifier
        ))
        switch nextResult {
        case .success(let segments):
            return AsyncThrowingStream { continuation in
                for segment in segments {
                    continuation.yield(segment)
                }
                continuation.finish()
            }
        case .failure(let error):
            throw error
        }
    }
}
