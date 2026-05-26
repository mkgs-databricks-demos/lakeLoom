import Foundation

/// A control-plane server operation iOS has chosen to perform —
/// queued for later replay so the user-facing action can proceed
/// without waiting on a network round trip.
///
/// Sibling of ``PendingUpload``: that one carries multipart file
/// payloads (audio / photo / screenshot / document); this one
/// carries idempotent control-plane calls (create capture session,
/// PATCH state, edit project name/description).
///
/// **Phase 2 scaffold** — this type and the ``OperationQueue`` that
/// drains it ship inert: no production caller enqueues anything
/// yet. Phase 3 will modify ``LiveCaptureService/startCapture`` to
/// generate a UUIDv7 locally + enqueue a
/// ``Variant/createCaptureSession`` op + start the recorder
/// immediately, behind a feature flag tied to Genie's server
/// support for `client_generated_id` (see
/// `architecture/hi_genie/2026-05-25_phase2-client-generated-capture-id.md`).
public struct PendingOperation: Sendable, Equatable, Hashable, Codable, Identifiable {

    public let id: String
    /// Workspace the op belongs to. Used to look up the right
    /// per-workspace credentials when the queue drains.
    public let workspaceID: String
    public let variant: Variant
    public let createdAt: Date

    /// Mutable lifecycle state — updates as the worker loop runs.
    public var state: State
    public var attempts: Int
    /// Earliest time the queue should retry after a transient
    /// failure. Used by the worker loop's wait policy. Mirrors
    /// ``PendingUpload/nextAttemptAt``.
    public var nextAttemptAt: Date?
    /// Last error string surfaced to UI / diagnostics. Cleared on
    /// the next successful attempt.
    public var lastError: String?

    public init(
        id: String = UUIDv7.generate(),
        workspaceID: String,
        variant: Variant,
        createdAt: Date = Date(),
        state: State = .queued,
        attempts: Int = 0,
        nextAttemptAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.variant = variant
        self.createdAt = createdAt
        self.state = state
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
    }

    // MARK: - Variant (the actual op payload)

    /// What the operation actually does on the server. Each case
    /// carries the inputs needed to make the request fully
    /// re-creatable from disk — the queue must be replayable cold,
    /// after a force-quit, without holding any in-memory state.
    ///
    /// **Idempotency invariant:** every variant must be safe to
    /// re-attempt. Where the server doesn't natively dedupe, the
    /// variant supplies a `clientGeneratedID` so the server can
    /// (e.g. capture session create, project create). Where the
    /// server is idempotent by path + state (`PATCH …/state` with
    /// the same payload), no extra client ID is needed.
    public enum Variant: Sendable, Equatable, Hashable, Codable {

        /// `POST /api/projects/:project_id/captures` with a
        /// client-supplied `id`. See the 2026-05-25 hi_genie note
        /// for the contract. The server-issued row's `id` equals
        /// ``captureSessionID`` once accepted; iOS uses
        /// ``captureSessionID`` for every subsequent op + upload
        /// against this capture, regardless of whether the create
        /// has ACK'd yet.
        case createCaptureSession(
            captureSessionID: String,
            projectID: String,
            label: String?,
            clientTimestamp: Date,
            deviceID: String?
        )

        /// `PATCH /api/captures/:capture_session_id` to terminal
        /// state (`.completed` or `.cancelled`). Idempotent — the
        /// server rejects redundant transitions (e.g. completed →
        /// completed) with 400, which the queue classifies as
        /// permanent.
        case updateCaptureSessionState(
            captureSessionID: String,
            endState: TerminalState,
            endedAt: Date?
        )

        /// `PATCH /api/v1/captures/:capture_session_id/label`.
        /// Idempotent — replays return the same row state.
        case updateCaptureLabel(
            captureSessionID: String,
            label: String
        )

        /// `POST /api/v1/projects` (server already supports the
        /// `client_generated_id` idempotency Genie shipped in
        /// 2026-05-22). Phase 2 lets the user create projects
        /// offline; the new project shows up locally immediately
        /// (added to the ``ProjectListStore``) and reconciles with
        /// the server when the queue drains.
        case createProject(
            projectID: String,
            name: String,
            description: String?
        )

        /// `PATCH /api/v1/projects/:id` with partial body — nil
        /// fields are omitted, matching the partial-PATCH semantics
        /// already in `ProjectServicing/update`.
        case updateProject(
            projectID: String,
            name: String?,
            description: String?
        )

        /// Human-readable category label for diagnostics / logs.
        public var category: String {
            switch self {
            case .createCaptureSession:      return "capture.create"
            case .updateCaptureSessionState: return "capture.state"
            case .updateCaptureLabel:        return "capture.label"
            case .createProject:             return "project.create"
            case .updateProject:             return "project.update"
            }
        }
    }

    /// Terminal capture-session states the server accepts on
    /// PATCH. Same shape as ``CaptureSession/EndState`` —
    /// duplicated here so the variant payload doesn't pull in
    /// the whole capture types when this file is read on its
    /// own.
    public enum TerminalState: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        case completed
        case cancelled
    }

    // MARK: - State

    /// Lifecycle of a queued operation. Mirrors
    /// ``PendingUpload/State`` so the two queues can share UI
    /// patterns later if we surface them in the same view.
    public enum State: Sendable, Equatable, Hashable, Codable {
        /// Sitting on disk, waiting for the worker to pick up.
        case queued
        /// Worker is in flight.
        case running
        /// Server returned 2xx and acknowledged the op. The entry
        /// is removed from the queue immediately after broadcast
        /// (same auto-retire as PR #60's upload coordinator fix).
        case succeeded
        /// Server returned a non-success or transport failed.
        /// `permanent == true` means we won't auto-retry
        /// (4xx validation / forbidden); `false` means transient
        /// (5xx / network) and the worker will back off + retry.
        case failed(reason: String, permanent: Bool)

        public var isTerminal: Bool {
            switch self {
            case .succeeded:               return true
            case .failed(_, let permanent): return permanent
            case .queued, .running:        return false
            }
        }
    }
}
