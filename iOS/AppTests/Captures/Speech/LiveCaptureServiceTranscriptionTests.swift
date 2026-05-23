import Foundation
import Testing

@testable import LakeloomApp

/// File-local fake transcript events client. Records every send so
/// the test can assert what LiveCaptureService forwarded.
private actor RecordingTranscriptEventsClient: TranscriptEventsClient {

    struct SendCall: Sendable, Equatable {
        let pairedSessionID: String
        let event: TranscriptEvent
    }

    private(set) var calls: [SendCall] = []

    func sendEvents(
        workspaceID: String,
        pairedSessionID: String,
        events: [TranscriptEvent]
    ) async throws -> Int {
        for event in events {
            calls.append(SendCall(pairedSessionID: pairedSessionID, event: event))
        }
        return events.count
    }
}

@Suite("LiveCaptureService — speech transcription forwarding")
struct LiveCaptureServiceTranscriptionTests {

    private static let workspaceID = "ws-1"
    private static let projectID = "proj-1"
    private static let captureID = "cap-1"
    private static let uploadID = "upload-fixed"
    private static let pairedSessionID = "paired-123"
    private static let deviceID = "device-uuid-aaaa"
    private static let fixedNow = Date(timeIntervalSince1970: 1_747_152_120)

    private struct Bundle {
        let service: LiveCaptureService
        let api: FakeCaptureAPIClient
        let recorder: FakeAudioRecorder
        let uploads: FakeUploadCoordinator
        let transcriber: FakeSpeechTranscriber
        let transcriptEvents: RecordingTranscriptEventsClient
    }

    private static func makeBundle() -> Bundle {
        let api = FakeCaptureAPIClient()
        let recorder = FakeAudioRecorder()
        let uploads = FakeUploadCoordinator()
        let transcriber = FakeSpeechTranscriber()
        let transcriptEvents = RecordingTranscriptEventsClient()
        let pairedSessionID = Self.pairedSessionID
        let provider: @Sendable () async -> String? = { pairedSessionID }
        let deviceStore = InMemoryDeviceIdentityStore(preloaded: Self.deviceID)
        let service = LiveCaptureService(
            captureAPI: api,
            recorder: recorder,
            uploadCoordinator: uploads,
            deviceIdentity: deviceStore,
            speechTranscriber: transcriber,
            transcriptEvents: transcriptEvents,
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
            transcriber: transcriber,
            transcriptEvents: transcriptEvents
        )
    }

    private static func captureSession() -> CaptureSession {
        CaptureSession(
            id: captureID,
            projectID: projectID,
            state: .active,
            label: "Kickoff",
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

    /// Spin until the fake events client has at least `n` calls, or
    /// give up after `attempts`. Each attempt yields the actor so
    /// the background transcription Task can make progress.
    private static func waitForEvents(
        on client: RecordingTranscriptEventsClient,
        atLeast n: Int,
        attempts: Int = 30
    ) async -> [RecordingTranscriptEventsClient.SendCall] {
        for _ in 0..<attempts {
            let snapshot = await client.calls
            if snapshot.count >= n { return snapshot }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await client.calls
    }

    // MARK: - Happy path

    @Test("stopCapture fires transcription → each segment becomes a final_transcript event")
    func segmentsForwarded() async throws {
        let bundle = Self.makeBundle()
        await bundle.api.enqueueCreateResult(.success(Self.captureSession()))
        let (fixtureURL, recording) = Self.fixtureRecording()
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        await bundle.recorder.setFakeURL(fixtureURL)
        await bundle.recorder.setFakeRecording(recording)
        await bundle.transcriber.enqueueSegments([
            TranscriptSegment(
                text: "hello",
                confidence: 0.92,
                segmentIndex: 0,
                durationMs: 600,
                startTimeSeconds: 0.5
            ),
            TranscriptSegment(
                text: "world",
                confidence: 0.88,
                segmentIndex: 1,
                durationMs: 700,
                startTimeSeconds: 1.2
            )
        ])

        try await bundle.service.startCapture(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            label: nil
        )
        try await bundle.service.stopCapture()

        let events = await Self.waitForEvents(on: bundle.transcriptEvents, atLeast: 2)
        #expect(events.count == 2)
        #expect(events[0].pairedSessionID == Self.pairedSessionID)
        #expect(events[0].event.eventType == .finalTranscript)
        #expect(events[0].event.text == "hello")
        #expect(events[0].event.segmentIndex == 0)
        #expect(events[0].event.confidence == 0.92)
        #expect(events[0].event.durationMs == 600)
        #expect(events[0].event.projectID == Self.projectID)
        #expect(events[0].event.deviceID == Self.deviceID)
        #expect(events[0].event.source == "on_device")
        #expect(events[0].event.model == "sf_speech_recognizer")
        #expect(events[0].event.language == "en-US")
        #expect(events[1].event.text == "world")
        #expect(events[1].event.segmentIndex == 1)

        // Transcriber called exactly once with the recorded file URL.
        let transcribeCalls = await bundle.transcriber.calls
        #expect(transcribeCalls.count == 1)
        #expect(transcribeCalls.first?.fileURL == fixtureURL)
    }

    @Test("nil pairedSessionID skips transcription emit entirely")
    func skipsWhenNoPairedSession() async throws {
        let api = FakeCaptureAPIClient()
        let recorder = FakeAudioRecorder()
        let uploads = FakeUploadCoordinator()
        let transcriber = FakeSpeechTranscriber()
        let transcriptEvents = RecordingTranscriptEventsClient()
        let provider: @Sendable () async -> String? = { nil }
        let service = LiveCaptureService(
            captureAPI: api,
            recorder: recorder,
            uploadCoordinator: uploads,
            speechTranscriber: transcriber,
            transcriptEvents: transcriptEvents,
            pairedSessionIDProvider: provider,
            nowProvider: { Self.fixedNow },
            uploadIDProvider: { Self.uploadID },
            fileHasher: { _ in "deadbeef" }
        )
        await api.enqueueCreateResult(.success(Self.captureSession()))
        let (fixtureURL, recording) = Self.fixtureRecording()
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        await recorder.setFakeURL(fixtureURL)
        await recorder.setFakeRecording(recording)
        await transcriber.enqueueSegments([
            TranscriptSegment(text: "hi", segmentIndex: 0, durationMs: 100, startTimeSeconds: 0)
        ])

        try await service.startCapture(workspaceID: Self.workspaceID, projectID: Self.projectID, label: nil)
        try await service.stopCapture()

        // Give the background Task a tick to run + bail out.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let events = await transcriptEvents.calls
        let transcribeCalls = await transcriber.calls
        #expect(events.isEmpty, "transcript_events sends should be skipped when paired session is nil")
        #expect(transcribeCalls.isEmpty, "transcriber should also be skipped — short-circuit before launching the work")
    }

    @Test("transcribe throw (e.g. permissionDenied) doesn't fail the capture")
    func transcribeFailureSwallowed() async throws {
        let bundle = Self.makeBundle()
        await bundle.api.enqueueCreateResult(.success(Self.captureSession()))
        let (fixtureURL, recording) = Self.fixtureRecording()
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        await bundle.recorder.setFakeURL(fixtureURL)
        await bundle.recorder.setFakeRecording(recording)
        await bundle.transcriber.enqueueFailure(SpeechTranscriberError.permissionDenied)

        try await bundle.service.startCapture(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            label: nil
        )
        // stopCapture must NOT throw — transcription failures stay
        // local to the background Task.
        try await bundle.service.stopCapture()

        try? await Task.sleep(nanoseconds: 100_000_000)
        let events = await bundle.transcriptEvents.calls
        #expect(events.isEmpty)
        let state = await bundle.service.state
        if case .failed = state {
            Issue.record("transcribe failure should not transition to .failed")
        }
    }
}
