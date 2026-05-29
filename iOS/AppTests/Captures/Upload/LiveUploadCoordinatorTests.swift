import Foundation
import Testing

@testable import LakeloomApp

@Suite("LiveUploadCoordinator — happy path, retry, persistence")
struct LiveUploadCoordinatorTests {

    private static let workspaceID = "ws-1"
    private static let captureID = "cap-1"

    // MARK: Sandbox helpers

    /// Per-test temp root with a dummy file and a queue store.
    private struct Sandbox {
        let root: URL
        let fileURL: URL
        let queueStore: UploadQueueStore
        let queueURL: URL
    }

    private static func makeSandbox(fileBytes: Data = Data([0x01, 0x02, 0x03])) -> Sandbox {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lakeloom-upload-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("audio.m4a", isDirectory: false)
        try? fileBytes.write(to: fileURL)
        let queueURL = root.appendingPathComponent("upload-queue.json", isDirectory: false)
        let store = UploadQueueStore(fileURL: queueURL)
        return Sandbox(root: root, fileURL: fileURL, queueStore: store, queueURL: queueURL)
    }

    private static func makePending(fileURL: URL, id: String = "u-\(UUID().uuidString)") -> PendingUpload {
        PendingUpload(
            id: id,
            workspaceID: workspaceID,
            captureSessionID: captureID,
            kind: .audio,
            localFileURL: fileURL,
            mimeType: "audio/mp4",
            sizeBytes: 3,
            sha256Hex: "deadbeef",
            clientTimestamp: Date(timeIntervalSince1970: 1_747_152_120),
            originalFilename: fileURL.lastPathComponent,
            createdAt: Date(timeIntervalSince1970: 1_747_152_120)
        )
    }

    /// Fake clock that monotonically advances on each tick.
    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(start: Date = Date(timeIntervalSince1970: 1_747_152_120)) {
            self.date = start
        }
        func tick() -> Date {
            lock.lock(); defer { lock.unlock() }
            let now = date
            date = date.addingTimeInterval(0.1)
            return now
        }
        func advance(by interval: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            date = date.addingTimeInterval(interval)
        }
    }

    /// Sleep stub that records requested intervals but returns
    /// immediately — tests don't actually wait, they just inspect
    /// that backoff was honored.
    actor SleepRecorder {
        private(set) var intervals: [TimeInterval] = []
        func record(_ interval: TimeInterval) { intervals.append(interval) }
    }

    // MARK: enqueue

    @Test("enqueue persists upload and broadcasts queued state")
    func enqueuePersistsAndBroadcasts() async throws {
        let sandbox = Self.makeSandbox()
        let app = FakeLakeloomAppClient()
        let clock = TestClock()
        let coordinator = LiveUploadCoordinator(
            lakeloomApp: app,
            queueStore: sandbox.queueStore,
            nowProvider: { clock.tick() },
            sleep: { _ in },
            multipartBoundaryProvider: { "fixed-boundary" }
        )

        let stream = await coordinator.stateUpdates()
        var iterator = stream.makeAsyncIterator()

        let pending = Self.makePending(fileURL: sandbox.fileURL)
        try await coordinator.enqueue(pending)

        let first = await iterator.next()
        #expect(first?.uploadID == pending.id)
        #expect(first?.state == .queued)

        let snapshot = await coordinator.currentUploads()
        #expect(snapshot.map(\.id) == [pending.id])

        // Persisted on disk.
        let persisted = await sandbox.queueStore.load()
        #expect(persisted.map(\.id) == [pending.id])
    }

    @Test("enqueue throws fileNotFound if file missing")
    func enqueueRejectsMissingFile() async {
        let sandbox = Self.makeSandbox()
        try? FileManager.default.removeItem(at: sandbox.fileURL)
        let app = FakeLakeloomAppClient()
        let coordinator = LiveUploadCoordinator(
            lakeloomApp: app,
            queueStore: sandbox.queueStore,
            sleep: { _ in }
        )
        let pending = Self.makePending(fileURL: sandbox.fileURL)
        await #expect(throws: UploadCoordinatorError.fileNotFound(path: sandbox.fileURL.path)) {
            try await coordinator.enqueue(pending)
        }
    }

    @Test("enqueue rejects duplicate IDs")
    func enqueueRejectsDuplicate() async throws {
        let sandbox = Self.makeSandbox()
        let app = FakeLakeloomAppClient()
        let coordinator = LiveUploadCoordinator(
            lakeloomApp: app,
            queueStore: sandbox.queueStore,
            sleep: { _ in }
        )
        let pending = Self.makePending(fileURL: sandbox.fileURL, id: "dup")
        try await coordinator.enqueue(pending)
        await #expect(throws: UploadCoordinatorError.alreadyQueued(uploadID: "dup")) {
            try await coordinator.enqueue(pending)
        }
    }

    // MARK: Happy path through the worker

    @Test("start drives queued upload to succeeded; file removed from disk")
    func happyPath() async throws {
        let sandbox = Self.makeSandbox()
        let app = FakeLakeloomAppClient()
        await app.enqueueResponse(.success(Data("""
        {"id":"remote-1"}
        """.utf8)))
        let coordinator = LiveUploadCoordinator(
            lakeloomApp: app,
            queueStore: sandbox.queueStore,
            sleep: { _ in },
            multipartBoundaryProvider: { "fixed-boundary" }
        )

        let stream = await coordinator.stateUpdates()
        var iterator = stream.makeAsyncIterator()

        let pending = Self.makePending(fileURL: sandbox.fileURL)
        try await coordinator.enqueue(pending)
        await coordinator.start()

        // queued → uploading → succeeded
        var seenStates: [PendingUpload.State] = []
        for _ in 0..<3 {
            if let change = await iterator.next() {
                seenStates.append(change.state)
                if change.state == .succeeded { break }
            }
        }
        #expect(seenStates.last == .succeeded)
        #expect(seenStates.contains(.uploading))
        // Local file gone.
        #expect(!FileManager.default.fileExists(atPath: sandbox.fileURL.path))

        // Request hit the right path + content type.
        let calls = await app.requestCalls
        #expect(calls.count == 1)
        #expect(calls.first?.method == .post)
        #expect(calls.first?.path == "/api/captures/\(Self.captureID)/audio")
        #expect(calls.first?.contentType == "multipart/form-data; boundary=fixed-boundary")
        #expect(calls.first?.body != nil)

        await coordinator.stop()
    }

    // MARK: Retry policy

    @Test("5xx → transient retry with exponential backoff")
    func transientRetry() async throws {
        let sandbox = Self.makeSandbox()
        let app = FakeLakeloomAppClient()
        // First attempt fails with 503, second succeeds.
        await app.enqueueResponse(.failure(.httpError(status: 503, detail: "unavailable")))
        await app.enqueueResponse(.success(Data("{\"id\":\"remote-2\"}".utf8)))

        let sleeper = SleepRecorder()
        let coordinator = LiveUploadCoordinator(
            lakeloomApp: app,
            queueStore: sandbox.queueStore,
            sleep: { await sleeper.record($0) },
            multipartBoundaryProvider: { "fixed-boundary" }
        )

        let stream = await coordinator.stateUpdates()
        var iterator = stream.makeAsyncIterator()

        let pending = Self.makePending(fileURL: sandbox.fileURL)
        try await coordinator.enqueue(pending)
        await coordinator.start()

        // queued → uploading → queued (retry scheduled) → uploading → succeeded
        var states: [PendingUpload.State] = []
        for _ in 0..<6 {
            if let change = await iterator.next() {
                states.append(change.state)
                if change.state == .succeeded { break }
            }
        }
        #expect(states.last == .succeeded)
        // Worker slept on the backoff before retrying.
        let recordedIntervals = await sleeper.intervals
        #expect(recordedIntervals.contains(where: { $0 > 0 }))
        // Two attempts hit the transport.
        let calls = await app.requestCalls
        #expect(calls.count == 2)

        await coordinator.stop()
    }

    @Test("400 → permanent failure, no retry")
    func permanentFailure() async throws {
        let sandbox = Self.makeSandbox()
        let app = FakeLakeloomAppClient()
        await app.enqueueResponse(.failure(.httpError(status: 400, detail: "validation: bad mime")))

        let coordinator = LiveUploadCoordinator(
            lakeloomApp: app,
            queueStore: sandbox.queueStore,
            sleep: { _ in },
            multipartBoundaryProvider: { "fixed-boundary" }
        )

        let stream = await coordinator.stateUpdates()
        var iterator = stream.makeAsyncIterator()

        let pending = Self.makePending(fileURL: sandbox.fileURL)
        try await coordinator.enqueue(pending)
        await coordinator.start()

        var finalState: PendingUpload.State?
        for _ in 0..<5 {
            if let change = await iterator.next() {
                if case .failed = change.state {
                    finalState = change.state
                    break
                }
            }
        }
        guard case .failed(_, let permanent) = finalState else {
            Issue.record("Expected final failed state, got \(String(describing: finalState))")
            return
        }
        #expect(permanent == true)
        let calls = await app.requestCalls
        #expect(calls.count == 1) // no retry

        await coordinator.stop()
    }

    @Test("retry resets a failed upload back to queued and re-attempts")
    func manualRetry() async throws {
        let sandbox = Self.makeSandbox()
        let app = FakeLakeloomAppClient()
        await app.enqueueResponse(.failure(.httpError(status: 400, detail: "validation")))
        await app.enqueueResponse(.success(Data("{\"id\":\"remote-3\"}".utf8)))

        let coordinator = LiveUploadCoordinator(
            lakeloomApp: app,
            queueStore: sandbox.queueStore,
            sleep: { _ in },
            multipartBoundaryProvider: { "fixed-boundary" }
        )

        let stream = await coordinator.stateUpdates()
        var iterator = stream.makeAsyncIterator()

        let pending = Self.makePending(fileURL: sandbox.fileURL)
        try await coordinator.enqueue(pending)
        await coordinator.start()

        // Wait until first attempt fails permanently.
        for _ in 0..<5 {
            if let change = await iterator.next(), case .failed = change.state {
                break
            }
        }

        await coordinator.retry(uploadID: pending.id)

        var states: [PendingUpload.State] = []
        for _ in 0..<5 {
            if let change = await iterator.next() {
                states.append(change.state)
                if change.state == .succeeded { break }
            }
        }
        #expect(states.last == .succeeded)
        let calls = await app.requestCalls
        #expect(calls.count == 2)

        await coordinator.stop()
    }

    // MARK: Persistence

    @Test("rehydrate from disk on start; .uploading is revived as .queued")
    func rehydratesUploading() async throws {
        let sandbox = Self.makeSandbox()
        let app = FakeLakeloomAppClient()
        await app.enqueueResponse(.success(Data("{\"id\":\"remote-4\"}".utf8)))

        // Seed the queue store with one upload stuck in .uploading
        // (simulates app killed mid-upload).
        let pending = Self.makePending(fileURL: sandbox.fileURL)
        var stuck = pending
        stuck.state = .uploading
        try await sandbox.queueStore.save([stuck])

        let coordinator = LiveUploadCoordinator(
            lakeloomApp: app,
            queueStore: sandbox.queueStore,
            sleep: { _ in },
            multipartBoundaryProvider: { "fixed-boundary" }
        )

        let stream = await coordinator.stateUpdates()
        var iterator = stream.makeAsyncIterator()

        await coordinator.start()

        // Coordinator should pick up the revived .queued upload,
        // upload it, and reach .succeeded.
        var lastState: PendingUpload.State?
        for _ in 0..<5 {
            if let change = await iterator.next() {
                lastState = change.state
                if change.state == .succeeded { break }
            }
        }
        #expect(lastState == .succeeded)

        await coordinator.stop()
    }

    @Test("networkUnavailable never parks terminal even past maxAttempts")
    func networkErrorsDontExhaustRetryBudget() async throws {
        // Reproduces the Phase 3 scenario-3 bug: an offline session
        // longer than `sum(backoff)` seconds used to park the upload
        // terminal-failed permanent before reachability returned,
        // because each network failure counted against maxAttempts.
        // After the fix, network errors don't exhaust the budget —
        // the upload waits on a fixed networkRetryDelay until it
        // finally lands (or until a real server-side failure does
        // count against the limit).
        let sandbox = Self.makeSandbox()
        let app = FakeLakeloomAppClient()
        // Queue more failures than maxAttempts: 10 offline-style
        // failures followed by one success. Pre-fix this would have
        // parked permanent at attempt 5; post-fix the 11th attempt
        // succeeds because the retry budget was never spent.
        for _ in 0..<10 {
            await app.enqueueResponse(.failure(.networkUnavailable))
        }
        await app.enqueueResponse(.success(Data("{\"id\":\"remote-net\"}".utf8)))

        let coordinator = LiveUploadCoordinator(
            lakeloomApp: app,
            queueStore: sandbox.queueStore,
            sleep: { _ in /* skip backoff in tests */ },
            multipartBoundaryProvider: { "fixed-boundary" }
        )

        let stream = await coordinator.stateUpdates()
        var iterator = stream.makeAsyncIterator()

        let pending = Self.makePending(fileURL: sandbox.fileURL)
        try await coordinator.enqueue(pending)
        await coordinator.start()

        // Drain state events until either succeeded or permanent
        // failure — fail the test if we hit permanent.
        var sawSucceeded = false
        for _ in 0..<60 {
            guard let change = await iterator.next() else { break }
            if change.state == .succeeded {
                sawSucceeded = true
                break
            }
            if case .failed(_, let permanent) = change.state, permanent {
                Issue.record("Upload parked terminal-permanent despite network-only failures")
                break
            }
        }
        #expect(sawSucceeded)
        let calls = await app.requestCalls
        #expect(calls.count == 11)

        await coordinator.stop()
    }

    @Test("transport(file unreadable) parks terminal after maxAttempts, no infinite loop")
    func transportFileUnreadableParksAfterMaxAttempts() async throws {
        // Regression: `LakeloomAppError.transport` is overloaded —
        // it's thrown by `sendOnce` for both genuinely-network-layer
        // failures AND for "file gone from disk between enqueue and
        // attempt" (a permanent failure). The network-error classifier
        // must NOT treat `.transport` as offline-only, or file-missing
        // uploads loop forever at fixed `networkRetryDelay`.
        let sandbox = Self.makeSandbox()
        // Delete the file AFTER constructing PendingUpload so the
        // enqueue path passes its file-exists guard, then sendOnce
        // hits the throw at line ~280.
        let pending = Self.makePending(fileURL: sandbox.fileURL)
        let app = FakeLakeloomAppClient()
        let coordinator = LiveUploadCoordinator(
            lakeloomApp: app,
            queueStore: sandbox.queueStore,
            sleep: { _ in /* skip backoff */ },
            multipartBoundaryProvider: { "fixed-boundary" }
        )

        try await coordinator.enqueue(pending)
        // Yank the file so sendOnce throws .transport("file unreadable: ...")
        // on every attempt.
        try FileManager.default.removeItem(at: sandbox.fileURL)

        let stream = await coordinator.stateUpdates()
        var iterator = stream.makeAsyncIterator()
        await coordinator.start()

        var sawPermanentFailure = false
        // Read up to 30 state events looking for the terminal park.
        // If we exceed without seeing it, the classifier regression
        // is back and we're looping at 5s forever.
        for _ in 0..<30 {
            guard let change = await iterator.next() else { break }
            if case .failed(_, let permanent) = change.state, permanent {
                sawPermanentFailure = true
                break
            }
        }
        #expect(sawPermanentFailure)
        // The transport never accepted the call because sendOnce
        // throws before reaching `requestRaw`. Verify no spurious
        // network attempts.
        let calls = await app.requestCalls
        #expect(calls.isEmpty)
        await coordinator.stop()
    }

    @Test("wake clears nextAttemptAt on queued uploads")
    func wakeClearsPendingBackoff() async throws {
        // After a network failure the upload sits in `.queued` with
        // `nextAttemptAt` set to (now + networkRetryDelay). Reachability
        // returning calls wake(), which should clear that timer so the
        // next worker iteration picks the upload up immediately rather
        // than honoring a stale offline-era backoff.
        let sandbox = Self.makeSandbox()
        let app = FakeLakeloomAppClient()
        await app.enqueueResponse(.failure(.networkUnavailable))
        await app.enqueueResponse(.success(Data("{\"id\":\"remote-wake\"}".utf8)))

        let coordinator = LiveUploadCoordinator(
            lakeloomApp: app,
            queueStore: sandbox.queueStore,
            sleep: { _ in },
            multipartBoundaryProvider: { "fixed-boundary" },
            networkRetryDelay: 600 // generous so the test never relies on it elapsing
        )

        let stream = await coordinator.stateUpdates()
        var iterator = stream.makeAsyncIterator()

        let pending = Self.makePending(fileURL: sandbox.fileURL)
        try await coordinator.enqueue(pending)
        await coordinator.start()

        // Wait for the network failure to land the upload back in .queued.
        var sawQueuedAfterFailure = false
        for _ in 0..<6 {
            guard let change = await iterator.next() else { break }
            if change.state == .queued {
                // First .queued is the initial enqueue; second is post-failure.
                if sawQueuedAfterFailure { break }
                sawQueuedAfterFailure = true
            }
        }

        // Verify nextAttemptAt was set to the far-future delay.
        let snapshotBefore = await coordinator.currentUploads()
        #expect(snapshotBefore.first?.nextAttemptAt != nil)

        // Wake — should clear nextAttemptAt and resume the worker.
        await coordinator.wake()

        let snapshotAfter = await coordinator.currentUploads()
        #expect(snapshotAfter.first?.nextAttemptAt == nil)

        // The worker re-attempts and succeeds.
        var sawSucceeded = false
        for _ in 0..<6 {
            guard let change = await iterator.next() else { break }
            if change.state == .succeeded {
                sawSucceeded = true
                break
            }
        }
        #expect(sawSucceeded)

        await coordinator.stop()
    }

    @Test("discard removes upload from queue and deletes local file")
    func discardRemovesEverything() async throws {
        let sandbox = Self.makeSandbox()
        let app = FakeLakeloomAppClient()
        let coordinator = LiveUploadCoordinator(
            lakeloomApp: app,
            queueStore: sandbox.queueStore,
            sleep: { _ in }
        )

        let pending = Self.makePending(fileURL: sandbox.fileURL)
        try await coordinator.enqueue(pending)
        await coordinator.discard(uploadID: pending.id)

        let snapshot = await coordinator.currentUploads()
        #expect(snapshot.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sandbox.fileURL.path))
    }

    @Test("discard broadcasts on stateUpdates so subscribers re-snapshot")
    func discardBroadcastsStateUpdate() async throws {
        // The home-page pending-upload pill subscribes to
        // `stateUpdates()` and re-snapshots `currentUploads().count`
        // on every yield. If `discard()` doesn't broadcast, the
        // pill renders a stale count after manual cleanup. This
        // test pins the contract: discard MUST emit on the stream.
        let sandbox = Self.makeSandbox()
        let app = FakeLakeloomAppClient()
        let coordinator = LiveUploadCoordinator(
            lakeloomApp: app,
            queueStore: sandbox.queueStore,
            sleep: { _ in }
        )

        let pending = Self.makePending(fileURL: sandbox.fileURL)
        try await coordinator.enqueue(pending)

        // Subscribe AFTER enqueue so the initial `.queued` yield is
        // already consumed by other subscribers — we only want the
        // discard-driven yield to land in our stream.
        let stream = await coordinator.stateUpdates()
        var iterator = stream.makeAsyncIterator()

        await coordinator.discard(uploadID: pending.id)

        let change = await iterator.next()
        #expect(change != nil)
        #expect(change?.uploadID == pending.id)
    }
}
