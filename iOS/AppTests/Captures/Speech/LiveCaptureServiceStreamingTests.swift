import Foundation
import Testing

@testable import LakeloomApp

/// File-local fake events client — records every batch send.
private actor RecordingTranscriptEventsClient: TranscriptEventsClient {
    struct SendCall: Sendable, Equatable {
        let count: Int
        let pairedSessionID: String
    }
    private(set) var calls: [SendCall] = []
    private(set) var lastBatch: [TranscriptEvent] = []
    func sendEvents(
        workspaceID: String,
        pairedSessionID: String,
        events: [TranscriptEvent]
    ) async throws -> Int {
        calls.append(SendCall(count: events.count, pairedSessionID: pairedSessionID))
        lastBatch = events
        return events.count
    }
}

@Suite("LiveCaptureService — streaming speech recognizer wiring")
struct LiveCaptureServiceStreamingTests {

    private static let workspaceID = "ws-1"
    private static let projectID = "proj-1"
    private static let captureID = "cap-1"
    private static let uploadID = "upload-fixed"
    private static let pairedSessionID = "paired-stream"
    private static let deviceID = "device-uuid-stream"
    private static let fixedNow = Date(timeIntervalSince1970: 1_747_152_120)

    private struct Bundle {
        let service: LiveCaptureService
        let api: FakeCaptureAPIClient
        let recorder: FakeAudioRecorder
        let uploads: FakeUploadCoordinator
        let streaming: FakeStreamingSpeechRecognizer
        let events: RecordingTranscriptEventsClient
    }

    private static func makeBundle() -> Bundle {
        let api = FakeCaptureAPIClient()
        let recorder = FakeAudioRecorder()
        let uploads = FakeUploadCoordinator()
        let streaming = FakeStreamingSpeechRecognizer()
        let events = RecordingTranscriptEventsClient()
        let streamer = LiveTranscriptStreamer(
            events: events,
            maxBatchSize: 100,
            retryBackoffSeconds: [0],
            logger: AppLogger(category: .capture),
            sleep: { _ in }
        )
        let provider: @Sendable () async -> String? = { Self.pairedSessionID }
        let deviceStore = InMemoryDeviceIdentityStore(preloaded: Self.deviceID)
        let service = LiveCaptureService(
            captureAPI: api,
            recorder: recorder,
            uploadCoordinator: uploads,
            deviceIdentity: deviceStore,
            speechTranscriber: nil, // no fallback path
            transcriptStreamer: streamer,
            streamingRecognizer: streaming,
            pairedSessionIDProvider: provider,
            nowProvider: { Self.fixedNow },
            uploadIDProvider: { Self.uploadID },
            fileHasher: { _ in "deadbeef" }
        )
        return Bundle(
            service: service,
            api: api,
            recorder: recorder,
            uploads: uploads,
            streaming: streaming,
            events: events
        )
    }

    private static func captureSession() -> CaptureSession {
        CaptureSession(
            id: captureID,
            projectID: projectID,
            state: .active,
            label: "Live",
            startedAt: fixedNow,
            endedAt: nil
        )
    }

    private static func fixtureRecording() -> (URL, AudioRecording) {
        let fixtureURL = URL(fileURLWithPath: "/tmp/lakeloom-test-\(UUID().uuidString).m4a")
        try? Data([0x01, 0x02, 0x03]).write(to: fixtureURL)
        let recording = AudioRecording(
            captureSessionID: captureID,
            fileURL: fixtureURL,
            startedAt: fixedNow,
            endedAt: fixedNow.addingTimeInterval(10),
            durationSeconds: 10,
            sizeBytes: 3,
            mimeType: "audio/mp4",
            fileExtension: "m4a"
        )
        return (fixtureURL, recording)
    }

    // MARK: - Tests

    @Test("startCapture fires the streaming recognizer; stopCapture stops it and drains segments")
    func liveSegmentsFlowEndToEnd() async throws {
        let bundle = Self.makeBundle()
        await bundle.api.enqueueCreateResult(.success(Self.captureSession()))
        let (fixtureURL, recording) = Self.fixtureRecording()
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        await bundle.recorder.setFakeURL(fixtureURL)
        await bundle.recorder.setFakeRecording(recording)

        try await bundle.service.startCapture(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            label: nil
        )

        // Wait for the background drain Task to have asked the fake
        // for transcripts(). It dispatches off the capture actor
        // immediately after startCapture returns but may not have
        // run yet by the time we get here.
        for _ in 0..<50 {
            if await bundle.streaming.transcriptsCallCount > 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let starts = await bundle.streaming.transcriptsCallCount
        #expect(starts == 1)

        // Emit a couple of segments as if they came in live during
        // the recording.
        await bundle.streaming.emit(TranscriptSegment(
            text: "hello there",
            confidence: 0.95,
            segmentIndex: 0,
            durationMs: 800,
            startTimeSeconds: 0.5
        ))
        await bundle.streaming.emit(TranscriptSegment(
            text: "general kenobi",
            confidence: 0.92,
            segmentIndex: 1,
            durationMs: 900,
            startTimeSeconds: 1.4
        ))

        try await bundle.service.stopCapture()

        // stop() called exactly once, before the recorder stopped.
        let stops = await bundle.streaming.stopCallCount
        #expect(stops == 1)

        // The streamer should have flushed both segments in a
        // single batch on stream end.
        let calls = await bundle.events.calls
        #expect(calls.count == 1)
        #expect(calls.first?.count == 2)
        let batch = await bundle.events.lastBatch
        #expect(batch.map(\.text) == ["hello there", "general kenobi"])
        #expect(batch.allSatisfy { $0.source == "on_device_live" })
        #expect(batch.allSatisfy { $0.model == "sf_speech_streaming" })
        #expect(batch.allSatisfy { $0.deviceID == Self.deviceID })
        #expect(batch.allSatisfy { $0.projectID == Self.projectID })
    }

    @Test("cancelCapture from .recording stops streaming + cancels the drain task")
    func cancelDuringStreamingTearsDownCleanly() async throws {
        let bundle = Self.makeBundle()
        await bundle.api.enqueueCreateResult(.success(Self.captureSession()))

        try await bundle.service.startCapture(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            label: nil
        )

        try await bundle.service.cancelCapture()

        let stops = await bundle.streaming.stopCallCount
        #expect(stops == 1)
        let state = await bundle.service.state
        if case .cancelled = state {} else {
            Issue.record("expected .cancelled, got \(state)")
        }
    }

    @Test("streaming recognizer throw on transcripts() doesn't fail the capture")
    func streamingStartFailureSwallowed() async throws {
        let bundle = Self.makeBundle()
        await bundle.api.enqueueCreateResult(.success(Self.captureSession()))
        let (fixtureURL, recording) = Self.fixtureRecording()
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        await bundle.recorder.setFakeURL(fixtureURL)
        await bundle.recorder.setFakeRecording(recording)
        await bundle.streaming.setFailureOnTranscripts(SpeechTranscriberError.permissionDenied)

        try await bundle.service.startCapture(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            label: nil
        )
        // stopCapture should NOT throw — even though the streaming
        // recognizer failed to start, the recorder + upload paths
        // proceed normally.
        try await bundle.service.stopCapture()

        let state = await bundle.service.state
        if case .failed = state {
            Issue.record("transient speech failure should not fail the capture; got \(state)")
        }
        let events = await bundle.events.calls
        #expect(events.isEmpty, "no segments to send when recognizer failed to start")
    }
}
