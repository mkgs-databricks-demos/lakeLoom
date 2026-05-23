import Foundation

/// One transcribed segment surfaced by ``SpeechTranscriber``. Carries
/// enough context to populate a ``TranscriptEvent`` payload without
/// the caller having to handle Apple's `SFTranscription` /
/// `SFTranscriptionSegment` types directly.
///
/// Each segment maps 1:1 to a final ZeroBus `final_transcript` event:
/// `text` → `text`, `confidence` → `confidence`,
/// `segmentIndex` → `segment_index`, `durationMs` → `duration_ms`.
public struct TranscriptSegment: Sendable, Equatable, Hashable {

    /// Recognized text for this segment. Whitespace not normalized.
    public let text: String

    /// Average confidence in [0, 1] across the words in this
    /// segment, or nil when the recognizer doesn't surface one.
    public let confidence: Double?

    /// Monotonic counter scoped to a single recording. Matches the
    /// `segment_index` field on the server payload — lets readers
    /// re-stitch out-of-order events.
    public let segmentIndex: Int

    /// Wall-clock duration of this segment in milliseconds. Computed
    /// from the recognizer's start/end timing.
    public let durationMs: Int

    /// Start of the segment relative to the beginning of the audio,
    /// in seconds. Useful for downstream UI that scrubs the audio
    /// timeline by transcript.
    public let startTimeSeconds: Double

    public init(
        text: String,
        confidence: Double? = nil,
        segmentIndex: Int,
        durationMs: Int,
        startTimeSeconds: Double
    ) {
        self.text = text
        self.confidence = confidence
        self.segmentIndex = segmentIndex
        self.durationMs = durationMs
        self.startTimeSeconds = startTimeSeconds
    }
}
