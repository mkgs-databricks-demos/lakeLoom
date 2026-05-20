import Foundation
import Testing

@testable import LakeloomApp

@Suite("LiveCaptureService — persistence + recovery")
struct CaptureServicePersistenceTests {

    private static let workspaceID = "ws-1"
    private static let projectID = "proj-1"
    private static let captureID = "cap-1"
    private static let uploadID = "upload-fixed"
    private static let fixedNow = Date(timeIntervalSince1970: 1_715_770_800)

    // MARK: Helpers

    private struct Bundle {
        let service: LiveCaptureService
        let api: FakeCaptureAPIClient
        let recorder: FakeAudioRecorder
        let uploads: FakeUploadCoordinator
        let store: CaptureContextStore
        let storeURL: URL
    }

    private static func makeBundle() -> Bundle {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lakeloom-svc-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("active-capture.json", isDirectory: false)
        let store = CaptureContextStore(fileURL: storeURL)
        let api = FakeCaptureAPIClient()
        let recorder = FakeAudioRecorder()
        let uploads = FakeUploadCoordinator()
        let service = LiveCaptureService(
            captureAPI: api,
            recorder: recorder,
            uploadCoordinator: uploads,
            contextStore: store,
            nowProvider: { fixedNow },
            uploadIDProvider: { uploadID },
            fileHasher: { _ in "deadbeef" }
        )
        return Bundle(service: service, api: api, recorder: recorder, uploads: uploads, store: store, storeURL: storeURL)
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

    private static func samplePending(id: String, state: PendingUpload.State) -> PendingUpload {
        PendingUpload(
            id: id,
            workspaceID: workspaceID,
            captureSessionID: captureID,
            kind: .audio,
            localFileURL: URL(fileURLWithPath: "/tmp/x.m4a"),
            mimeType: "audio/mp4",
            sizeBytes: 1,
            sha256Hex: "deadbeef",
            clientTimestamp: fixedNow,
            originalFilename: "x.m4a",
            createdAt: fixedNow,
            state: state
        )
    }

    private static func writeFixtureAudioFile() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lakeloom-svc-fixture-\(UUID().uuidString).m4a")
        try? Data([0x01]).write(to: url)
        return url
    }

    // MARK: Save on transitions

    @Test("startCapture persists a .recording snapshot")
    func startPersistsRecording() async throws {
        let bundle = Self.makeBundle()
        await bundle.api.enqueueCreateResult(.success(Self.captureSession()))
        try await bundle.service.startCapture(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            label: nil
        )
        let snapshot = await bundle.store.load()
        #expect(snapshot != nil)
        #expect(snapshot?.captureSessionID == Self.captureID)
        #expect(snapshot?.phase == .recording)
        #expect(snapshot?.pendingUploadIDs.isEmpty == true)
    }

    @Test("stopCapture persists a .finalizing snapshot with pending IDs")
    func stopPersistsFinalizing() async throws {
        let bundle = Self.makeBundle()
        await bundle.api.enqueueCreateResult(.success(Self.captureSession()))
        let fixtureURL = Self.writeFixtureAudioFile()
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

        let snapshot = await bundle.store.load()
        #expect(snapshot?.phase == .finalizing)
        #expect(snapshot?.pendingUploadIDs == [Self.uploadID])
    }

    @Test("upload .succeeded clears the snapshot on transition to .completed")
    func completedClearsSnapshot() async throws {
        let bundle = Self.makeBundle()
        await bundle.api.enqueueCreateResult(.success(Self.captureSession()))
        let fixtureURL = Self.writeFixtureAudioFile()
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
        _ = await iterator.next() // initial .idle replay

        try await bundle.service.startCapture(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            label: nil
        )
        try await bundle.service.stopCapture()
        await bundle.uploads.emit(Self.uploadID, state: .succeeded)

        // Wait for transition to .completed.
        var seen: CaptureServiceState?
        for _ in 0..<6 {
            if let change = await iterator.next() {
                seen = change
                if case .completed = change { break }
            }
        }
        guard case .completed = seen else {
            Issue.record("expected .completed, got \(String(describing: seen))")
            return
        }

        let snapshot = await bundle.store.load()
        #expect(snapshot == nil)
    }

    @Test("cancelCapture from .recording clears the snapshot")
    func cancelFromRecordingClears() async throws {
        let bundle = Self.makeBundle()
        await bundle.api.enqueueCreateResult(.success(Self.captureSession()))
        try await bundle.service.startCapture(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            label: nil
        )
        #expect(await bundle.store.load() != nil)

        try await bundle.service.cancelCapture()
        #expect(await bundle.store.load() == nil)
    }

    @Test("cancelCapture from .finalizing clears the snapshot")
    func cancelFromFinalizingClears() async throws {
        let bundle = Self.makeBundle()
        await bundle.api.enqueueCreateResult(.success(Self.captureSession()))
        let fixtureURL = Self.writeFixtureAudioFile()
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
        #expect(await bundle.store.load()?.phase == .finalizing)

        try await bundle.service.cancelCapture()
        #expect(await bundle.store.load() == nil)
    }

    // MARK: Recovery

    @Test("start() with no snapshot is a no-op for capture context")
    func recoverNoSnapshot() async throws {
        let bundle = Self.makeBundle()
        await bundle.service.start()
        let state = await bundle.service.state
        if case .idle = state { /* ok */ } else {
            Issue.record("expected .idle, got \(state)")
        }
    }

    @Test("start() with .recording snapshot patches server .cancelled and clears")
    func recoverRecordingOrphan() async throws {
        let bundle = Self.makeBundle()
        try await bundle.store.save(PersistedCaptureContext(
            captureSessionID: Self.captureID,
            projectID: Self.projectID,
            workspaceID: Self.workspaceID,
            startedAt: Self.fixedNow,
            phase: .recording,
            pendingUploadIDs: []
        ))

        await bundle.service.start()

        let updates = await bundle.api.updateCalls
        #expect(updates.contains(where: { $0.state == .cancelled && $0.captureSessionID == Self.captureID }))
        #expect(await bundle.store.load() == nil)
    }

    @Test("start() with .finalizing + all uploads succeeded → server .completed + clears")
    func recoverFinalizingAllDone() async throws {
        let bundle = Self.makeBundle()
        try await bundle.store.save(PersistedCaptureContext(
            captureSessionID: Self.captureID,
            projectID: Self.projectID,
            workspaceID: Self.workspaceID,
            startedAt: Self.fixedNow,
            phase: .finalizing,
            pendingUploadIDs: ["u-1", "u-2"]
        ))
        await bundle.uploads.setStoredUploads([
            Self.samplePending(id: "u-1", state: .succeeded),
            Self.samplePending(id: "u-2", state: .succeeded)
        ])

        await bundle.service.start()

        let updates = await bundle.api.updateCalls
        #expect(updates.contains(where: { $0.state == .completed && $0.captureSessionID == Self.captureID }))
        #expect(await bundle.store.load() == nil)
    }

    @Test("start() with .finalizing + some uploads pending re-attaches watcher")
    func recoverFinalizingReattachesWatcher() async throws {
        let bundle = Self.makeBundle()
        try await bundle.store.save(PersistedCaptureContext(
            captureSessionID: Self.captureID,
            projectID: Self.projectID,
            workspaceID: Self.workspaceID,
            startedAt: Self.fixedNow,
            phase: .finalizing,
            pendingUploadIDs: ["u-1"]
        ))
        await bundle.uploads.setStoredUploads([
            Self.samplePending(id: "u-1", state: .queued)
        ])

        let stream = await bundle.service.stateUpdates()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // initial .idle replay

        await bundle.service.start()

        // After start(), state should be .finalizing with u-1 still pending.
        var seenFinalizing = false
        for _ in 0..<4 {
            if let change = await iterator.next() {
                if case .finalizing(_, let pending) = change, pending == ["u-1"] {
                    seenFinalizing = true
                    break
                }
            }
        }
        #expect(seenFinalizing)

        // Snapshot still on disk (still in flight).
        #expect(await bundle.store.load()?.phase == .finalizing)

        // Drive the upload to .succeeded — watcher should patch to .completed + clear.
        await bundle.uploads.emit("u-1", state: .succeeded)

        var seenCompleted = false
        for _ in 0..<5 {
            if let change = await iterator.next() {
                if case .completed = change { seenCompleted = true; break }
            }
        }
        #expect(seenCompleted)

        let updates = await bundle.api.updateCalls
        #expect(updates.contains(where: { $0.state == .completed }))
        #expect(await bundle.store.load() == nil)
    }
}
