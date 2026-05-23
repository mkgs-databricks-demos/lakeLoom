import Foundation
import Testing

@testable import LakeloomApp

@Suite("TranscriptEvent encoding")
struct TranscriptEventEncodingTests {

    private func encode(_ event: TranscriptEvent) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(event)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Could not decode event JSON")
            return [:]
        }
        return json
    }

    // MARK: - Field naming

    @Test("event_type, segment_index, duration_ms encode as snake_case")
    func snakeCaseFields() throws {
        let event = TranscriptEvent(
            eventType: .finalTranscript,
            text: "Hello world",
            segmentIndex: 3,
            durationMs: 1200
        )
        let json = try encode(event)

        #expect(json["event_type"] as? String == "final_transcript")
        #expect(json["segment_index"] as? Int == 3)
        #expect(json["duration_ms"] as? Int == 1200)
        #expect(json["text"] as? String == "Hello world")
        // No camelCase leakage
        #expect(json["eventType"] == nil)
        #expect(json["segmentIndex"] == nil)
        #expect(json["durationMs"] == nil)
    }

    @Test("EventType rawValues match Genie's documented strings")
    func eventTypeRawValues() {
        #expect(TranscriptEvent.EventType.finalTranscript.rawValue == "final_transcript")
        #expect(TranscriptEvent.EventType.partialTranscript.rawValue == "partial_transcript")
        #expect(TranscriptEvent.EventType.audioUploaded.rawValue == "audio_uploaded")
        #expect(TranscriptEvent.EventType.clientStatus.rawValue == "client_status")
    }

    // MARK: - Optional handling

    @Test("nil fields are omitted from the encoded body")
    func nilFieldsOmitted() throws {
        let event = TranscriptEvent(
            eventType: .clientStatus,
            text: nil,
            confidence: nil,
            language: nil,
            segmentIndex: nil,
            durationMs: nil,
            source: nil,
            model: nil
        )
        let json = try encode(event)

        #expect(json.count == 1)
        #expect(json["event_type"] as? String == "client_status")
    }

    @Test("all fields populated → all present in encoded body")
    func fullPayloadEncodes() throws {
        let event = TranscriptEvent(
            eventType: .finalTranscript,
            text: "Sample text",
            confidence: 0.97,
            language: "en-US",
            segmentIndex: 0,
            durationMs: 18400,
            source: "speech_to_text",
            model: "whisper-large-v3"
        )
        let json = try encode(event)

        #expect(json["event_type"] as? String == "final_transcript")
        #expect(json["text"] as? String == "Sample text")
        #expect((json["confidence"] as? Double).map { abs($0 - 0.97) < 0.0001 } == true)
        #expect(json["language"] as? String == "en-US")
        #expect(json["segment_index"] as? Int == 0)
        #expect(json["duration_ms"] as? Int == 18400)
        #expect(json["source"] as? String == "speech_to_text")
        #expect(json["model"] as? String == "whisper-large-v3")
    }

    // MARK: - Round-trip

    @Test("encode → decode preserves equality")
    func roundTrip() throws {
        let original = TranscriptEvent(
            eventType: .partialTranscript,
            text: "partial",
            confidence: 0.5,
            language: "fr-FR",
            segmentIndex: 1,
            durationMs: 800,
            source: "speech_analyzer",
            model: "apple_speech_analyzer"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptEvent.self, from: data)
        #expect(decoded == original)
    }

    @Test("Array of events encodes as a JSON array")
    func batchEncoding() throws {
        let events = [
            TranscriptEvent(eventType: .finalTranscript, text: "one", segmentIndex: 0),
            TranscriptEvent(eventType: .finalTranscript, text: "two", segmentIndex: 1)
        ]
        let data = try JSONEncoder().encode(events)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]

        #expect(parsed?.count == 2)
        #expect(parsed?[0]["text"] as? String == "one")
        #expect(parsed?[0]["segment_index"] as? Int == 0)
        #expect(parsed?[1]["text"] as? String == "two")
        #expect(parsed?[1]["segment_index"] as? Int == 1)
    }
}
