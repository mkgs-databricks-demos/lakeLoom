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
    private let logger: AppLogger
    private let nowProvider: @Sendable () -> Date

    // MARK: State

    private var diagnosticsState = ProjectServiceDiagnostics.zero
    private var eventContinuations: [UUID: AsyncStream<ProjectChangeEvent>.Continuation] = [:]
    private var started = false

    // MARK: Init

    public init(
        auth: any AuthServicing,
        endpointResolver: any AppEndpointResolving,
        api: any ProjectAPIClient = LiveProjectAPIClient(),
        defaults: any DefaultsStore = LiveDefaultsStore(),
        cacheTTL: TimeInterval = 5 * 60,
        logger: AppLogger = AppLogger(category: .projects),
        nowProvider: @Sendable @escaping () -> Date = Date.init
    ) {
        self.auth = auth
        self.endpointResolver = endpointResolver
        self.api = api
        self.defaults = defaults
        self.cache = ProjectCache(ttl: cacheTTL, nowProvider: nowProvider)
        self.logger = logger
        self.nowProvider = nowProvider
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
            return try await fetchAndCache(workspaceID: workspaceID)
        }
    }

    public func fetch(projectID: String, workspaceID: String) async throws -> ProjectMetadata {
        if let cached = await cache.projects(workspaceID: workspaceID),
           let hit = cached.first(where: { $0.id == projectID }) {
            return hit
        }
        let token = try await auth.currentToken()
        let endpoint = try await endpointResolver.resolve(
            workspaceID: workspaceID,
            workspaceURL: workspaceURL(for: workspaceID, fallbackTo: token)
        )
        do {
            return try await api.fetch(
                projectID: projectID,
                workspaceID: workspaceID,
                token: token,
                endpoint: endpoint
            )
        } catch ProjectAPIError.unauthorized {
            return try await retryAfterForceRefresh { newToken in
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
    }

    public func create(name: String, description: String?, workspaceID: String) async throws -> ProjectMetadata {
        let normalizedName = try ProjectValidator.validateName(name)
        let normalizedDescription = try ProjectValidator.validateDescription(description)
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
            broadcast(.projectArchived(projectID: projectID, workspaceID: workspaceID))
        case .unarchive:
            // Refresh cache so the restored project re-appears with its
            // current state. We could fetch by id, but a list refresh keeps
            // ordering / archived state right for everything.
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
        diagnosticsState.recordListFetch(at: nowProvider())
        broadcast(.listRefreshed(workspaceID: workspaceID, projects: response.projects))
        return response.projects
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
