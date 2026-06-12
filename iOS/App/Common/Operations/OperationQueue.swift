import Foundation

/// Control-plane operation queue. The "outbox" for non-multipart
/// server calls that iOS wants to fire-and-forget so user-facing
/// actions don't block on a network round trip.
///
/// **Phase 2 scaffold (PR #18)** — the queue, store, value types,
/// and drainer all ship inert. No production code enqueues anything
/// yet. The scaffold lets us land + test the persistence + retry
/// machinery independently of the behavioral cutover (Phase 3 PR),
/// which will:
///   * Modify ``LiveCaptureService/startCapture`` to generate a
///     UUIDv7 locally + enqueue a `.createCaptureSession` op + start
///     the recorder immediately
///   * Lift the "disable Record when offline" gate from Phase 1
///   * Be gated on Genie's server-side support for
///     `client_generated_id` (see
///     `architecture/hi_genie/2026-05-25_phase2-client-generated-capture-id.md`)
///
/// Tests cover the queue + store in isolation.
public protocol OperationQueueing: Sendable {

    /// Add an op to the back of the queue and persist.
    /// Idempotent on `(workspaceID, variant)` — re-enqueueing an
    /// existing op is a no-op (returns silently).
    func enqueue(_ operation: PendingOperation) async throws

    /// Snapshot every op currently tracked, in FIFO order.
    /// Useful for diagnostics + future "outbox" UI.
    func currentOperations() async -> [PendingOperation]

    /// Subscribe to live state changes. Each yield is one op's
    /// new state; the stream completes when the queue is
    /// deallocated or the subscriber drops it.
    func stateUpdates() async -> AsyncStream<OperationStateChange>

    /// Drop an op without firing it. Used for sign-out cleanup or
    /// the user explicitly discarding via diagnostic UI.
    func discard(operationID: String) async

    /// Force-retry a failed-permanent op (e.g. "Retry" from the
    /// outbox diagnostic UI). Resets attempts and re-queues.
    /// No-op for ops not currently tracked.
    func retry(operationID: String) async

    /// Start the worker loop and rehydrate the on-disk snapshot.
    /// Idempotent. Production wiring should call this from app
    /// bootstrap; the worker stays blocked on a continuation when
    /// the queue is empty so the runtime cost at rest is zero.
    func start() async

    /// Stop the worker loop. Pending enqueues still persist; the
    /// next `start()` resumes draining.
    func stop() async

    /// Nudge the worker to re-check the queue immediately. Used by
    /// the reachability monitor on `offline → online` transitions:
    /// any ops that were sitting in transient-failure backoff get
    /// re-attempted right away instead of waiting out their delay.
    func wake() async
}

public enum OperationQueueingError: Error, Sendable, Equatable {
    /// Hashing or persistence of the queue failed. Caller can
    /// surface "Couldn't queue this action — try again."
    case persistenceFailed(reason: String)
}

public struct OperationStateChange: Sendable, Equatable {
    public let operationID: String
    public let state: PendingOperation.State

    public init(operationID: String, state: PendingOperation.State) {
        self.operationID = operationID
        self.state = state
    }
}

// MARK: - Live impl

/// Production ``OperationQueueing``. Mirrors the structure of
/// ``LiveUploadCoordinator`` so the two queues age in lockstep —
/// when we revisit retry tuning, backoff curves, or persistence
/// shape, both pick up the same improvements.
///
/// Inject ``execute`` at init: the closure performs the actual HTTP
/// call for a given variant. Production wiring routes it through
/// the existing `CaptureAPIClient` + `ProjectAPIClient`. Tests
/// inject a recording closure for assertions.
public actor LiveOperationQueue: OperationQueueing {

    /// Closure that performs the server call for a given operation.
    /// Throwing classifies as a transient failure unless the thrown
    /// error is ``OperationPermanentFailure``, in which case the
    /// queue marks the op as `.failed(permanent: true)` and stops
    /// retrying.
    public typealias Executor = @Sendable (PendingOperation) async throws -> Void

    private let queueStore: OperationQueueStore
    private let logger: AppLogger
    private let execute: Executor
    private let sleep: @Sendable (UInt64) async throws -> Void

    /// FIFO key order. Stored separately so we don't lose ordering
    /// across the dict's natural iteration. Mirrors
    /// ``LiveUploadCoordinator/order``.
    private var order: [String] = []
    private var operations: [String: PendingOperation] = [:]
    private var continuations: [UUID: AsyncStream<OperationStateChange>.Continuation] = [:]

    private var didLoadFromDisk = false
    private var workerTask: Task<Void, Never>?
    private var wakeContinuation: CheckedContinuation<Void, Never>?

    /// Retry policy — same shape as ``LiveUploadCoordinator``.
    private static let baseBackoff: TimeInterval = 2
    private static let maxBackoff: TimeInterval = 60
    private static let maxTransientAttempts = 6

    public init(
        queueStore: OperationQueueStore,
        execute: @escaping Executor,
        logger: AppLogger = AppLogger(category: .ingest),
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { ns in
            try await Task.sleep(nanoseconds: ns)
        }
    ) {
        self.queueStore = queueStore
        self.execute = execute
        self.logger = logger
        self.sleep = sleep
    }

    // MARK: Public surface

    public func enqueue(_ operation: PendingOperation) async throws {
        if operations[operation.id] != nil {
            // Idempotent re-enqueue — no-op.
            return
        }
        operations[operation.id] = operation
        order.append(operation.id)
        do {
            try await persist()
        } catch {
            operations.removeValue(forKey: operation.id)
            order.removeAll { $0 == operation.id }
            throw OperationQueueingError.persistenceFailed(reason: error.localizedDescription)
        }
        await logger.info(
            "operation.queue.enqueued",
            metadata: [
                "operation_id": .uuidPrefix(operation.id),
                "category": .string(operation.variant.category)
            ]
        )
        broadcast(operationID: operation.id, state: operation.state)
        wakeWorker()
    }

    public func currentOperations() async -> [PendingOperation] {
        order.compactMap { operations[$0] }
    }

    public func stateUpdates() async -> AsyncStream<OperationStateChange> {
        let (stream, continuation) = AsyncStream<OperationStateChange>.makeStream()
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.unsubscribe(id: id) }
        }
        return stream
    }

    public func discard(operationID: String) async {
        guard operations.removeValue(forKey: operationID) != nil else { return }
        order.removeAll { $0 == operationID }
        try? await persist()
        await logger.info(
            "operation.queue.discarded",
            metadata: ["operation_id": .uuidPrefix(operationID)]
        )
    }

    public func retry(operationID: String) async {
        guard var operation = operations[operationID] else { return }
        operation.state = .queued
        operation.attempts = 0
        operation.nextAttemptAt = nil
        operation.lastError = nil
        operations[operationID] = operation
        try? await persist()
        broadcast(operationID: operationID, state: .queued)
        wakeWorker()
    }

    public func start() async {
        if !didLoadFromDisk {
            let restored = await queueStore.load()
            var resetCount = 0
            for op in restored {
                // Skip ops that were enqueued in-memory before start()
                // — those are already in `operations`/`order` and the
                // disk copy is just the persisted shadow of them.
                if operations[op.id] != nil { continue }
                var recovered = op
                // `runOne` persists `.running` BEFORE awaiting the
                // network call. If the previous launch died mid-
                // attempt (force-quit, jetsam, crash), the op is on
                // disk in `.running` — and `nextWorkableID()` skips
                // running ops, so the worker would wedge the queue
                // forever. Reset to `.queued` on restore so we re-
                // attempt cleanly. Note `attempts` is preserved so
                // the transient-retry budget keeps counting up.
                if case .running = recovered.state {
                    recovered.state = .queued
                    recovered.nextAttemptAt = nil
                    resetCount += 1
                }
                operations[recovered.id] = recovered
                order.append(recovered.id)
            }
            didLoadFromDisk = true
            if resetCount > 0 {
                // Persist the reset so a subsequent crash mid-recovery
                // doesn't re-wedge us against the same disk state.
                try? await persist()
                await logger.info(
                    "operation.queue.recovered_running",
                    metadata: ["count": .int(Int64(resetCount))]
                )
            }
            await logger.info(
                "operation.queue.restored",
                metadata: ["count": .int(Int64(restored.count))]
            )
        }
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.workerLoop()
        }
    }

    public func stop() async {
        workerTask?.cancel()
        workerTask = nil
        // Resume any waiting wake() so the loop exits cleanly.
        wakeContinuation?.resume()
        wakeContinuation = nil
    }

    public func wake() async {
        wakeWorker()
    }

    // MARK: Worker loop

    private func workerLoop() async {
        while !Task.isCancelled {
            guard let id = nextWorkableID() else {
                // Nothing to do — block until enqueue / retry /
                // wake nudges us. The continuation pattern matches
                // LiveUploadCoordinator.
                await waitForWake()
                continue
            }
            await runOne(id: id)
        }
    }

    /// Pick the oldest non-terminal op whose `nextAttemptAt`
    /// (if any) is in the past. Returns nil when the queue is
    /// empty or every workable entry is still in backoff —
    /// `waitForWake` handles the backoff window via a sleep
    /// timer in the failure-handler path.
    private func nextWorkableID() -> String? {
        let now = Date()
        for id in order {
            guard let op = operations[id] else { continue }
            switch op.state {
            case .succeeded:
                continue
            case .failed(_, let permanent):
                if permanent { continue }
                if let nextAt = op.nextAttemptAt, nextAt > now { continue }
                return id
            case .running:
                continue
            case .queued:
                if let nextAt = op.nextAttemptAt, nextAt > now { continue }
                return id
            }
        }
        return nil
    }

    private func runOne(id: String) async {
        guard var op = operations[id] else { return }
        op.state = .running
        op.attempts += 1
        operations[id] = op
        broadcast(operationID: id, state: .running)
        try? await persist()
        await logger.info(
            "operation.attempt.start",
            metadata: [
                "operation_id": .uuidPrefix(id),
                "category": .string(op.variant.category),
                "attempt": .int(Int64(op.attempts))
            ]
        )

        do {
            try await execute(op)
        } catch let error as OperationPermanentFailure {
            await markFailedPermanent(id: id, reason: error.reason)
            return
        } catch {
            await markFailedTransient(id: id, reason: error.localizedDescription)
            return
        }

        await markSucceeded(id: id)
    }

    private func markSucceeded(id: String) async {
        // Full retire on success — same pattern as LiveUploadCoordinator
        // after the PR #60 fix. The .succeeded broadcast goes out
        // BEFORE we remove the entry so subscribers see the terminal
        // signal; the actor's serial executor guarantees no
        // currentOperations() call can land between broadcast + remove.
        operations.removeValue(forKey: id)
        order.removeAll { $0 == id }
        try? await persist()
        broadcast(operationID: id, state: .succeeded)
        await logger.info(
            "operation.attempt.ok",
            metadata: ["operation_id": .uuidPrefix(id)]
        )
    }

    private func markFailedTransient(id: String, reason: String) async {
        guard var op = operations[id] else { return }
        if op.attempts >= Self.maxTransientAttempts {
            await markFailedPermanent(id: id, reason: "max-attempts: \(reason)")
            return
        }
        let backoff = min(
            Self.baseBackoff * pow(2.0, Double(op.attempts - 1)),
            Self.maxBackoff
        )
        op.state = .failed(reason: reason, permanent: false)
        op.lastError = reason
        op.nextAttemptAt = Date().addingTimeInterval(backoff)
        operations[id] = op
        try? await persist()
        broadcast(operationID: id, state: op.state)
        await logger.warning(
            "operation.attempt.failed_transient",
            metadata: [
                "operation_id": .uuidPrefix(id),
                "attempt": .int(Int64(op.attempts)),
                "retry_in_s": .string(String(format: "%.1f", backoff)),
                "reason": .string(reason)
            ]
        )
        // Sleep this worker out for the backoff window. wake() can
        // pre-empt the sleep on a reachability change.
        try? await sleep(UInt64(backoff * 1_000_000_000))
        // Clear nextAttemptAt now that the backoff window has elapsed
        // — the next worker iteration should treat the op as workable.
        // The persisted `nextAttemptAt` above survives a crash mid-sleep,
        // so restart-time backoff honoring still works.
        if var refreshed = operations[id] {
            refreshed.nextAttemptAt = nil
            operations[id] = refreshed
        }
    }

    private func markFailedPermanent(id: String, reason: String) async {
        guard var op = operations[id] else { return }
        op.state = .failed(reason: reason, permanent: true)
        op.lastError = reason
        op.nextAttemptAt = nil
        operations[id] = op
        try? await persist()
        broadcast(operationID: id, state: op.state)
        await logger.error(
            "operation.attempt.failed_permanent",
            metadata: [
                "operation_id": .uuidPrefix(id),
                "reason": .string(reason)
            ],
            errorCode: "permanent"
        )
    }

    // MARK: Wake / persist / broadcast

    private func waitForWake() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wakeContinuation = continuation
        }
    }

    private func wakeWorker() {
        guard let continuation = wakeContinuation else { return }
        wakeContinuation = nil
        continuation.resume()
    }

    private func persist() async throws {
        let snapshot = order.compactMap { operations[$0] }
        try await queueStore.save(snapshot)
    }

    private func broadcast(operationID: String, state: PendingOperation.State) {
        let change = OperationStateChange(operationID: operationID, state: state)
        for continuation in continuations.values {
            continuation.yield(change)
        }
    }

    private func unsubscribe(id: UUID) {
        continuations[id] = nil
    }
}

/// Throw this from an ``LiveOperationQueue/Executor`` to tell the
/// queue not to retry. Use for 4xx validation / forbidden /
/// not-found responses where the same payload will keep failing.
/// 5xx + network errors are transient by default.
public struct OperationPermanentFailure: Error, Sendable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}
