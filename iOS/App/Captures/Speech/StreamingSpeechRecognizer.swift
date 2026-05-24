@preconcurrency import AVFoundation
import Foundation

/// Live during-recording speech recognizer. Unlike the file-based
/// ``SpeechTranscriber`` which processes a finalized `.m4a` after
/// `stopCapture`, this protocol consumes an
/// ``AudioBufferSource``'s live PCM stream and emits
/// ``TranscriptSegment``s as the recognizer finalizes them — every
/// 1–3 seconds during a recording, not seconds after stop.
///
/// Why this exists in addition to ``SpeechTranscriber``: Apple's
/// on-device file-based recognizer (`SFSpeechURLRecognitionRequest`)
/// is known to drop significant portions of long continuous speech
/// — it grabs the cleanest section it can decode and ignores the
/// rest. The buffer-based recognizer
/// (`SFSpeechAudioBufferRecognitionRequest`) doesn't have this
/// problem because it processes audio in real time as it arrives,
/// never sees the file as a whole, and naturally handles continuous
/// speech.
///
/// Lifecycle:
/// 1. Caller invokes ``transcripts(buffers:)`` with the buffer
///    stream from a running recorder. Returns an
///    `AsyncThrowingStream` of segments + a handle.
/// 2. Recognizer subscribes to the buffer stream in a background
///    Task, feeds each `AVAudioPCMBuffer` to
///    `SFSpeechAudioBufferRecognitionRequest.append(_:)`.
/// 3. As the recognizer hypothesizes text, callbacks fire with
///    incremental results. The recognizer extracts new phrases
///    (using ``PhraseGrouper``) and yields them.
/// 4. When the buffer stream finishes (recorder stops), the
///    recognizer calls `request.endAudio()`, the final callback
///    fires, any unemitted tail is yielded, and the segment stream
///    finishes.
/// 5. ``stop()`` is a defensive teardown — finishes the segment
///    stream immediately if it's still open. Idempotent.
public protocol StreamingSpeechRecognizer: Sendable {
    /// Begin recognizing audio from `buffers`. Throws
    /// ``SpeechTranscriberError`` synchronously on permission /
    /// availability failure so the caller can surface a banner
    /// rather than receiving a stream that immediately errors.
    func transcripts(
        buffers: AsyncStream<PCMBufferEnvelope>
    ) async throws -> AsyncThrowingStream<TranscriptSegment, Error>

    /// Halt the recognizer and finalize any in-flight recognition.
    /// Idempotent — calling twice is safe. The segment stream from
    /// ``transcripts(buffers:)`` finishes shortly after the first
    /// call (or naturally when the buffer stream ends, whichever
    /// happens first).
    func stop() async
}
