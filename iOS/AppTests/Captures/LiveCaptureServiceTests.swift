import Foundation
import Testing

@testable import LakeloomApp

@Suite("LiveCaptureService — full lifecycle")
struct LiveCaptureServiceTests {

    private static let workspaceID = "ws-1"
    private static let projectID = "proj-1"
    private static let captureID = "cap-1"
    private static let uploadID = "upload-fixed"
    private static let fixedNow = Date(timeIntervalSince1970: 1_747_152_120)

    // MARK: Helpers

    private struct Bundle {
        let service: LiveCaptureService
        let api: FakeCaptureAPIClient
        let recorder: FakeAudioRecorder
        let uploads: FakeUploadCoordinator
    }

    private static func makeBundle(
        clock: @Sendable @escaping () -> Date = { LiveCaptureServiceTests.fixedNow },
        uploadID: String = LiveCaptureServiceTests.uploadID,
        hash: @Sendable @escaping (URL) throws -> String = { _ in "deadbeef" }
    ) -> Bundle {
        let api = FakeCaptureAPIClient()
        let recorder = FakeAudioRecorder()
        let uploads = FakeUploadCoordinator()
        let service = LiveCaptureService(
            captureAPI: api,
            recorder: recorder,
            uploadCoordinator: uploads,
            nowProvider: clock,
            uploadIDProvider: { uploadID },
            fileHasher: hash
        )
        return Bundle(service: service, api: api, recorder: recorder, uploads: uploads)
    }

    private static func captureSession(id: String = captureID, projectID: String = projectID) -> CaptureSession {
        CaptureSession(
            id: id,
            projectID: projectID,
            state: .active,
            label: "Kickoff",
            startedAt: fixedNow,
            endedAt: nil
        )
    }

    /// Wait until `state` matches `predicate`, draining the stream.
    /// Returns the matching state or `nil` if the stream ends first.
    private static func awaitState(
        from iterator: inout AsyncStream<CaptureServiceState>.Iterator,
        matching predicate: @Sendable (CaptureServiceState) -> Bool,
        maxStates: Int = 8
    ) async -> CaptureServiceState? {
        var seen = 0
        while seen < maxStates, let state = await iterator.next() {
            seen += 1
            if predicate(state) { return state }
        }
        return nil
    }

    // MARK: Happy path

    @Test("startCapture creates session + starts recorder + transitions to .recording")
    func startCaptureHappy() async throws {
        let bundle = Self.makeBundle()
        await bundle.api.enqueueCreateResult(.success(Self.captureSession()))

        let stream = await bundle.service.stateUpdates()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // initial replayed .idle

        try await bundle.service.startCapture(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            label: "Kickoff"
        )

        let recording = await Self.awaitState(from: &iterator) { state in
            if case .recording = state { return true }
            return false
        }
        guard case .recording(let context) = recording else {
            Issue.record("expected .recording, got \(String(describing: recording))")
            return
        }
        #expect(context.captureSessionID == Self.captureID)
        #expect(context.projectID == Self.projectID)
        #expect(context.workspaceID == Self.workspaceID)

        let createCalls = await bundle.api.createCalls
        #expect(createCalls.first?.projectID == Self.projectID)
        let recorderCalls = await bundle.recorder.calls
        #expect(recorderCalls.first == .start(Self.captureID))
    }

    @Test("stopCapture enqueues upload + transitions to .finalizing")
    func stopCaptureEnqueues() async throws {
        let bundle = Self.makeBundle()
        await bundle.api.enqueueCreateResult(.success(Self.captureSession()))
        let fixtureURL = URL(fileURLWithPath: "/tmp/lakeloom-test-\(UUID().uuidString).m4a")
        try Data([0x01, 0x02, 0x03]).write(to: fixtureURL)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        await bundle.recorder.setFakeURL(fixtureURL)
        await bundle.recorder.setFakeRecording(AudioRecording(
            captureSessionID: Self.captureID,
            fileURL: fixtureURL,
            startedAt: Self.fixedNow,
            endedAt: Self.fixedNow.addingTimeInterval(60),
            durationSeconds: 60,
            sizeBytes: 3,
            mimeType: "audio/mp4",
            fileExtension: "m4a"
        ))

        try await bundle.service.startCapture(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            label: nil
        )
        try await bundle.service.stopCapture()

        let calls = await bundle.uploads.calls
        #expect(calls.contains(.enqueue(uploadID: Self.uploadID, captureSessionID: Self.captureID)))

        let snapshot = await bundle.service.state
        guard case .finalizing(let context, let pending) = snapshot else {
            Issue.record("expected .finalizing, got \(snapshot)")
            return
        }
        #expect(context.captureSessionID == Self.captureID)
        #expect(pending == [Self.uploadID])
    }

    @Test("upload .succeeded drains pending set → patches server + .completed")
    func uploadDrainsToCompleted() async throws {
        let bundle = Self.makeBundle()
        await bundle.api.enqueueCreateResult(.success(Self.captureSession()))
        let fixtureURL = URL(fileURLWithPath: "/tmp/lakeloom-test-\(UUID().uuidString).m4a")
        try Data([0xFF]).write(to: fixtureURL)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        await bundle.recorder.setFakeURL(fixtureURL)
        await bundle.recorder.setFakeRecording(AudioRecording(
            captureSessionID: Self.captureID,
            fileURL: fixtureURL,
            startedAt: Self.fixedNow,
            endedAt: Self.fixedNow,
            durationSeconds: 1,
            sizeBytes: 1,
            mimeType: "audio/mp4",
            fileExtension: "m4a"
        ))

        let stream = await bundle.service.stateUpdates()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // initial .idle

        try await bundle.service.startCapture(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            label: nil
        )
        try await bundle.service.stopCapture()

        // Drive the watcher: simulate the upload reaching .succeeded.
        await bundle.uploads.emit(Self.uploadID, state: .succeeded)

        let completed = await Self.awaitState(from: &iterator) { state in
            if case .completed = state { return true }
            return false
        }
        guard case .completed(let context) = completed else {
            Issue.record("expected .completed, got \(String(describing: completed))")
            return
        }
        #expect(context.captureSessionID == Self.captureID)

        // Server-side PATCH .completed fired.
        let updates = await bundle.api.updateCalls
        #expect(updates.contains(where: { $0.state == .completed && $0.captureSessionID == Self.captureID }))
    }

    // MARK: Cancel

    @Test("cancelCapture from .recording cancels recorder + patches server .cancelled")
    func cancelFromRecording() async throws {
        let bundle = Self.makeBundle()
        await bundle.api.enqueueCreateResult(.success(Self.captureSession()))

        try await bundle.service.startCapture(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            label: nil
        )
        try await bundle.service.cancelCapture()

        let recorderCalls = await bundle.recorder.calls
        #expect(recorderCalls.contains(.cancel))
        let updates = await bundle.api.updateCalls
        #expect(updates.contains(where: { $0.state == .cancelled }))

        let final = await bundle.service.state
        guard case .cancelled = final else {
            Issue.record("expected .cancelled, got \(final)")
            return
        }
    }

    @Test("cancelCapture from .finalizing discards pending uploads + patches server .cancelled")
    func cancelFromFinalizing() async throws {
        let bundle = Self.makeBundle()
        await bundle.api.enqueueCreateResult(.success(Self.captureSession()))
        let fixtureURL = URL(fileURLWithPath: "/tmp/lakeloom-test-\(UUID().uuidString).m4a")
        try Data([0x00]).write(to: fixtureURL)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        await bundle.recorder.setFakeURL(fixtureURL)
        await bundle.recorder.setFakeRecording(AudioRecording(
            captureSessionID: Self.captureID,
            fileURL: fixtureURL,
            startedAt: Self.fixedNow,
            endedAt: Self.fixedNow,
            durationSeconds: 1,
            sizeBytes: 1,
            mimeType: "audio/mp4",
            fileExtension: "m4a"
        ))

        try await bundle.service.startCapture(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            label: nil
        )
        try await bundle.service.stopCapture()
        try await bundle.service.cancelCapture()

        let calls = await bundle.uploads.calls
        #expect(calls.contains(.discard(uploadID: Self.uploadID)))
        let updates = await bundle.api.updateCalls
        #expect(updates.contains(where: { $0.state == .cancelled }))

        let final = await bundle.service.state
        guard case .cancelled = final else {
            Issue.record("expected .cancelled, got \(final)")
            return
        }
    }

    // MARK: Error paths

    @Test("createCaptureSession failure surfaces createSessionFailed + state .failed")
    func createSessionFails() async throws {
        let bundle = Self.makeBundle()
        await bundle.api.enqueueCreateResult(.failure(.networkUnavailable))

        await #expect(throws: CaptureServiceError.createSessionFailed(reason: "networkUnavailable")) {
            try await bundle.service.startCapture(
                workspaceID: Self.workspaceID,
                projectID: Self.projectID,
                label: nil
            )
        }
        let snapshot = await bundle.service.state
        guard case .failed = snapshot else {
            Issue.record("expected .failed, got \(snapshot)")
            return
        }
    }

    @Test("recorder.start failure rolls back server session via .cancelled patch")
    func recorderStartRollsBack() async throws {
        let bundle = Self.makeBundle()
        await bundle.api.enqueueCreateResult(.success(Self.captureSession()))
        await bundle.recorder.setStartError(AudioRecorderError.permissionDenied)

        await #expect(throws: CaptureServiceError.recorderStartFailed(reason: "permissionDenied")) {
            try await bundle.service.startCapture(
                workspaceID: Self.workspaceID,
                projectID: Self.projectID,
                label: nil
            )
        }
        let updates = await bundle.api.updateCalls
        #expect(updates.contains(where: { $0.state == .cancelled && $0.captureSessionID == Self.captureID }))
    }

    @Test("startCapture rejects a second start while in .recording")
    func cannotStartWhileRecording() async throws {
        let bundle = Self.makeBundle()
        await bundle.api.enqueueCreateResult(.success(Self.captureSession()))
        try await bundle.service.startCapture(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            label: nil
        )
        await #expect(throws: CaptureServiceError.alreadyCapturing) {
            try await bundle.service.startCapture(
                workspaceID: Self.workspaceID,
                projectID: Self.projectID,
                label: nil
            )
        }
    }

    @Test("stopCapture from .idle throws notRecording")
    func stopFromIdle() async {
        let bundle = Self.makeBundle()
        await #expect(throws: CaptureServiceError.notRecording) {
            try await bundle.service.stopCapture()
        }
    }

    @Test("startCapture is allowed again after a .completed capture")
    func canStartAfterCompleted() async throws {
        let bundle = Self.makeBundle()
        await bundle.api.enqueueCreateResult(.success(Self.captureSession(id: "cap-1")))
        await bundle.api.enqueueCreateResult(.success(Self.captureSession(id: "cap-2")))

        let fixtureURL = URL(fileURLWithPath: "/tmp/lakeloom-test-\(UUID().uuidString).m4a")
        try Data([0x00]).write(to: fixtureURL)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        await bundle.recorder.setFakeURL(fixtureURL)
        await bundle.recorder.setFakeRecording(AudioRecording(
            captureSessionID: "cap-1",
            fileURL: fixtureURL,
            startedAt: Self.fixedNow,
            endedAt: Self.fixedNow,
            durationSeconds: 1,
            sizeBytes: 1,
            mimeType: "audio/mp4",
            fileExtension: "m4a"
        ))

        try await bundle.service.startCapture(workspaceID: Self.workspaceID, projectID: Self.projectID, label: nil)
        try await bundle.service.stopCapture()
        await bundle.uploads.emit(Self.uploadID, state: .succeeded)

        // Wait a tick for the watcher to transition to .completed.
        let stream = await bundle.service.stateUpdates()
        var iterator = stream.makeAsyncIterator()
        _ = await Self.awaitState(from: &iterator) { state in
            if case .completed = state { return true }
            return false
        }

        try await bundle.service.startCapture(workspaceID: Self.workspaceID, projectID: Self.projectID, label: nil)
        let snapshot = await bundle.service.state
        guard case .recording = snapshot else {
            Issue.record("expected .recording after restart, got \(snapshot)")
            return
        }
    }
}
