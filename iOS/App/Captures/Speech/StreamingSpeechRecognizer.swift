import Foundation

/// Live-recording speech recognizer. Unlike ``SpeechTranscriber``
/// which takes a finalized audio file post-stop, this protocol runs
/// in parallel with the audio recorder and emits ``TranscriptSegment``s
/// as the recognizer finalizes them — typically every 1–3 seconds
/// during a recording.
///
/// Lifecycle:
/// 1. ``transcripts()`` returns an `AsyncThrowingStream` and starts
///    the underlying engine (AVAudioEngine for the live impl).
/// 2. The caller iterates segments off the stream in a background
///    Task as audio flows through the mic.
/// 3. ``stop()`` ends the engine + finalizes any in-flight
///    recognition. The stream finishes naturally after the last
///    segment is delivered.
///
/// The protocol is one-shot per instance — once `stop()` has been
/// called, a fresh recognizer is needed for the next session.
/// Implementations are responsible for permission gating
/// (`SFSpeechRecognizer.requestAuthorization`) and audio-session
/// configuration; callers see a single async surface.
public protocol StreamingSpeechRecognizer: Sendable {
    /// Begin recognizing audio from the device microphone. Throws
    /// ``SpeechTranscriberError`` synchronously on permission or
    /// availability failure (so the caller can surface a banner)
    /// rather than returning a stream that immediately errors.
    /// Once the call returns, segments are yielded as they finalize.
    func transcripts() async throws -> AsyncThrowingStream<TranscriptSegment, Error>

    /// Halt the engine and finalize any in-flight recognition. The
    /// stream returned from `transcripts()` finishes shortly after.
    /// Idempotent — calling twice (e.g. from a watchdog + the
    /// capture stop path) is safe.
    func stop() async
}
