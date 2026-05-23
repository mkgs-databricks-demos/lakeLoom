import Foundation

/// Transcribes a recorded audio file into a stream of
/// ``TranscriptSegment``s. Used post-recording in
/// ``LiveCaptureService``'s finalize path — the audio file is the
/// authoritative artifact, and each emitted segment becomes a
/// `final_transcript` ZeroBus event via ``TranscriptEventsClient``.
///
/// A future PR will introduce a sibling protocol or extension for
/// **live** streaming (AVAudioEngine tap → SpeechAnalyzer). This v1
/// surface is intentionally file-based so it slots cleanly between
/// "audio recording stopped" and "audio file uploaded" without
/// touching the existing AVAudioRecorder pipeline.
///
/// The returned stream finishes after the last segment is delivered.
/// Errors are thrown synchronously from the call before the stream
/// starts, OR yielded as the stream's terminal state (cancellation,
/// mid-flight failures) — the protocol guarantees one of these two
/// paths, never both.
public protocol SpeechTranscriber: Sendable {
    /// Transcribe the file at `fileURL`. The recognizer must be
    /// configured to prefer on-device recognition; if on-device
    /// isn't available, the impl decides whether to fall back to
    /// server (currently no) or surface ``SpeechTranscriberError/unavailable``.
    ///
    /// - Parameters:
    ///   - fileURL: Local file (typically the `.m4a` written by
    ///     ``LiveAudioRecorder``).
    ///   - locale: BCP-47 tag. Defaults to `en-US`. Pass nil to use
    ///     the system default.
    /// - Returns: A stream of segments in monotonic `segmentIndex`
    ///   order. The stream finishes once the recognizer emits its
    ///   final result; if recognition fails the stream finishes
    ///   without further yields after the impl logs the failure
    ///   (best-effort transcription doesn't bubble errors to the
    ///   capture pipeline).
    func transcribe(
        fileURL: URL,
        locale: Locale?
    ) async throws -> AsyncThrowingStream<TranscriptSegment, Error>
}
