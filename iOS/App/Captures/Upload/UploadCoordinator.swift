import Foundation

/// Owns the local-then-upload pipeline for capture artifacts. The
/// recording layer (`AudioRecorder`, future `ScreenCapture` / camera)
/// finalizes files on disk and hands them off here; the coordinator
/// queues them, ships them to the Databricks App's upload routes,
/// retries on transient failures, and reports state changes to the
/// UI via ``stateUpdates()``.
///
/// Persistence: the queue is mirrored to disk so a force-quit doesn't
/// lose a pending upload. On `start()` the coordinator rehydrates
/// from the snapshot and resumes any uploads that were mid-flight
/// before the app went away.
public protocol UploadCoordinator: Sendable {

    /// Enqueue a finalized capture artifact. The coordinator takes
    /// ownership of the file on disk: callers must not delete or
    /// move the file at `pending.localFileURL` after enqueue
    /// returns. Successful uploads remove the file; failed terminal
    /// uploads leave it for diagnostics.
    func enqueue(_ pending: PendingUpload) async throws

    /// Snapshot of every upload currently tracked, in enqueue order.
    /// Includes queued, in-flight, and recently completed (until the
    /// caller invokes ``discard(uploadID:)``).
    func currentUploads() async -> [PendingUpload]

    /// Subscribe to live state changes. Each yield is one upload's
    /// new state; the stream completes when the coordinator is
    /// deallocated or the subscriber drops it. Each call to
    /// ``stateUpdates()`` returns an independent stream.
    func stateUpdates() async -> AsyncStream<UploadStateChange>

    /// Force a retry on a permanent-failure or terminal-success
    /// upload (e.g., "Retry" from the UI). Resets attempts and
    /// re-queues. No-op for uploads not currently tracked.
    func retry(uploadID: String) async

    /// Drop an upload from the queue and delete its local file.
    /// Use for permanent failures the user wants to clear, or for
    /// a user-cancelled capture.
    func discard(uploadID: String) async

    /// Start the worker loop and rehydrate the on-disk queue.
    /// Idempotent — safe to call from `App.bootstrap`.
    func start() async

    /// Stop the worker loop. After `stop()`, calls to ``enqueue(_:)``
    /// still persist to disk but won't be uploaded until the next
    /// `start()`.
    func stop() async
}

/// Typed errors surfaced by ``UploadCoordinator/enqueue(_:)``.
public enum UploadCoordinatorError: Error, Sendable, Equatable {
    /// The file at `localFileURL` doesn't exist or isn't readable.
    /// Usually a programmer error (caller deleted before enqueueing).
    case fileNotFound(path: String)

    /// An upload with the same `id` is already tracked. Generate a
    /// fresh UUID per `enqueue` to avoid this.
    case alreadyQueued(uploadID: String)

    /// Hashing or persistence of the queue failed. The caller can
    /// surface "Couldn't queue upload — try again."
    case persistenceFailed(reason: String)
}
