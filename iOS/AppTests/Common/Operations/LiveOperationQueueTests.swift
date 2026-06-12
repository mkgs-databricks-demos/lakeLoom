import Foundation
import Testing

@testable import LakeloomApp

@Suite("LiveOperationQueue")
struct LiveOperationQueueTests {

    // MARK: - Helpers

    /// Recording executor: appends each invocation to `calls` and
    /// returns whatever the per-call handler dictates. Lets tests
    /// inspect FIFO ordering + retry behavior without standing up a
    /// real network client.
    actor RecordingExecutor {
        var calls: [String] = []
        private var handlers: [String: @Sendable (PendingOperation) async throws -> Void] = [:]

        func handle(_ id: String, _ handler: @escaping @Sendable (PendingOperation) async throws -> Void) {
            handlers[id] = handler
        }

        func run(_ op: PendingOperation) async throws {
            calls.append(op.id)
            if let handler = handlers[op.id] {
                try await handler(op)
            }
            // Default: success.
        }
    }

    private static func makeStore() -> OperationQueueStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lakeloom-op-queue-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("operation-queue.json", isDirectory: false)
        return OperationQueueStore(fileURL: url)
    }

    private static func makeOp(id: String) -> PendingOperation {
        PendingOperation(
            id: id,
            workspaceID: "ws-1",
            variant: .updateCaptureLabel(captureSessionID: "cap-1", label: "x"),
            createdAt: Date(timeIntervalSince1970: 1_747_152_120)
        )
    }

    /// Drive the queue's `stateUpdates()` stream until `predicate`
    /// is met. Bounded so tests never hang on a missing event.
    private static func waitFor(
        queue: any OperationQueueing,
        until predicate: @escaping (OperationStateChange) -> Bool,
        timeout: TimeInterval = 2
    ) async {
        let stream = await queue.stateUpdates()
        let deadline = Date().addingTimeInterval(timeout)
        for await change in stream {
            if predicate(change) { return }
            if Date() > deadline { return }
        }
    }

    // MARK: - Tests

    @Test("happy path: enqueue → execute → succeeded retires from queue")
    func happyPath() async throws {
        let store = Self.makeStore()
        let recorder = RecordingExecutor()
        let queue = LiveOperationQueue(
            queueStore: store,
            execute: { op in try await recorder.run(op) },
            sleep: { _ in /* no-op for tests */ }
        )

        let op = Self.makeOp(id: "op-happy")
        try await queue.enqueue(op)
        await queue.start()

        await Self.waitFor(queue: queue) { change in
            change.operationID == "op-happy" && change.state == .succeeded
        }

        let calls = await recorder.calls
        #expect(calls == ["op-happy"])
        let snapshot = await queue.currentOperations()
        #expect(snapshot.isEmpty)
        await queue.stop()
    }

    @Test("transient failure → retry with attempts incrementing")
    func transientRetry() async throws {
        let store = Self.makeStore()
        let recorder = RecordingExecutor()
        // Fail twice, then succeed.
        await recorder.handle("op-retry") { op in
            if op.attempts < 3 {
                struct Transient: Error {}
                throw Transient()
            }
        }
        let queue = LiveOperationQueue(
            queueStore: store,
            execute: { op in try await recorder.run(op) },
            sleep: { _ in /* skip backoff for tests */ }
        )

        let op = Self.makeOp(id: "op-retry")
        try await queue.enqueue(op)
        await queue.start()

        await Self.waitFor(
            queue: queue,
            until: { change in
                change.operationID == "op-retry" && change.state == .succeeded
            },
            timeout: 5
        )

        let calls = await recorder.calls
        #expect(calls.count == 3)
        #expect(calls.allSatisfy { $0 == "op-retry" })
        await queue.stop()
    }

    @Test("permanent failure → parks in queue, no further attempts")
    func permanentFailure() async throws {
        let store = Self.makeStore()
        let recorder = RecordingExecutor()
        await recorder.handle("op-perm") { _ in
            throw OperationPermanentFailure(reason: "validation: bad payload")
        }
        let queue = LiveOperationQueue(
            queueStore: store,
            execute: { op in try await recorder.run(op) },
            sleep: { _ in }
        )

        let op = Self.makeOp(id: "op-perm")
        try await queue.enqueue(op)
        await queue.start()

        // Wait for the .failed permanent broadcast.
        await Self.waitFor(queue: queue) { change in
            if change.operationID == "op-perm",
               case .failed(_, let permanent) = change.state {
                return permanent
            }
            return false
        }

        let calls = await recorder.calls
        #expect(calls.count == 1) // No retries.
        let snapshot = await queue.currentOperations()
        #expect(snapshot.count == 1) // Still in queue for diagnostics.
        if case .failed(let reason, let permanent) = snapshot[0].state {
            #expect(permanent == true)
            #expect(reason.contains("validation"))
        } else {
            Issue.record("Expected failed-permanent state, got \(snapshot[0].state)")
        }
        await queue.stop()
    }

    @Test("discard removes op from queue")
    func discard() async throws {
        let store = Self.makeStore()
        let recorder = RecordingExecutor()
        // Block execution so the queue can't auto-drain before
        // discard lands.
        await recorder.handle("op-discard") { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        let queue = LiveOperationQueue(
            queueStore: store,
            execute: { op in try await recorder.run(op) },
            sleep: { _ in }
        )

        let op = Self.makeOp(id: "op-discard")
        try await queue.enqueue(op)

        // Discard before start() so the worker never picks it up.
        await queue.discard(operationID: "op-discard")

        let snapshot = await queue.currentOperations()
        #expect(snapshot.isEmpty)
        await queue.stop()
    }

    @Test("restore recovers .running op from disk by resetting to .queued")
    func recoversRunningOpFromDisk() async throws {
        // Simulate a previous launch that died mid-attempt: persist
        // an op in `.running` state, then bring up a fresh queue
        // against the same store. The worker must pick it up.
        let store = Self.makeStore()
        let wedged = PendingOperation(
            id: "op-wedged",
            workspaceID: "ws-1",
            variant: .updateCaptureLabel(captureSessionID: "cap-1", label: "x"),
            createdAt: Date(timeIntervalSince1970: 1_747_152_120),
            state: .running,
            attempts: 1
        )
        try await store.save([wedged])

        let recorder = RecordingExecutor()
        let queue = LiveOperationQueue(
            queueStore: store,
            execute: { op in try await recorder.run(op) },
            sleep: { _ in }
        )

        await queue.start()

        await Self.waitFor(queue: queue) { change in
            change.operationID == "op-wedged" && change.state == .succeeded
        }

        let calls = await recorder.calls
        #expect(calls == ["op-wedged"])
        let snapshot = await queue.currentOperations()
        #expect(snapshot.isEmpty)
        await queue.stop()
    }

    @Test("FIFO ordering preserved across enqueue + execute")
    func fifoOrdering() async throws {
        let store = Self.makeStore()
        let recorder = RecordingExecutor()
        let queue = LiveOperationQueue(
            queueStore: store,
            execute: { op in try await recorder.run(op) },
            sleep: { _ in }
        )

        try await queue.enqueue(Self.makeOp(id: "first"))
        try await queue.enqueue(Self.makeOp(id: "second"))
        try await queue.enqueue(Self.makeOp(id: "third"))
        await queue.start()

        await Self.waitFor(
            queue: queue,
            until: { change in
                change.operationID == "third" && change.state == .succeeded
            },
            timeout: 3
        )

        let calls = await recorder.calls
        #expect(calls == ["first", "second", "third"])
        await queue.stop()
    }
}
