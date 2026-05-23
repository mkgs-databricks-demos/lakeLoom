import Foundation

/// One event in lakeLoom's ZeroBus transcript ingest pipeline. The
/// server route `POST /api/sessions/:paired_session_id/events`
/// accepts a single event OR an array of up to 100 events
/// (per Genie's `hey_isaac/2026-05-21_zerobus-ingest-live-start-sending.md`).
///
/// The client always sends arrays — even singletons — so the wire
/// shape is consistent.
///
/// Field names map to the documented snake_case payload. Extra
/// fields the server doesn't extract into typed columns are still
/// preserved in the VARIANT `body` column, so this struct lists the
/// known-typed fields for v1; richer model-specific metadata
/// (per-word timestamps, alternates, etc.) will warrant a
/// `metadata: [String: JSONValue]` follow-on once the speech engine
/// is integrated.
public struct TranscriptEvent: Sendable, Equatable, Hashable, Codable {

    /// Discriminator. Drives which Delta column the server lights up
    /// and which downstream view materializes the row.
    public let eventType: EventType

    /// The transcribed text. Required for `.finalTranscript` /
    /// `.partialTranscript`; nil for status / file-correlation events.
    public let text: String?

    /// 0..1 confidence score the speech engine reported for this
    /// segment. Optional — engines that don't expose a confidence can
    /// omit it.
    public let confidence: Double?

    /// BCP-47 language tag (e.g. `en-US`). Optional.
    public let language: String?

    /// Monotonic counter scoped to a single recording. Lets downstream
    /// readers re-stitch out-of-order events in delivery order
    /// independent of `ingested_at`.
    public let segmentIndex: Int?

    /// Wall-clock duration of the segment in milliseconds. Optional.
    public let durationMs: Int?

    /// Free-form source label — `speech_to_text`, `speech_analyzer`,
    /// `manual_correction`, etc. Useful for filtering in analyses.
    public let source: String?

    /// Engine/model identifier, e.g. `apple_speech_analyzer` or
    /// `whisper-large-v3`. Useful for cross-engine quality compare.
    public let model: String?

    public init(
        eventType: EventType,
        text: String? = nil,
        confidence: Double? = nil,
        language: String? = nil,
        segmentIndex: Int? = nil,
        durationMs: Int? = nil,
        source: String? = nil,
        model: String? = nil
    ) {
        self.eventType = eventType
        self.text = text
        self.confidence = confidence
        self.language = language
        self.segmentIndex = segmentIndex
        self.durationMs = durationMs
        self.source = source
        self.model = model
    }

    /// Documented event types. Strict matching — unknown values from
    /// the server would surface as a decode failure, which is what we
    /// want until iOS and server schemas agree on a new type.
    public enum EventType: String, Sendable, Equatable, Hashable, Codable {
        case finalTranscript = "final_transcript"
        case partialTranscript = "partial_transcript"
        case audioUploaded = "audio_uploaded"
        case clientStatus = "client_status"
    }

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case text
        case confidence
        case language
        case segmentIndex = "segment_index"
        case durationMs = "duration_ms"
        case source
        case model
    }
}
