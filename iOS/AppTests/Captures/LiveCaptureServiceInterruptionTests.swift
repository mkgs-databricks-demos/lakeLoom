import Foundation
import Testing

@testable import LakeloomApp

@Suite("LiveCaptureService — interruption broadcasting")
struct LiveCaptureServiceInterruptionTests {

    private static let workspaceID = "ws-1"
    private static let projectID = "proj-1"
    private static let captureID = "cap-1"
    private static let fixedNow = Date(timeIntervalSince1970: 1_747_152_120)

    @MainActor
    private static func makeService(
        api: FakeCaptureAPIClient,
        recorder: FakeAudioRecorder,
        uploads: FakeUploadCoordinator,
        publisher: any AudioInterruptionPublishing,
        nowPlaying: any NowPlayingControlling
    ) -> LiveCaptureService {
        LiveCaptureService(
            captureAPI: api,
            recorder: recorder,
            uploadCoordinator: uploads,
            interruptionPublisher: publisher,
            nowPlaying: nowPlaying,
            nowProvider: { fixedNow },
            uploadIDProvider: { "u-1" },
            fileHasher: { _ in "deadbeef" }
        )
    }

    private static func session() -> CaptureSession {
        CaptureSession(
            id: captureID,
            projectID: projectID,
            state: .active,
            label: "Kickoff",
            startedAt: fixedNow,
            endedAt: nil
        )
    }

    /// Drain the service's `interruptionUpdates()` stream until it
    /// yields the expected value (or times out). Returns the matched
    /// value or nil.
    private static func waitFor(
        stream: AsyncStream<Bool>,
        equals target: Bool,
        max: Int = 8
    ) async -> Bool? {
        var iterator = stream.makeAsyncIterator()
        for _ in 0..<max {
            guard let next = await iterator.next() else { return nil }
            if next == target { return next }
        }
        return nil
    }

    @Test("startCapture wires Now Playing + interruption listener")
    func startWiresController() async throws {
        let api = FakeCaptureAPIClient()
        await api.enqueueCreateResult(.success(Self.session()))
        let recorder = FakeAudioRecorder()
        let uploads = FakeUploadCoordinator()
        let publisher = FakeAudioInterruptionPublisher()
        let spy = await SpyNowPlayingController()

        let service = await Self.makeService(
            api: api,
            recorder: recorder,
            uploads: uploads,
            publisher: publisher,
            nowPlaying: spy
        )

        try await service.startCapture(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            label: "Kickoff"
        )

        // Give the actor + main-actor hop a chance to run start().
        try await Task.sleep(nanoseconds: 50_000_000)
        let calls = await spy.calls
        // First call should be .start(label: "Kickoff", …).
        guard case .start(let label, _) = calls.first else {
            Issue.record("expected .start as first NowPlaying call, got \(calls)")
            return
        }
        #expect(label == "Kickoff")

        // Clean up so the tick task doesn't keep running across tests.
        try await service.cancelCapture()
    }

    @Test("engine interruption true broadcasts to subscribers + spy")
    func interruptionTrueFansOut() async throws {
        let api = FakeCaptureAPIClient()
        await api.enqueueCreateResult(.success(Self.session()))
        let recorder = FakeAudioRecorder()
        let uploads = FakeUploadCoordinator()
        let publisher = FakeAudioInterruptionPublisher()
        let spy = await SpyNowPlayingController()

        let service = await Self.makeService(
            api: api,
            recorder: recorder,
            uploads: uploads,
            publisher: publisher,
            nowPlaying: spy
        )

        try await service.startCapture(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            label: "Kickoff"
        )

        // Subscribe to the service's broadcast stream AFTER start so
        // the listener task has already attached to the publisher.
        let updates = await service.interruptionUpdates()

        await publisher.yield(true)

        let observed = await Self.waitFor(stream: updates, equals: true)
        #expect(observed == true)

        // The Now Playing spy should also have seen setInterrupted(true).
        // Brief sleep lets the @MainActor hop through.
        try await Task.sleep(nanoseconds: 100_000_000)
        let calls = await spy.calls
        #expect(calls.contains(.setInterrupted(true)))

        try await service.cancelCapture()
    }

    @Test("cancelCapture clears Now Playing + ends interruption stream")
    func cancelTearsDown() async throws {
        let api = FakeCaptureAPIClient()
        await api.enqueueCreateResult(.success(Self.session()))
        let recorder = FakeAudioRecorder()
        let uploads = FakeUploadCoordinator()
        let publisher = FakeAudioInterruptionPublisher()
        let spy = await SpyNowPlayingController()

        let service = await Self.makeService(
            api: api,
            recorder: recorder,
            uploads: uploads,
            publisher: publisher,
            nowPlaying: spy
        )

        try await service.startCapture(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            label: nil
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        try await service.cancelCapture()
        try await Task.sleep(nanoseconds: 50_000_000)

        let calls = await spy.calls
        #expect(calls.contains(.stop))
    }
}
