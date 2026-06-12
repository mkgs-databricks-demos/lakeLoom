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

    @Test("start() with .recording snapshot and no on-disk audio patches server .cancelled")
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

    @Test("start() with .recording snapshot AND on-disk audio resurrects uploads instead of cancelling")
    func recoverRecordingResurrectsAudio() async throws {
        // The FDE-in-field scenario: app died mid-recording with
        // audio files on disk. Recovery should enqueue every file
        // as a PendingUpload against the still-`.active` server
        // session and re-attach the finalize watcher — NOT patch
        // the server to `.cancelled` (the old behavior, which lost
        // the user's audio).
        let sandboxRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lakeloom-recover-\(UUID().uuidString)", isDirectory: true)
        let captureDir = sandboxRoot
            .appendingPathComponent("Captures", isDirectory: true)
            .appendingPathComponent(Self.captureID, isDirectory: true)
        try FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)

        // Write two stand-in audio files large enough to clear the
        // 256-byte stub-purge floor. Simulates a chunked recording
        // that force-quit between chunk 1's finalize and chunk 2's
        // rotation.
        let payload = Data(repeating: 0xAB, count: 512)
        let chunk0 = captureDir.appendingPathComponent("audio-20260529T120000Z-chunk0.m4a")
        let chunk1 = captureDir.appendingPathComponent("audio-20260529T120000Z-chunk1.caf")
        try payload.write(to: chunk0)
        try payload.write(to: chunk1)

        let api = FakeCaptureAPIClient()
        let recorder = FakeAudioRecorder()
        let uploads = FakeUploadCoordinator()
        let store = CaptureContextStore(
            fileURL: sandboxRoot.appendingPathComponent("active-capture.json")
        )
        // Stateful ID provider; tests need unique IDs across the
        // two enqueues so the upload coordinator doesn't dedupe.
        // Wrap the counter in a class so the `@Sendable` closure
        // can mutate via reference instead of capturing a `var`.
        final class IDCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func next() -> Int {
                lock.lock(); defer { lock.unlock() }
                value += 1
                return value
            }
        }
        let counter = IDCounter()
        let service = LiveCaptureService(
            captureAPI: api,
            recorder: recorder,
            uploadCoordinator: uploads,
            contextStore: store,
            nowProvider: { Self.fixedNow },
            uploadIDProvider: { "u-recover-\(counter.next())" },
            fileHasher: { _ in "deadbeefcafe" },
            capturesDirectoryProvider: { _ in captureDir }
        )

        try await store.save(PersistedCaptureContext(
            captureSessionID: Self.captureID,
            projectID: Self.projectID,
            workspaceID: Self.workspaceID,
            startedAt: Self.fixedNow,
            phase: .recording,
            pendingUploadIDs: []
        ))

        await service.start()

        // Server should NOT have been patched cancelled.
        let updates = await api.updateCalls
        #expect(!updates.contains(where: { $0.state == .cancelled }))

        // Both audio files enqueued, in filename-sorted order so
        // the upload coordinator drains in recording order.
        let calls = await uploads.calls
        let enqueued: [String] = calls.compactMap { call in
            if case let .enqueue(_, captureSessionID) = call,
               captureSessionID == Self.captureID {
                return captureSessionID
            }
            return nil
        }
        #expect(enqueued.count == 2)

        let stored = await uploads.currentUploads()
        let m4a = stored.first { $0.localFileURL == chunk0 }
        let caf = stored.first { $0.localFileURL == chunk1 }
        #expect(m4a?.mimeType == "audio/mp4")
        #expect(caf?.mimeType == "audio/x-caf")
        #expect(m4a?.sizeBytes == 512)
        #expect(caf?.sizeBytes == 512)
        #expect(m4a?.captureSessionID == Self.captureID)

        // Snapshot transitioned to `.finalizing` with the recovered
        // upload IDs — watcher will drive it to `.completed` once
        // the uploads drain.
        let snapshot = await store.load()
        #expect(snapshot?.phase == .finalizing)
        #expect(snapshot?.pendingUploadIDs.count == 2)

        try? FileManager.default.removeItem(at: sandboxRoot)
    }

    @Test("start() with .recording snapshot drops sub-256-byte stub files instead of enqueuing them")
    func recoverRecordingPurgesStubs() async throws {
        // Force-quit before any audio frames landed leaves a tiny
        // CAF header stub. Recovery should not enqueue that — it'd
        // just become a failed upload row the user has to discard.
        let sandboxRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lakeloom-recover-\(UUID().uuidString)", isDirectory: true)
        let captureDir = sandboxRoot
            .appendingPathComponent("Captures", isDirectory: true)
            .appendingPathComponent(Self.captureID, isDirectory: true)
        try FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)

        let stub = captureDir.appendingPathComponent("audio-stub.caf")
        try Data(repeating: 0x00, count: 64).write(to: stub) // < 256-byte floor

        let api = FakeCaptureAPIClient()
        let uploads = FakeUploadCoordinator()
        let store = CaptureContextStore(
            fileURL: sandboxRoot.appendingPathComponent("active-capture.json")
        )
        let service = LiveCaptureService(
            captureAPI: api,
            recorder: FakeAudioRecorder(),
            uploadCoordinator: uploads,
            contextStore: store,
            nowProvider: { Self.fixedNow },
            uploadIDProvider: { "u-stub" },
            fileHasher: { _ in "deadbeef" },
            capturesDirectoryProvider: { _ in captureDir }
        )
        try await store.save(PersistedCaptureContext(
            captureSessionID: Self.captureID,
            projectID: Self.projectID,
            workspaceID: Self.workspaceID,
            startedAt: Self.fixedNow,
            phase: .recording,
            pendingUploadIDs: []
        ))

        await service.start()

        let stored = await uploads.currentUploads()
        #expect(stored.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: stub.path))
        // With no salvageable audio, fall back to cancelling the
        // server-side session so the row doesn't linger `.active`.
        let updates = await api.updateCalls
        #expect(updates.contains(where: { $0.state == .cancelled }))

        try? FileManager.default.removeItem(at: sandboxRoot)
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
