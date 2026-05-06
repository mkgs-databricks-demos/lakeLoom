import Foundation

/// In-memory per-workspace project list cache for ``ProjectService``.
///
/// Default TTL is 5 minutes (Module 06 §10.1). Beyond TTL the entry is
/// considered "stale" and the next read triggers a refresh — but stale
/// entries are still returned synchronously to the caller so the
/// project picker is instant; the refresh runs in the background and
/// emits ``ProjectChangeEvent/listRefreshed`` if the contents changed.
///
/// Concurrent fetches for the same workspace dedupe via ``inFlight``
/// — both callers share the result of one network round trip.
actor ProjectCache {

    private var entries: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<[ProjectMetadata], any Error>] = [:]
    private let ttl: TimeInterval
    private let nowProvider: @Sendable () -> Date

    init(
        ttl: TimeInterval = 5 * 60,
        nowProvider: @Sendable @escaping () -> Date = Date.init
    ) {
        self.ttl = ttl
        self.nowProvider = nowProvider
    }

    // MARK: Reads

    /// Synchronous read — returns the cached list if any, plus whether
    /// it's fresh. Caller decides whether to use it directly, refresh in
    /// the background, or block on a refresh.
    func snapshot(workspaceID: String) -> CacheSnapshot {
        guard let entry = entries[workspaceID] else { return .miss }
        return entry.isStale(now: nowProvider()) ? .stale(entry.projects) : .fresh(entry.projects)
    }

    func projects(workspaceID: String) -> [ProjectMetadata]? {
        entries[workspaceID]?.projects
    }

    func entryCount() -> Int {
        entries.count
    }

    // MARK: Writes

    func store(_ projects: [ProjectMetadata], workspaceID: String) {
        entries[workspaceID] = CacheEntry(
            projects: projects,
            fetchedAt: nowProvider(),
            ttl: ttl
        )
    }

    /// Insert a single project into the cached list (used after create()
    /// so the new project is selectable immediately).
    func upsert(_ project: ProjectMetadata, workspaceID: String) {
        var current = entries[workspaceID]?.projects ?? []
        if let idx = current.firstIndex(where: { $0.id == project.id }) {
            current[idx] = project
        } else {
            current.insert(project, at: 0)
        }
        entries[workspaceID] = CacheEntry(
            projects: current,
            fetchedAt: nowProvider(),
            ttl: ttl
        )
    }

    /// Remove a project from the cached list (used after archive()).
    func remove(projectID: String, workspaceID: String) {
        guard var current = entries[workspaceID]?.projects else { return }
        current.removeAll { $0.id == projectID }
        entries[workspaceID] = CacheEntry(
            projects: current,
            fetchedAt: nowProvider(),
            ttl: ttl
        )
    }

    func invalidate(workspaceID: String) {
        entries.removeValue(forKey: workspaceID)
    }

    func invalidateAll() {
        entries.removeAll(keepingCapacity: true)
    }

    // MARK: In-flight dedup

    /// Returns the in-flight task for `workspaceID`, or nil. Used by
    /// ProjectService to share a single fetch among concurrent callers.
    func inFlightTask(for workspaceID: String) -> Task<[ProjectMetadata], any Error>? {
        inFlight[workspaceID]
    }

    /// Register an in-flight task; remove it when it finishes via
    /// ``clearInFlight``.
    func setInFlight(_ task: Task<[ProjectMetadata], any Error>, for workspaceID: String) {
        inFlight[workspaceID] = task
    }

    func clearInFlight(for workspaceID: String) {
        inFlight.removeValue(forKey: workspaceID)
    }
}

enum CacheSnapshot: Sendable {
    case miss
    case fresh([ProjectMetadata])
    case stale([ProjectMetadata])
}
