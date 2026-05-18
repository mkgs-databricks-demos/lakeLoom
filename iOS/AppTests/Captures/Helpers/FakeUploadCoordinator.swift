import Foundation

@testable import LakeloomApp

/// Scriptable ``UploadCoordinator`` for ``CaptureService`` tests.
/// Records enqueue/discard/retry/start/stop calls. The
/// ``stateUpdates()`` stream is backed by a single
/// `AsyncStream.Continuation` that tests prod via
/// ``emit(_:state:)`` to simulate the worker reporting progress.
public actor FakeUploadCoordinator: UploadCoordinator {

    public enum Call: Sendable, Equatable {
        case enqueue(uploadID: String, captureSessionID: String)
        case discard(uploadID: String)
        case retry(uploadID: String)
        case start
        case stop
    }

    public private(set) var calls: [Call] = []

    private var enqueueErrors: [Error?] = []
    private var stored: [PendingUpload] = []
    private var continuations: [UUID: AsyncStream<UploadStateChange>.Continuation] = [:]

    public init() {}

    public func setNextEnqueueError(_ error: Error?) {
        enqueueErrors.append(error)
    }

    /// Test-only: seed the in-memory upload list with arbitrary state.
    /// Used by the persistence-recovery tests to simulate uploads
    /// that the upload coordinator's queue store would have rehydrated
    /// in their post-app-kill state (e.g., `.succeeded` already, or
    /// still `.queued`).
    public func setStoredUploads(_ uploads: [PendingUpload]) {
        stored = uploads
    }

    /// Push a state change onto every subscribed stateUpdates stream.
    /// Tests call this to drive `CaptureService`'s upload watcher.
    public func emit(_ uploadID: String, state: PendingUpload.State) {
        let change = UploadStateChange(uploadID: uploadID, state: state)
        for continuation in continuations.values {
            continuation.yield(change)
        }
    }

    public func enqueue(_ pending: PendingUpload) async throws {
        calls.append(.enqueue(uploadID: pending.id, captureSessionID: pending.captureSessionID))
        if !enqueueErrors.isEmpty, let error = enqueueErrors.removeFirst() {
            throw error
        }
        stored.append(pending)
    }

    public func currentUploads() async -> [PendingUpload] {
        stored
    }

    public func stateUpdates() async -> AsyncStream<UploadStateChange> {
        let (stream, continuation) = AsyncStream<UploadStateChange>.makeStream()
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.unsubscribe(id: id) }
        }
        return stream
    }

    public func retry(uploadID: String) async {
        calls.append(.retry(uploadID: uploadID))
    }

    public func discard(uploadID: String) async {
        calls.append(.discard(uploadID: uploadID))
        stored.removeAll { $0.id == uploadID }
    }

    public func start() async {
        calls.append(.start)
    }

    public func stop() async {
        calls.append(.stop)
    }

    private func unsubscribe(id: UUID) {
        continuations[id] = nil
    }
}
