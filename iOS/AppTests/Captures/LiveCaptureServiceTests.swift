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

        await #expect(throws: CaptureServiceError.createSessionNetworkUnavailable) {
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

        await #expect(throws: CaptureServiceError.microphonePermissionDenied) {
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

    // MARK: Multi-session / finalize de-wedge (offline field bug)

    /// Reproduces the onsite field bug: a long session stopped while
    /// offline sits in `.finalizing` (its uploads can't drain), and a
    /// second session must still be startable. The fix demotes the
    /// finalizing session to a background finalizer instead of throwing
    /// `alreadyCapturing`.
    @Test("startCapture while .finalizing demotes the draining session and starts fresh")
    func startWhileFinalizingDemotesAndStarts() async throws {
        let bundle = Self.makeBundle()
        await bundle.api.enqueueCreateResult(.success(Self.captureSession(id: "cap-A")))
        await bundle.api.enqueueCreateResult(.success(Self.captureSession(id: "cap-B")))

        let fixtureURL = URL(fileURLWithPath: "/tmp/lakeloom-test-\(UUID().uuidString).m4a")
        try Data([0x01, 0x02, 0x03]).write(to: fixtureURL)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        await bundle.recorder.setFakeURL(fixtureURL)
        await bundle.recorder.setFakeRecording(AudioRecording(
            captureSessionID: "cap-A",
            fileURL: fixtureURL,
            startedAt: Self.fixedNow,
            endedAt: Self.fixedNow.addingTimeInterval(3600),
            durationSeconds: 3600,
            sizeBytes: 3,
            mimeType: "audio/mp4",
            fileExtension: "m4a"
        ))

        // Session A: start + stop offline. The upload stays pending in
        // the fake queue (nothing drives it to .succeeded).
        try await bundle.service.startCapture(
            workspaceID: Self.workspaceID, projectID: Self.projectID, label: nil
        )
        try await bundle.service.stopCapture()
        guard case .finalizing(let ctxA, let pendingA) = await bundle.service.state else {
            Issue.record("expected .finalizing(cap-A) after stop, got \(await bundle.service.state)")
            return
        }
        #expect(ctxA.captureSessionID == "cap-A")
        #expect(!pendingA.isEmpty)

        // Session B: this is the line that used to throw
        // `alreadyCapturing` and wedge the device. It must succeed.
        try await bundle.service.startCapture(
            workspaceID: Self.workspaceID, projectID: Self.projectID, label: nil
        )
        guard case .recording(let ctxB) = await bundle.service.state else {
            Issue.record("expected .recording(cap-B), got \(await bundle.service.state)")
            return
        }
        #expect(ctxB.captureSessionID == "cap-B")

        // Session A's still-pending upload was demoted, never discarded.
        let calls = await bundle.uploads.calls
        #expect(!calls.contains(where: { if case .discard = $0 { return true }; return false }))
    }

    /// Once a demoted session's uploads drain (here: auto-retired out of
    /// the queue, simulating a reconnect), the background finalizer
    /// PATCHes it to `.completed` without disturbing the foreground
    /// recording.
    @Test("demoted session completes in the background when its uploads drain")
    func demotedSessionCompletesInBackground() async throws {
        let bundle = Self.makeBundle()
        await bundle.api.enqueueCreateResult(.success(Self.captureSession(id: "cap-A")))
        await bundle.api.enqueueCreateResult(.success(Self.captureSession(id: "cap-B")))

        let fixtureURL = URL(fileURLWithPath: "/tmp/lakeloom-test-\(UUID().uuidString).m4a")
        try Data([0x09]).write(to: fixtureURL)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        await bundle.recorder.setFakeURL(fixtureURL)
        await bundle.recorder.setFakeRecording(AudioRecording(
            captureSessionID: "cap-A",
            fileURL: fixtureURL,
            startedAt: Self.fixedNow,
            endedAt: Self.fixedNow.addingTimeInterval(60),
            durationSeconds: 60,
            sizeBytes: 1,
            mimeType: "audio/mp4",
            fileExtension: "m4a"
        ))

        try await bundle.service.startCapture(
            workspaceID: Self.workspaceID, projectID: Self.projectID, label: nil
        )
        try await bundle.service.stopCapture()

        // Simulate cap-A's upload having succeeded + been auto-retired
        // out of the queue before the new session starts. The
        // background finalizer's reconcile sees an empty pending set and
        // completes immediately.
        await bundle.uploads.setStoredUploads([])

        try await bundle.service.startCapture(
            workspaceID: Self.workspaceID, projectID: Self.projectID, label: nil
        )
        guard case .recording(let ctxB) = await bundle.service.state else {
            Issue.record("expected .recording(cap-B), got \(await bundle.service.state)")
            return
        }
        #expect(ctxB.captureSessionID == "cap-B")

        // The demoted cap-A drains to .completed on the background path.
        let completed = await Self.waitUntil {
            await bundle.api.updateCalls.contains {
                $0.captureSessionID == "cap-A" && $0.state == .completed
            }
        }
        #expect(completed)

        // The foreground recording was never patched — it's still live.
        let bPatched = await bundle.api.updateCalls.contains { $0.captureSessionID == "cap-B" }
        #expect(!bPatched)
    }

    /// Poll an async predicate until it's true or the budget elapses.
    /// Used to await a background Task's effect without reaching into
    /// the actor's private state.
    private static func waitUntil(
        tries: Int = 200,
        _ predicate: @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<tries {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
        }
        return false
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
