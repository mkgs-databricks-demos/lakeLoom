import Foundation

/// Production ``ProjectServicing`` actor.
///
/// Composes the auth + endpoint resolution + HTTP client + cache +
/// defaults layers. Public methods route through the actor executor;
/// the cache and inflight-task dedup map are actor-isolated.
///
/// See `architecture/LakeLoomMarkdowns/module-06-project-service.md`.
public actor ProjectService: ProjectServicing {

    // MARK: Dependencies

    private let auth: any AuthServicing
    private let endpointResolver: any AppEndpointResolving
    private let api: any ProjectAPIClient
    private let cache: ProjectCache
    private let defaults: any DefaultsStore
    /// Optional disk-persistent project-list cache. When wired,
    /// every successful list / upsert / remove mirrors into it so a
    /// cold launch without network can still render the projects
    /// the user saw most recently. Production wiring sets this;
    /// tests omit it.
    private let listStore: ProjectListStore?
    private let logger: AppLogger
    private let nowProvider: @Sendable () -> Date
    /// Offline outbox, late-attached at bootstrap via
    /// ``attachOperationQueue(_:)`` (the queue is built *after* the
    /// service because the queue's executor depends on the service, so
    /// it can't be an init dependency without a construction cycle).
    /// When present + ``offlineCreateEnabled``, ``create`` mints the
    /// project locally and enqueues a `.createProject` op instead of
    /// blocking on the network.
    private var operationQueue: (any OperationQueueing)?
    /// Gates the queue-first offline-create path. Defaults off: the
    /// path returns a locally-minted project whose id the caller then
    /// uses for captures, which is only correct once Genie confirms
    /// Option-A (server adopts `client_generated_id` as the project's
    /// row id). Flip to `true` after that confirmation lands.
    private let offlineCreateEnabled: Bool

    // MARK: State

    private var diagnosticsState = ProjectServiceDiagnostics.zero
    private var eventContinuations: [UUID: AsyncStream<ProjectChangeEvent>.Continuation] = [:]
    private var started = false

    // MARK: Init

    public init(
        auth: any AuthServicing,
        endpointResolver: any AppEndpointResolving,
        api: any ProjectAPIClient,
        defaults: any DefaultsStore = LiveDefaultsStore(),
        listStore: ProjectListStore? = nil,
        cacheTTL: TimeInterval = 5 * 60,
        offlineCreateEnabled: Bool = false,
        logger: AppLogger = AppLogger(category: .projects),
        nowProvider: @Sendable @escaping () -> Date = Date.init
    ) {
        self.auth = auth
        self.endpointResolver = endpointResolver
        self.api = api
        self.defaults = defaults
        self.listStore = listStore
        self.cache = ProjectCache(ttl: cacheTTL, nowProvider: nowProvider)
        self.offlineCreateEnabled = offlineCreateEnabled
        self.logger = logger
        self.nowProvider = nowProvider
    }

    /// Late-attach the offline outbox (see ``operationQueue``). Called
    /// once at bootstrap after the queue is constructed.
    public func attachOperationQueue(_ queue: any OperationQueueing) {
        operationQueue = queue
    }

    // MARK: Public surface

    public func start() async {
        guard !started else { return }
        started = true
    }

    public var changes: AsyncStream<ProjectChangeEvent> {
        get async {
            let (stream, continuation) = AsyncStream<ProjectChangeEvent>.makeStream()
            let id = UUID()
            // Synchronous registration: by the time `await service.changes`
            // returns the subscriber is already in the broadcast set, so
            // immediately-following events (e.g. from a `create` that
            // happens right after) reach this subscriber.
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.unsubscribe(id: id) }
            }
            return stream
        }
    }

    public func list(workspaceID: String, forceRefresh: Bool) async throws -> [ProjectMetadata] {
        if forceRefresh {
            return try await fetchAndCache(workspaceID: workspaceID)
        }
        switch await cache.snapshot(workspaceID: workspaceID) {
        case .fresh(let projects):
            return projects
        case .stale(let projects):
            // Stale-while-revalidate: serve immediately, refresh in background.
            Task { [weak self] in
                _ = try? await self?.fetchAndCache(workspaceID: workspaceID)
            }
            return projects
        case .miss:
            // Cold-launch survival: hydrate from the on-disk
            // ``listStore`` before falling through to the network.
            // If the disk has projects we've seen before, serve them
            // immediately and kick a background refresh — same
            // pattern as the `.stale` branch above. Only fall to
            // `fetchAndCache` (which can throw on a network error)
            // when the disk is also empty.
            if let stored = await listStore?.load(workspaceID: workspaceID),
               !stored.isEmpty {
                await cache.store(stored, workspaceID: workspaceID)
                Task { [weak self] in
                    _ = try? await self?.fetchAndCache(workspaceID: workspaceID)
                }
                return stored
            }
            return try await fetchAndCache(workspaceID: workspaceID)
        }
    }

    public func fetch(projectID: String, workspaceID: String) async throws -> ProjectMetadata {
        if let cached = await cache.projects(workspaceID: workspaceID),
           let hit = cached.first(where: { $0.id == projectID }) {
            return hit
        }
        // Cold-launch survival: hydrate the in-memory cache from
        // disk before falling through to the network. Lets
        // `AppCoordinator.bootstrap` (which calls `fetch` via
        // `defaultProject`) reach `.ready` from a cached project
        // when the network is down. The disk-hit also short-
        // circuits the network round trip on warm launches, which
        // matters for startup latency.
        if let stored = await listStore?.load(workspaceID: workspaceID),
           let hit = stored.first(where: { $0.id == projectID }) {
            await cache.store(stored, workspaceID: workspaceID)
            return hit
        }
        let token = try await auth.currentToken()
        let endpoint = try await endpointResolver.resolve(
            workspaceID: workspaceID,
            workspaceURL: workspaceURL(for: workspaceID, fallbackTo: token)
        )
        let project: ProjectMetadata
        do {
            project = try await api.fetch(
                projectID: projectID,
                workspaceID: workspaceID,
                token: token,
                endpoint: endpoint
            )
        } catch ProjectAPIError.unauthorized {
            project = try await retryAfterForceRefresh { newToken in
                try await self.api.fetch(
                    projectID: projectID,
                    workspaceID: workspaceID,
                    token: newToken,
                    endpoint: endpoint
                )
            }
        } catch {
            throw ProjectErrorMapper.map(error)
        }
        // Populate the in-memory cache + disk store so a subsequent
        // offline lookup of this project (or the list it belongs to)
        // can serve from local state. Without this, the bootstrap
        // path's defaultProject → fetch network call would hydrate
        // activeContext but leave the cache empty — and the next
        // offline tap on the project switcher would surface
        // "you're offline" even though the user just used the app
        // online a moment ago.
        await cache.upsert(project, workspaceID: workspaceID)
        await mirrorCacheToStore(workspaceID: workspaceID)
        return project
    }

    public func create(name: String, description: String?, workspaceID: String) async throws -> ProjectMetadata {
        let normalizedName = try ProjectValidator.validateName(name)
        let normalizedDescription = try ProjectValidator.validateDescription(description)

        // Queue-first offline path (gated). Mint the project locally,
        // surface it in the cache/picker immediately, and enqueue a
        // `.createProject` op the outbox drains on reconnect. The
        // returned id IS the `client_generated_id` — correct for the
        // caller to start captures against ONLY under Option-A (server
        // adopts it as the row id), which is why this is gated.
        if offlineCreateEnabled, let operationQueue {
            return try await createOffline(
                name: normalizedName,
                description: normalizedDescription,
                workspaceID: workspaceID,
                queue: operationQueue
            )
        }

        let payload = CreateProjectPayload(
            clientGeneratedID: UUIDv7.generate(now: nowProvider()),
            name: normalizedName,
            description: normalizedDescription,
            workspaceID: workspaceID
        )

        let token = try await auth.currentToken()
        let endpoint = try await endpointResolver.resolve(
            workspaceID: workspaceID,
            workspaceURL: workspaceURL(for: workspaceID, fallbackTo: token)
        )

        let project: ProjectMetadata
        do {
            project = try await api.create(payload, token: token, endpoint: endpoint)
        } catch ProjectAPIError.unauthorized {
            project = try await retryAfterForceRefresh { newToken in
                try await self.api.create(payload, token: newToken, endpoint: endpoint)
            }
        } catch {
            throw ProjectErrorMapper.map(error)
        }

        await cache.upsert(project, workspaceID: workspaceID)
        await mirrorCacheToStore(workspaceID: workspaceID)
        diagnosticsState.recordCreate(at: nowProvider())
        broadcast(.projectCreated(project))
        await logger.info(
            "project created",
            metadata: [
                "project_id": .uuidPrefix(project.id),
                "workspace_id": .uuidPrefix(workspaceID),
                "client_generated_id": .uuidPrefix(payload.clientGeneratedID)
            ]
        )
        return project
    }

    /// Queue-first create: mint a local ``ProjectMetadata`` (its id is
    /// the `client_generated_id`), upsert it so the picker shows it at
    /// once, enqueue a `.createProject` op, and return immediately
    /// without touching the network. The op's drain calls
    /// ``submitQueuedCreate(projectID:name:description:workspaceID:)``,
    /// which replaces this placeholder with the server's canonical row.
    private func createOffline(
        name: String,
        description: String?,
        workspaceID: String,
        queue: any OperationQueueing
    ) async throws -> ProjectMetadata {
        let now = nowProvider()
        let localID = UUIDv7.generate(now: now)
        // Best-effort local identity for display until the server's
        // canonical `created_by_*` lands via submitQueuedCreate's upsert.
        let user = await auth.activeWorkspace?.user
        let local = ProjectMetadata(
            id: localID,
            name: name,
            description: description,
            workspaceID: workspaceID,
            createdByUserID: user?.userID ?? "",
            createdByUsername: user?.userName ?? (user?.email ?? ""),
            createdAt: now,
            updatedAt: now,
            archived: false
        )

        let op = PendingOperation(
            id: UUIDv7.generate(now: now),
            workspaceID: workspaceID,
            variant: .createProject(
                projectID: localID,
                name: name,
                description: description
            ),
            createdAt: now
        )
        do {
            try await queue.enqueue(op)
        } catch {
            // The outbox persists on enqueue; a failure here means the
            // on-disk store is unhealthy and we can't promise the
            // project will ever reconcile. Surface it rather than
            // silently dropping the create.
            throw ProjectError.unknown(reason: "outbox enqueue: \(error.localizedDescription)")
        }

        await cache.upsert(local, workspaceID: workspaceID)
        await mirrorCacheToStore(workspaceID: workspaceID)
        diagnosticsState.recordCreate(at: now)
        broadcast(.projectCreated(local))
        await logger.info(
            "project.create.queued_offline",
            metadata: [
                "project_id": .uuidPrefix(localID),
                "workspace_id": .uuidPrefix(workspaceID)
            ]
        )
        return local
    }

    public func submitQueuedCreate(
        projectID: String,
        name: String,
        description: String?,
        workspaceID: String
    ) async throws {
        let payload = CreateProjectPayload(
            clientGeneratedID: projectID,
            name: name,
            description: description,
            workspaceID: workspaceID
        )
        let token = try await auth.currentToken()
        let endpoint = try await endpointResolver.resolve(
            workspaceID: workspaceID,
            workspaceURL: workspaceURL(for: workspaceID, fallbackTo: token)
        )
        // Deliberately NOT routed through ProjectErrorMapper / the
        // `retryAfterForceRefresh` helper (both wrap into `ProjectError`):
        // the executor needs the raw ProjectAPIError to classify
        // transient vs permanent. We still give `unauthorized` one
        // force-refresh retry inline — the outbox token may simply have
        // expired — but any failure of the retried call surfaces as the
        // raw ProjectAPIError for the executor to classify.
        let project: ProjectMetadata
        do {
            project = try await api.create(payload, token: token, endpoint: endpoint)
        } catch ProjectAPIError.unauthorized {
            let newToken = try await auth.currentToken(forceRefresh: true)
            project = try await api.create(payload, token: newToken, endpoint: endpoint)
        }
        // Replace the local placeholder with the server's canonical row
        // (corrects created_by_*, timestamps; id is unchanged under
        // Option-A). Broadcast so any open picker refreshes.
        await cache.upsert(project, workspaceID: workspaceID)
        await mirrorCacheToStore(workspaceID: workspaceID)
        broadcast(.projectUpdated(project))
        await logger.info(
            "project.create.queued_reconciled",
            metadata: [
                "project_id": .uuidPrefix(project.id),
                "workspace_id": .uuidPrefix(workspaceID)
            ]
        )
    }

    public func update(
        projectID: String,
        workspaceID: String,
        name: String?,
        description: String?
    ) async throws -> ProjectMetadata {
        // Validate up front so we don't burn a network round trip on
        // a payload the server will reject. Each branch normalizes
        // the input (trim whitespace, length cap) — same rules the
        // create path uses.
        let normalizedName: String?
        if let name {
            normalizedName = try ProjectValidator.validateName(name)
        } else {
            normalizedName = nil
        }
        let normalizedDescription: String?
        if let description {
            normalizedDescription = try ProjectValidator.validateDescription(description)
        } else {
            normalizedDescription = nil
        }
        guard normalizedName != nil || normalizedDescription != nil else {
            throw ProjectError.validationFailed(reason: "At least one of name or description must be provided.")
        }

        let token = try await auth.currentToken()
        let endpoint = try await endpointResolver.resolve(
            workspaceID: workspaceID,
            workspaceURL: workspaceURL(for: workspaceID, fallbackTo: token)
        )

        let project: ProjectMetadata
        do {
            project = try await api.update(
                projectID: projectID,
                workspaceID: workspaceID,
                name: normalizedName,
                description: normalizedDescription,
                token: token,
                endpoint: endpoint
            )
        } catch ProjectAPIError.unauthorized {
            project = try await retryAfterForceRefresh { newToken in
                try await self.api.update(
                    projectID: projectID,
                    workspaceID: workspaceID,
                    name: normalizedName,
                    description: normalizedDescription,
                    token: newToken,
                    endpoint: endpoint
                )
            }
        } catch {
            throw ProjectErrorMapper.map(error)
        }

        await cache.upsert(project, workspaceID: workspaceID)
        await mirrorCacheToStore(workspaceID: workspaceID)
        broadcast(.projectUpdated(project))
        await logger.info(
            "project updated",
            metadata: [
                "project_id": .uuidPrefix(project.id),
                "workspace_id": .uuidPrefix(workspaceID),
                "fields": .string([
                    normalizedName != nil ? "name" : nil,
                    normalizedDescription != nil ? "description" : nil
                ].compactMap { $0 }.joined(separator: ","))
            ]
        )
        return project
    }

    public func archive(projectID: String, workspaceID: String) async throws {
        try await runArchiveAction(.archive, projectID: projectID, workspaceID: workspaceID)
    }

    public func unarchive(projectID: String, workspaceID: String) async throws {
        try await runArchiveAction(.unarchive, projectID: projectID, workspaceID: workspaceID)
    }

    public func defaultProject(workspaceID: String) async -> ProjectMetadata? {
        guard let projectID = await defaults.defaultProjectID(workspaceID: workspaceID) else {
            return nil
        }
        do {
            return try await fetch(projectID: projectID, workspaceID: workspaceID)
        } catch ProjectError.notFound {
            await defaults.clearDefault(workspaceID: workspaceID)
            return nil
        } catch {
            // Network or auth failure — return nil; AppCoordinator will fall
            // back to firstAvailableProject() and surface the error
            // separately.
            return nil
        }
    }

    public func setDefault(projectID: String, workspaceID: String) async throws {
        // Verify the project exists before persisting the choice.
        _ = try await fetch(projectID: projectID, workspaceID: workspaceID)
        await defaults.setDefaultProjectID(projectID, workspaceID: workspaceID)
        broadcast(.defaultChanged(workspaceID: workspaceID, projectID: projectID))
    }

    public func firstAvailableProject(workspaceID: String) async -> ProjectMetadata? {
        do {
            let list = try await list(workspaceID: workspaceID, forceRefresh: false)
            return list.first(where: { !$0.archived })
        } catch {
            return nil
        }
    }

    public func refreshIfStale(workspaceID: String) async {
        switch await cache.snapshot(workspaceID: workspaceID) {
        case .stale, .miss:
            _ = try? await fetchAndCache(workspaceID: workspaceID)
        case .fresh:
            break
        }
    }

    public func diagnostics() async -> ProjectServiceDiagnostics {
        var snapshot = diagnosticsState
        snapshot = ProjectServiceDiagnostics(
            cacheEntries: await cache.entryCount(),
            cacheHitRateLastHour: snapshot.cacheHitRateLastHour,
            lastListFetchAt: snapshot.lastListFetchAt,
            lastCreateAt: snapshot.lastCreateAt,
            totalListCallsLifetime: snapshot.totalListCallsLifetime,
            totalCreateCallsLifetime: snapshot.totalCreateCallsLifetime,
            lastAppErrorReason: snapshot.lastAppErrorReason
        )
        return snapshot
    }

    // MARK: - Private

    private enum ArchiveAction { case archive, unarchive }

    private func runArchiveAction(
        _ action: ArchiveAction,
        projectID: String,
        workspaceID: String
    ) async throws {
        let token = try await auth.currentToken()
        let endpoint = try await endpointResolver.resolve(
            workspaceID: workspaceID,
            workspaceURL: workspaceURL(for: workspaceID, fallbackTo: token)
        )
        do {
            switch action {
            case .archive:
                try await api.archive(
                    projectID: projectID,
                    workspaceID: workspaceID,
                    token: token,
                    endpoint: endpoint
                )
            case .unarchive:
                try await api.unarchive(
                    projectID: projectID,
                    workspaceID: workspaceID,
                    token: token,
                    endpoint: endpoint
                )
            }
        } catch ProjectAPIError.unauthorized {
            try await retryArchiveAfterForceRefresh(
                action: action,
                projectID: projectID,
                workspaceID: workspaceID,
                endpoint: endpoint
            )
        } catch {
            throw ProjectErrorMapper.map(error)
        }

        switch action {
        case .archive:
            await cache.remove(projectID: projectID, workspaceID: workspaceID)
            await mirrorCacheToStore(workspaceID: workspaceID)
            broadcast(.projectArchived(projectID: projectID, workspaceID: workspaceID))
        case .unarchive:
            // Refresh cache so the restored project re-appears with its
            // current state. We could fetch by id, but a list refresh keeps
            // ordering / archived state right for everything.
            // `fetchAndCache` mirrors the new list into the store
            // already, so no separate save needed here.
            if let refreshed = try? await fetchAndCache(workspaceID: workspaceID),
               let restored = refreshed.first(where: { $0.id == projectID }) {
                broadcast(.projectUnarchived(restored))
            }
        }
    }

    private func retryArchiveAfterForceRefresh(
        action: ArchiveAction,
        projectID: String,
        workspaceID: String,
        endpoint: AppEndpoint
    ) async throws {
        let newToken: AccessToken
        do {
            newToken = try await auth.currentToken(forceRefresh: true)
        } catch {
            throw ProjectErrorMapper.map(error)
        }
        do {
            switch action {
            case .archive:
                try await api.archive(
                    projectID: projectID,
                    workspaceID: workspaceID,
                    token: newToken,
                    endpoint: endpoint
                )
            case .unarchive:
                try await api.unarchive(
                    projectID: projectID,
                    workspaceID: workspaceID,
                    token: newToken,
                    endpoint: endpoint
                )
            }
        } catch {
            throw ProjectErrorMapper.map(error)
        }
    }

    private func fetchAndCache(workspaceID: String) async throws -> [ProjectMetadata] {
        if let inflight = await cache.inFlightTask(for: workspaceID) {
            do {
                return try await inflight.value
            } catch {
                throw ProjectErrorMapper.map(error)
            }
        }

        let task = Task<[ProjectMetadata], any Error> { [self] in
            try await self.executeListFetch(workspaceID: workspaceID)
        }
        await cache.setInFlight(task, for: workspaceID)
        defer { Task { await cache.clearInFlight(for: workspaceID) } }

        do {
            return try await task.value
        } catch {
            throw ProjectErrorMapper.map(error)
        }
    }

    private func executeListFetch(workspaceID: String) async throws -> [ProjectMetadata] {
        let token = try await auth.currentToken()
        let endpoint = try await endpointResolver.resolve(
            workspaceID: workspaceID,
            workspaceURL: workspaceURL(for: workspaceID, fallbackTo: token)
        )
        let response: ProjectListResponse
        do {
            response = try await api.list(
                workspaceID: workspaceID,
                query: nil,
                limit: 200,
                token: token,
                endpoint: endpoint
            )
        } catch ProjectAPIError.unauthorized {
            response = try await retryAfterForceRefresh { newToken in
                try await self.api.list(
                    workspaceID: workspaceID,
                    query: nil,
                    limit: 200,
                    token: newToken,
                    endpoint: endpoint
                )
            }
        }
        await cache.store(response.projects, workspaceID: workspaceID)
        await listStore?.save(response.projects, workspaceID: workspaceID)
        diagnosticsState.recordListFetch(at: nowProvider())
        broadcast(.listRefreshed(workspaceID: workspaceID, projects: response.projects))
        return response.projects
    }

    /// Snapshot the in-memory cache for `workspaceID` and mirror it
    /// to ``listStore`` (if wired). Called after every per-row write
    /// (`upsert`, `remove`) so the disk copy stays in sync without
    /// having to thread the new project list through every call
    /// site. Fire-and-forget at the call site — the writer is
    /// already async, the actor serializes, and a failed save is
    /// non-fatal (the cache stays correct in memory).
    private func mirrorCacheToStore(workspaceID: String) async {
        guard let listStore else { return }
        let current = await cache.projects(workspaceID: workspaceID) ?? []
        await listStore.save(current, workspaceID: workspaceID)
    }

    private func retryAfterForceRefresh<T: Sendable>(
        _ work: @Sendable (AccessToken) async throws -> T
    ) async throws -> T {
        let newToken: AccessToken
        do {
            newToken = try await auth.currentToken(forceRefresh: true)
        } catch {
            throw ProjectErrorMapper.map(error)
        }
        do {
            return try await work(newToken)
        } catch {
            throw ProjectErrorMapper.map(error)
        }
    }

    /// Best-effort workspace URL lookup for endpoint resolution. Reads
    /// the active workspace's URL from AuthService when the workspace
    /// in question matches the active one. Otherwise falls back to a
    /// constructed URL using the token's workspace_id host (which is
    /// what AuthService sets as the workspace ID per Module 01 §5.7).
    private func workspaceURL(for workspaceID: String, fallbackTo token: AccessToken) async -> URL {
        if let active = await auth.activeWorkspace, active.id == workspaceID {
            return active.workspaceURL
        }
        // Fallback: workspace ID is the host string per Module 01's
        // current convention. https://<host>/ is the workspace root.
        return URL(string: "https://\(workspaceID)") ?? URL(fileURLWithPath: "/")
    }

    // MARK: Events

    private func unsubscribe(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func broadcast(_ event: ProjectChangeEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }
}

// MARK: - Diagnostics helpers

private extension ProjectServiceDiagnostics {

    mutating func recordListFetch(at date: Date) {
        self = ProjectServiceDiagnostics(
            cacheEntries: self.cacheEntries,
            cacheHitRateLastHour: self.cacheHitRateLastHour,
            lastListFetchAt: date,
            lastCreateAt: self.lastCreateAt,
            totalListCallsLifetime: self.totalListCallsLifetime + 1,
            totalCreateCallsLifetime: self.totalCreateCallsLifetime,
            lastAppErrorReason: self.lastAppErrorReason
        )
    }

    mutating func recordCreate(at date: Date) {
        self = ProjectServiceDiagnostics(
            cacheEntries: self.cacheEntries,
            cacheHitRateLastHour: self.cacheHitRateLastHour,
            lastListFetchAt: self.lastListFetchAt,
            lastCreateAt: date,
            totalListCallsLifetime: self.totalListCallsLifetime,
            totalCreateCallsLifetime: self.totalCreateCallsLifetime + 1,
            lastAppErrorReason: self.lastAppErrorReason
        )
    }
}
