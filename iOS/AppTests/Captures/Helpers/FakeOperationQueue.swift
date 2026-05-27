import Foundation

@testable import LakeloomApp

/// Scriptable ``OperationQueueing`` for the Phase 3 cutover tests.
/// Records every `enqueue` call so the assertions can verify the
/// variant + workspace + payload that LiveCaptureService emits, and
/// otherwise no-ops (no worker loop, no real persistence).
public actor FakeOperationQueue: OperationQueueing {

    public private(set) var enqueued: [PendingOperation] = []
    public private(set) var discardedIDs: [String] = []
    public private(set) var retriedIDs: [String] = []
    public private(set) var startCount = 0
    public private(set) var stopCount = 0
    public private(set) var wakeCount = 0

    public init() {}

    public func enqueue(_ operation: PendingOperation) async throws {
        enqueued.append(operation)
    }

    public func currentOperations() async -> [PendingOperation] {
        enqueued
    }

    public func stateUpdates() async -> AsyncStream<OperationStateChange> {
        AsyncStream<OperationStateChange> { _ in }
    }

    public func discard(operationID: String) async {
        discardedIDs.append(operationID)
    }

    public func retry(operationID: String) async {
        retriedIDs.append(operationID)
    }

    public func start() async {
        startCount += 1
    }

    public func stop() async {
        stopCount += 1
    }

    public func wake() async {
        wakeCount += 1
    }
}
