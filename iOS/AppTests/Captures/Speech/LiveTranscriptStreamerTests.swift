import Foundation
import Testing

@testable import LakeloomApp

/// Scriptable transcript events client for streamer tests. Records
/// every batch and can be scripted to fail the first N attempts.
private actor ScriptedTranscriptEventsClient: TranscriptEventsClient {

    struct Call: Sendable {
        let events: [TranscriptEvent]
    }

    private(set) var calls: [Call] = []
    private var nextResults: [Result<Int, TranscriptEventsError>] = []

    func enqueue(_ result: Result<Int, TranscriptEventsError>) {
        nextResults.append(result)
    }

    func sendEvents(
        workspaceID: String,
        pairedSessionID: String,
        events: [TranscriptEvent]
    ) async throws -> Int {
        calls.append(Call(events: events))
        if nextResults.isEmpty {
            return events.count
        }
        switch nextResults.removeFirst() {
        case .success(let n): return n
        case .failure(let error): throw error
        }
    }
}

@Suite("LiveTranscriptStreamer")
struct LiveTranscriptStreamerTests {

    private static let workspaceID = "ws-1"
    private static let pairedSessionID = "paired-1"
    private static let projectID = "proj-1"
    private static let deviceID = "device-uuid-aaaa"
    private static let recordingStartedAt = Date(timeIntervalSince1970: 1_747_152_120)

    private static func makeStreamer(
        events: any TranscriptEventsClient,
        maxBatchSize: Int = 100,
        retries: [TimeInterval] = [0]
    ) -> LiveTranscriptStreamer {
        LiveTranscriptStreamer(
            events: events,
            maxBatchSize: maxBatchSize,
            retryBackoffSeconds: retries,
            logger: AppLogger(category: .capture),
            sleep: { _ in }
        )
    }

    private static func segments(count: Int) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { continuation in
            for i in 0..<count {
                continuation.yield(TranscriptSegment(
                    text: "segment-\(i)",
                    confidence: 0.9,
                    segmentIndex: i,
                    durationMs: 500,
                    startTimeSeconds: Double(i) * 0.5
                ))
            }
            continuation.finish()
        }
    }

    private static func emptySegments() -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    private static func failingSegments(
        yieldCount: Int,
        thenError: Error
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { continuation in
            for i in 0..<yieldCount {
                continuation.yield(TranscriptSegment(
                    text: "segment-\(i)",
                    segmentIndex: i,
                    durationMs: 500,
                    startTimeSeconds: Double(i) * 0.5
                ))
            }
            continuation.finish(throwing: thenError)
        }
    }

    private static func drive(
        streamer: LiveTranscriptStreamer,
        segments: AsyncThrowingStream<TranscriptSegment, Error>
    ) async {
        await streamer.stream(
            workspaceID: workspaceID,
            pairedSessionID: pairedSessionID,
            projectID: projectID,
            deviceID: deviceID,
            recordingStartedAt: recordingStartedAt,
            segments: segments,
            source: "on_device",
            model: "sf_speech_recognizer",
            language: "en-US"
        )
    }

    // MARK: - Batching

    @Test("empty stream → no sends")
    func emptyStream() async {
        let events = ScriptedTranscriptEventsClient()
        let streamer = Self.makeStreamer(events: events)
        await Self.drive(streamer: streamer, segments: Self.emptySegments())
        let calls = await events.calls
        #expect(calls.isEmpty)
    }

    @Test("under-batchSize segments → single batch flushed on stream end")
    func singleBatchOnEnd() async {
        let events = ScriptedTranscriptEventsClient()
        let streamer = Self.makeStreamer(events: events)
        await Self.drive(streamer: streamer, segments: Self.segments(count: 7))
        let calls = await events.calls
        #expect(calls.count == 1)
        #expect(calls.first?.events.count == 7)
        // Each event populated with the streamer's source/model/lang.
        #expect(calls.first?.events.first?.source == "on_device")
        #expect(calls.first?.events.first?.model == "sf_speech_recognizer")
        #expect(calls.first?.events.first?.language == "en-US")
        // project_id + device_id threaded through.
        #expect(calls.first?.events.first?.projectID == Self.projectID)
        #expect(calls.first?.events.first?.deviceID == Self.deviceID)
    }

    @Test("more than batchSize segments → split across batches")
    func multipleBatches() async {
        let events = ScriptedTranscriptEventsClient()
        let streamer = Self.makeStreamer(events: events, maxBatchSize: 3)
        await Self.drive(streamer: streamer, segments: Self.segments(count: 7))
        let calls = await events.calls
        // 7 segments / batch=3 → 3 batches of [3, 3, 1].
        #expect(calls.count == 3)
        #expect(calls.map { $0.events.count } == [3, 3, 1])
        // Ordering preserved across batches.
        let allTexts = calls.flatMap { $0.events.map { $0.text ?? "" } }
        #expect(allTexts == (0..<7).map { "segment-\($0)" })
    }

    @Test("exact-multiple → final flush is skipped (no empty trailing call)")
    func exactMultiple() async {
        let events = ScriptedTranscriptEventsClient()
        let streamer = Self.makeStreamer(events: events, maxBatchSize: 4)
        await Self.drive(streamer: streamer, segments: Self.segments(count: 8))
        let calls = await events.calls
        #expect(calls.count == 2)
        #expect(calls.map { $0.events.count } == [4, 4])
    }

    // MARK: - Retry classification

    @Test("transient failure retries then succeeds")
    func transientRetrySucceeds() async {
        let events = ScriptedTranscriptEventsClient()
        await events.enqueue(.failure(.networkUnavailable))
        await events.enqueue(.success(3))
        let streamer = Self.makeStreamer(events: events, retries: [0, 0, 0])
        await Self.drive(streamer: streamer, segments: Self.segments(count: 3))
        let calls = await events.calls
        #expect(calls.count == 2, "first attempt fails transient, retry succeeds")
        // Both attempts carry the same batch.
        #expect(calls[0].events.count == 3)
        #expect(calls[1].events.count == 3)
    }

    @Test("transient retry exhausts → drop batch, continue with next")
    func transientExhausts() async {
        let events = ScriptedTranscriptEventsClient()
        // 3-attempt schedule, 3 transient failures, then a success
        // for the second batch.
        await events.enqueue(.failure(.timeout))
        await events.enqueue(.failure(.timeout))
        await events.enqueue(.failure(.timeout))
        await events.enqueue(.success(2))
        let streamer = Self.makeStreamer(events: events, maxBatchSize: 2, retries: [0, 0, 0])
        await Self.drive(streamer: streamer, segments: Self.segments(count: 4))
        let calls = await events.calls
        // First batch tried 3 times + second batch tried 1 time.
        #expect(calls.count == 4)
        #expect(calls.prefix(3).allSatisfy { $0.events.first?.segmentIndex == 0 }, "first batch retried")
        #expect(calls.last?.events.first?.segmentIndex == 2, "second batch delivered")
    }

    @Test("permanent failure drops batch immediately, no retry")
    func permanentDropsImmediately() async {
        let events = ScriptedTranscriptEventsClient()
        await events.enqueue(.failure(.validationFailed(reason: "schema drift")))
        await events.enqueue(.success(2))
        let streamer = Self.makeStreamer(events: events, maxBatchSize: 2, retries: [0, 0, 0])
        await Self.drive(streamer: streamer, segments: Self.segments(count: 4))
        let calls = await events.calls
        // First batch: 1 attempt only. Second batch: 1 attempt success.
        #expect(calls.count == 2)
        #expect(calls[0].events.first?.segmentIndex == 0)
        #expect(calls[1].events.first?.segmentIndex == 2)
    }

    @Test("5xx server unavailable counts as transient")
    func serverUnavailableTransient() async {
        let events = ScriptedTranscriptEventsClient()
        await events.enqueue(.failure(.serverUnavailable(status: 503, reason: "pool wake")))
        await events.enqueue(.success(1))
        let streamer = Self.makeStreamer(events: events, retries: [0, 0])
        await Self.drive(streamer: streamer, segments: Self.segments(count: 1))
        let calls = await events.calls
        #expect(calls.count == 2, "503 should retry, then succeed")
    }

    @Test("auth failed counts as permanent (no retry)")
    func authFailedPermanent() async {
        let events = ScriptedTranscriptEventsClient()
        await events.enqueue(.failure(.authFailed(reason: "token expired")))
        let streamer = Self.makeStreamer(events: events, retries: [0, 0, 0])
        await Self.drive(streamer: streamer, segments: Self.segments(count: 1))
        let calls = await events.calls
        #expect(calls.count == 1, "authFailed should not retry")
    }

    // MARK: - Source errors

    @Test("source stream throws mid-flight → buffered tail still flushed")
    func sourceErrorFlushesBuffer() async {
        let events = ScriptedTranscriptEventsClient()
        let streamer = Self.makeStreamer(events: events)
        let segments = Self.failingSegments(
            yieldCount: 3,
            thenError: NSError(domain: "test", code: 42)
        )
        await Self.drive(streamer: streamer, segments: segments)
        let calls = await events.calls
        // 3 segments yielded before the source error — should be
        // flushed once as a final partial batch.
        #expect(calls.count == 1)
        #expect(calls.first?.events.count == 3)
    }

    // MARK: - Field mapping

    @Test("event_time = recording_started_at + segment.startTimeSeconds")
    func eventTimeOffset() async {
        let events = ScriptedTranscriptEventsClient()
        let streamer = Self.makeStreamer(events: events)
        await Self.drive(streamer: streamer, segments: Self.segments(count: 1))
        let calls = await events.calls
        let eventTime = calls.first?.events.first?.eventTime ?? ""
        // segment 0 has startTimeSeconds = 0; eventTime should match
        // recording_started_at to the second.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = formatter.date(from: eventTime)
        #expect(parsed != nil, "event_time must parse as ISO 8601 with fractional seconds")
        if let parsed {
            #expect(abs(parsed.timeIntervalSince(Self.recordingStartedAt)) < 0.01)
        }
    }
}
