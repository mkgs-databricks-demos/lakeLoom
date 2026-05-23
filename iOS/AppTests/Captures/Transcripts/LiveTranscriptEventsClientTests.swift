import Foundation
import Testing

@testable import LakeloomApp

@Suite("LiveTranscriptEventsClient")
struct LiveTranscriptEventsClientTests {

    private static let workspaceID = "fevm-hls-fde"
    private static let pairedSessionID = "ps-abcdef-1234"

    private static func sampleEvent(segment: Int = 0) -> TranscriptEvent {
        TranscriptEvent(
            eventType: .finalTranscript,
            text: "hello world",
            confidence: 0.92,
            language: "en-US",
            segmentIndex: segment,
            durationMs: 1200,
            source: "speech_to_text",
            model: "whisper-large-v3"
        )
    }

    // MARK: - Success

    @Test("sendEvents POSTs to the paired-session path, decodes accepted count")
    func happyPath() async throws {
        let fake = FakeLakeloomAppClient()
        await fake.enqueueResponse(.success(Data("""
        { "accepted": 2 }
        """.utf8)))

        let client = LiveTranscriptEventsClient(lakeloomApp: fake)
        let accepted = try await client.sendEvents(
            workspaceID: Self.workspaceID,
            pairedSessionID: Self.pairedSessionID,
            events: [Self.sampleEvent(segment: 0), Self.sampleEvent(segment: 1)]
        )

        #expect(accepted == 2)

        let calls = await fake.requestCalls
        #expect(calls.count == 1)
        #expect(calls.first?.method == .post)
        #expect(calls.first?.path == "/api/sessions/\(Self.pairedSessionID)/events")
        #expect(calls.first?.workspaceID == Self.workspaceID)
    }

    @Test("sendEvent convenience wraps a singleton into an array")
    func singletonConvenience() async throws {
        let fake = FakeLakeloomAppClient()
        await fake.enqueueResponse(.success(Data(#"{ "accepted": 1 }"#.utf8)))

        let client = LiveTranscriptEventsClient(lakeloomApp: fake)
        let accepted = try await client.sendEvent(
            workspaceID: Self.workspaceID,
            pairedSessionID: Self.pairedSessionID,
            event: Self.sampleEvent()
        )
        #expect(accepted == 1)

        let calls = await fake.requestCalls
        let body = try #require(calls.first?.body)
        let parsed = try JSONSerialization.jsonObject(with: body)
        #expect(parsed is [[String: Any]], "body should be an array, even for a singleton")
        if let arr = parsed as? [[String: Any]] {
            #expect(arr.count == 1)
        }
    }

    @Test("encoded body uses compact JSON (no whitespace) and snake_case keys")
    func compactBodyShape() async throws {
        let fake = FakeLakeloomAppClient()
        await fake.enqueueResponse(.success(Data(#"{ "accepted": 1 }"#.utf8)))

        let client = LiveTranscriptEventsClient(lakeloomApp: fake)
        _ = try await client.sendEvent(
            workspaceID: Self.workspaceID,
            pairedSessionID: Self.pairedSessionID,
            event: Self.sampleEvent()
        )
        let calls = await fake.requestCalls
        let bytes = try #require(calls.first?.body)
        let text = try #require(String(data: bytes, encoding: .utf8))

        // Compact JSON: no spaces after ':' or ','
        #expect(!text.contains(": "))
        #expect(!text.contains(", "))
        // Snake-case keys present in raw body bytes
        #expect(text.contains("\"event_type\""))
        #expect(text.contains("\"segment_index\""))
        #expect(text.contains("\"duration_ms\""))
    }

    // MARK: - Pre-flight validation

    @Test("empty array short-circuits without hitting the network")
    func emptyArrayThrows() async {
        let fake = FakeLakeloomAppClient()
        let client = LiveTranscriptEventsClient(lakeloomApp: fake)
        await #expect(throws: TranscriptEventsError.empty) {
            _ = try await client.sendEvents(
                workspaceID: Self.workspaceID,
                pairedSessionID: Self.pairedSessionID,
                events: []
            )
        }
        let calls = await fake.requestCalls
        #expect(calls.isEmpty, "should not hit the wire")
    }

    @Test("> 100 events short-circuits with batchTooLarge")
    func tooLargeBatchThrows() async {
        let fake = FakeLakeloomAppClient()
        let client = LiveTranscriptEventsClient(lakeloomApp: fake)
        let events = (0..<101).map { Self.sampleEvent(segment: $0) }
        await #expect(throws: TranscriptEventsError.batchTooLarge(count: 101)) {
            _ = try await client.sendEvents(
                workspaceID: Self.workspaceID,
                pairedSessionID: Self.pairedSessionID,
                events: events
            )
        }
        let calls = await fake.requestCalls
        #expect(calls.isEmpty, "should not hit the wire")
    }

    @Test("exactly 100 events is allowed")
    func batchAtBoundary() async throws {
        let fake = FakeLakeloomAppClient()
        await fake.enqueueResponse(.success(Data(#"{ "accepted": 100 }"#.utf8)))

        let client = LiveTranscriptEventsClient(lakeloomApp: fake)
        let events = (0..<100).map { Self.sampleEvent(segment: $0) }
        let accepted = try await client.sendEvents(
            workspaceID: Self.workspaceID,
            pairedSessionID: Self.pairedSessionID,
            events: events
        )
        #expect(accepted == 100)
    }

    // MARK: - Error mapping

    @Test("networkUnavailable → TranscriptEventsError.networkUnavailable")
    func networkUnavailableMaps() async {
        let fake = FakeLakeloomAppClient()
        await fake.enqueueResponse(.failure(.networkUnavailable))

        let client = LiveTranscriptEventsClient(lakeloomApp: fake)
        await #expect(throws: TranscriptEventsError.networkUnavailable) {
            _ = try await client.sendEvent(
                workspaceID: Self.workspaceID,
                pairedSessionID: Self.pairedSessionID,
                event: Self.sampleEvent()
            )
        }
    }

    @Test("422 → validationFailed")
    func validation422Maps() async {
        let fake = FakeLakeloomAppClient()
        await fake.enqueueResponse(.failure(.httpError(status: 422, detail: "missing text", code: nil)))

        let client = LiveTranscriptEventsClient(lakeloomApp: fake)
        await #expect(throws: TranscriptEventsError.validationFailed(reason: "missing text")) {
            _ = try await client.sendEvent(
                workspaceID: Self.workspaceID,
                pairedSessionID: Self.pairedSessionID,
                event: Self.sampleEvent()
            )
        }
    }

    @Test("403 → forbidden")
    func forbidden403Maps() async {
        let fake = FakeLakeloomAppClient()
        await fake.enqueueResponse(.failure(.httpError(status: 403, detail: "session belongs to another user", code: nil)))

        let client = LiveTranscriptEventsClient(lakeloomApp: fake)
        await #expect(throws: TranscriptEventsError.forbidden(reason: "session belongs to another user")) {
            _ = try await client.sendEvent(
                workspaceID: Self.workspaceID,
                pairedSessionID: Self.pairedSessionID,
                event: Self.sampleEvent()
            )
        }
    }

    @Test("401 token_expired → authFailed")
    func tokenExpiredMaps() async {
        let fake = FakeLakeloomAppClient()
        await fake.enqueueResponse(.failure(.unauthorized(kind: .tokenExpired, detail: "session token expired")))

        let client = LiveTranscriptEventsClient(lakeloomApp: fake)
        await #expect(throws: TranscriptEventsError.authFailed(reason: "session token expired")) {
            _ = try await client.sendEvent(
                workspaceID: Self.workspaceID,
                pairedSessionID: Self.pairedSessionID,
                event: Self.sampleEvent()
            )
        }
    }

    @Test("500 → serverUnavailable")
    func server500Maps() async {
        let fake = FakeLakeloomAppClient()
        await fake.enqueueResponse(.failure(.httpError(status: 500, detail: "zerobus pool exhausted", code: nil)))

        let client = LiveTranscriptEventsClient(lakeloomApp: fake)
        await #expect(throws: TranscriptEventsError.serverUnavailable(status: 500, reason: "zerobus pool exhausted")) {
            _ = try await client.sendEvent(
                workspaceID: Self.workspaceID,
                pairedSessionID: Self.pairedSessionID,
                event: Self.sampleEvent()
            )
        }
    }
}
