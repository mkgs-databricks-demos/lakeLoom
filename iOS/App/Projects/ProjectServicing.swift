import Foundation

/// The iOS-side interface to project metadata, served by the Databricks
/// App's REST API. AppCoordinator and Settings UIs call into this; the
/// underlying transport is ``ProjectAPIClient``.
///
/// See `architecture/LakeLoomMarkdowns/module-06-project-service.md`.
public protocol ProjectServicing: Sendable {

    /// Bring the service into a usable state. Lightweight — does not
    /// block on network. Heavy work (the initial list fetch) is deferred
    /// to the first call.
    func start() async

    /// List non-archived projects for `workspaceID`. Honors the in-memory
    /// 5-min TTL cache; ``forceRefresh: true`` bypasses it (e.g., on
    /// pull-to-refresh).
    func list(workspaceID: String, forceRefresh: Bool) async throws -> [ProjectMetadata]

    /// Fetch a single project by ID. Cache-first (looks for the project
    /// in the cached list), then network.
    func fetch(projectID: String, workspaceID: String) async throws -> ProjectMetadata

    /// Create a new project in `workspaceID`. iOS generates a UUIDv7
    /// `client_generated_id` so retries are idempotent — re-submitting
    /// the same `(workspaceID, client_generated_id)` returns the
    /// existing project rather than failing.
    ///
    /// When an offline outbox is attached (see
    /// ``ProjectService/attachOperationQueue(_:)``) **and** offline
    /// create is enabled, this takes a queue-first path: the project is
    /// minted locally with the `client_generated_id` as its id, shown
    /// in the picker immediately, and reconciled to the server when the
    /// queue drains. Otherwise it's a direct online create.
    func create(name: String, description: String?, workspaceID: String) async throws -> ProjectMetadata

    /// Executor entry point: submit a queued offline project-create to
    /// the server, using the locally-minted `projectID` as the
    /// `client_generated_id` (idempotent — a re-submit returns the
    /// existing row). Upserts the server's canonical metadata into the
    /// cache on success. Throws the raw ``ProjectAPIError`` (unmapped)
    /// so ``OperationExecutor`` can classify transient vs permanent —
    /// it is **not** routed through ``ProjectErrorMapper`` like the
    /// user-facing ``create(name:description:workspaceID:)``.
    ///
    /// Depends on Genie confirming Option-A semantics for
    /// `POST /api/v1/projects` (row id == `client_generated_id`); until
    /// then the queue-first path in `create` stays gated off.
    func submitQueuedCreate(
        projectID: String,
        name: String,
        description: String?,
        workspaceID: String
    ) async throws

    /// Update a project's name and/or description. At least one of
    /// the two must be non-nil; passing both nil throws
    /// ``ProjectError/validationFailed`` without hitting the network.
    /// Returns the server's canonical post-update ``ProjectMetadata``;
    /// also invalidates the cache for `workspaceID` so the next
    /// `list` reflects the change.
    func update(
        projectID: String,
        workspaceID: String,
        name: String?,
        description: String?
    ) async throws -> ProjectMetadata

    /// Archive a project (soft delete). The remote project is preserved;
    /// list calls hide it by default. Restore via ``unarchive``.
    func archive(projectID: String, workspaceID: String) async throws

    /// Restore an archived project so it appears in list results again.
    func unarchive(projectID: String, workspaceID: String) async throws

    /// User's default project for a workspace, if set. Reads from
    /// device-local UserDefaults; cheap, no network.
    func defaultProject(workspaceID: String) async -> ProjectMetadata?

    /// Set the default project for `workspaceID`. Verifies the project
    /// exists before persisting. Emits ``ProjectChangeEvent/defaultChanged``.
    func setDefault(projectID: String, workspaceID: String) async throws

    /// First-available (non-archived, most-recently-updated) project for
    /// `workspaceID`. Used as the bootstrap fallback when no default is set.
    func firstAvailableProject(workspaceID: String) async -> ProjectMetadata?

    /// Refresh the cache for `workspaceID` if its entry is older than
    /// the TTL. Non-throwing — used for opportunistic background
    /// refreshes; failures are swallowed and surfaced via diagnostics.
    func refreshIfStale(workspaceID: String) async

    /// Stream of changes to the project list for any workspace. Sessions
    /// list view-models subscribe to keep rows fresh as the user creates
    /// or archives projects elsewhere.
    ///
    /// `get async` because subscription registration runs on the actor.
    /// By the time `await service.changes` returns, the subscriber's
    /// continuation is already in the broadcast set — any event fired
    /// after the await reaches this subscriber.
    var changes: AsyncStream<ProjectChangeEvent> { get async }

    /// Snapshot of internal counters for the diagnostics screen.
    func diagnostics() async -> ProjectServiceDiagnostics
}

extension ProjectServicing {
    /// Convenience overload — equivalent to
    /// `list(workspaceID: workspaceID, forceRefresh: false)`.
    public func list(workspaceID: String) async throws -> [ProjectMetadata] {
        try await list(workspaceID: workspaceID, forceRefresh: false)
    }
}
