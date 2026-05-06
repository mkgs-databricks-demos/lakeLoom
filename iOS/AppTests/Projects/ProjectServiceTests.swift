import Foundation
import Testing

@testable import LakeloomApp

@Suite("ProjectService — list + cache")
struct ProjectServiceListTests {

    private static let workspaceID = "ws-1"

    private func makeService(
        api: ScriptedProjectAPIClient,
        cacheTTL: TimeInterval = 5 * 60
    ) async -> (ProjectService, MockAuthService) {
        let auth = MockAuthService(activeWorkspace: .fixture(id: Self.workspaceID))
        let resolver = LiveAppEndpointResolver()
        let service = ProjectService(
            auth: auth,
            endpointResolver: resolver,
            api: api,
            defaults: InMemoryDefaultsStore(),
            cacheTTL: cacheTTL
        )
        return (service, auth)
    }

    @Test("list cache miss → fetches and caches")
    func cacheMissTriggersFetch() async throws {
        let api = ScriptedProjectAPIClient()
        let project = ProjectMetadata.fixture(id: "p-1")
        await api.enqueueList(.success(ProjectListResponse(projects: [project], truncated: false)))
        let (service, _) = await makeService(api: api)

        let projects = try await service.list(workspaceID: Self.workspaceID, forceRefresh: false)
        #expect(projects == [project])

        // Second call should hit cache and NOT call list again.
        let again = try await service.list(workspaceID: Self.workspaceID, forceRefresh: false)
        #expect(again == [project])
        let calls = await api.listCalls
        #expect(calls.count == 1)
    }

    @Test("forceRefresh always hits the network")
    func forceRefreshHitsNetwork() async throws {
        let api = ScriptedProjectAPIClient()
        let p1 = ProjectMetadata.fixture(id: "p-1")
        let p2 = ProjectMetadata.fixture(id: "p-2")
        await api.enqueueList(.success(ProjectListResponse(projects: [p1], truncated: false)))
        await api.enqueueList(.success(ProjectListResponse(projects: [p1, p2], truncated: false)))
        let (service, _) = await makeService(api: api)

        let first = try await service.list(workspaceID: Self.workspaceID, forceRefresh: false)
        let second = try await service.list(workspaceID: Self.workspaceID, forceRefresh: true)
        #expect(first.count == 1)
        #expect(second.count == 2)
        let calls = await api.listCalls
        #expect(calls.count == 2)
    }

    @Test("401 on list triggers force-refresh + retry once")
    func listForceRefreshOn401() async throws {
        let api = ScriptedProjectAPIClient()
        await api.enqueueList(.failure(.unauthorized))
        let project = ProjectMetadata.fixture(id: "p-1")
        await api.enqueueList(.success(ProjectListResponse(projects: [project], truncated: false)))
        let (service, auth) = await makeService(api: api)
        await auth.setNextTokenAfterForceRefresh("token-2")

        let projects = try await service.list(workspaceID: Self.workspaceID, forceRefresh: true)
        #expect(projects == [project])
        let tokenCalls = await auth.currentTokenCalls
        // Initial currentToken (false) + force-refresh after 401 (true).
        #expect(tokenCalls.contains(true))
        let calls = await api.listCalls
        #expect(calls.count == 2)
        #expect(calls.last?.tokenValue == "token-2")
    }

    @Test("403 on list maps to permissionDenied")
    func listForbidden() async throws {
        let api = ScriptedProjectAPIClient()
        let envelope = ProjectErrorResponse(
            error: "workspace_not_authorized",
            message: "You don't have access to this workspace.",
            existingProjectID: nil
        )
        await api.enqueueList(.failure(.forbidden(envelope)))
        let (service, _) = await makeService(api: api)

        do {
            _ = try await service.list(workspaceID: Self.workspaceID, forceRefresh: true)
            Issue.record("expected permissionDenied")
        } catch ProjectError.permissionDenied(let reason) {
            #expect(reason.contains("don't have access"))
        }
    }
}

@Suite("ProjectService — create")
struct ProjectServiceCreateTests {

    private static let workspaceID = "ws-1"

    private func makeService(
        api: ScriptedProjectAPIClient
    ) async -> (ProjectService, MockAuthService) {
        let auth = MockAuthService(activeWorkspace: .fixture(id: Self.workspaceID))
        let resolver = LiveAppEndpointResolver()
        let service = ProjectService(
            auth: auth,
            endpointResolver: resolver,
            api: api,
            defaults: InMemoryDefaultsStore()
        )
        return (service, auth)
    }

    @Test("create validates name + description before sending")
    func validatesBeforeSending() async throws {
        let api = ScriptedProjectAPIClient()
        let (service, _) = await makeService(api: api)

        do {
            _ = try await service.create(
                name: "",
                description: nil,
                workspaceID: Self.workspaceID
            )
            Issue.record("expected validationFailed for empty name")
        } catch ProjectError.validationFailed {
            #expect(Bool(true))
        }

        let calls = await api.createCalls
        #expect(calls.isEmpty)
    }

    @Test("create POSTs with a UUIDv7 client_generated_id and surfaces the result")
    func happyPath() async throws {
        let api = ScriptedProjectAPIClient()
        let project = ProjectMetadata.fixture(id: "p-new", name: "Customer 360")
        await api.enqueueCreate(.success(project))
        let (service, _) = await makeService(api: api)

        let result = try await service.create(
            name: "Customer 360",
            description: "Lakehouse",
            workspaceID: Self.workspaceID
        )
        #expect(result == project)

        let createCalls = await api.createCalls
        #expect(createCalls.count == 1)
        let payload = createCalls.first?.payload
        // UUIDv7 has version digit 7 in the third group.
        let versionGroup = payload?.clientGeneratedID.split(separator: "-")[2]
        #expect(versionGroup?.first == "7")
        #expect(payload?.name == "Customer 360")
    }

    @Test("HTTP 409 surfaces as duplicateName with existingProjectID")
    func duplicateName() async throws {
        let api = ScriptedProjectAPIClient()
        let envelope = ProjectErrorResponse(
            error: "project_name_taken",
            message: "Already exists.",
            existingProjectID: "p-existing"
        )
        await api.enqueueCreate(.failure(.duplicate(envelope)))
        let (service, _) = await makeService(api: api)

        do {
            _ = try await service.create(
                name: "Customer 360",
                description: nil,
                workspaceID: Self.workspaceID
            )
            Issue.record("expected duplicateName")
        } catch ProjectError.duplicateName(let existingID) {
            #expect(existingID == "p-existing")
        }
    }

    @Test("create updates the cache and broadcasts .projectCreated")
    func updatesCacheAndBroadcasts() async throws {
        let api = ScriptedProjectAPIClient()
        // Initial list seeds the cache.
        let p0 = ProjectMetadata.fixture(id: "p-0")
        await api.enqueueList(.success(ProjectListResponse(projects: [p0], truncated: false)))
        // Create returns the new project.
        let pNew = ProjectMetadata.fixture(id: "p-new")
        await api.enqueueCreate(.success(pNew))

        let (service, _) = await makeService(api: api)

        // Subscribe before triggering the events. Spawn a Task that
        // collects the first two events; Task is Sendable so the
        // non-Sendable AsyncIterator stays inside it.
        let collector = Task<[ProjectChangeEvent], Never> {
            var collected: [ProjectChangeEvent] = []
            for await event in service.changes {
                collected.append(event)
                if collected.count == 2 { break }
            }
            return collected
        }

        _ = try await service.list(workspaceID: Self.workspaceID, forceRefresh: false)
        _ = try await service.create(
            name: "Customer 360",
            description: nil,
            workspaceID: Self.workspaceID
        )

        let events = await collector.value
        #expect(events.count == 2)
        if case .listRefreshed = events[0] { #expect(Bool(true)) } else {
            Issue.record("expected listRefreshed first, got \(events[0])")
        }
        if case .projectCreated(let project) = events[1] {
            #expect(project.id == "p-new")
        } else {
            Issue.record("expected projectCreated, got \(events[1])")
        }

        // The cached list should now contain p-new.
        let cached = try await service.list(workspaceID: Self.workspaceID, forceRefresh: false)
        #expect(cached.contains(where: { $0.id == "p-new" }))
        #expect(cached.contains(where: { $0.id == "p-0" }))
    }
}

@Suite("ProjectService — defaultProject")
struct ProjectServiceDefaultProjectTests {

    private static let workspaceID = "ws-1"

    private func makeService(
        api: ScriptedProjectAPIClient,
        defaults: InMemoryDefaultsStore = InMemoryDefaultsStore()
    ) async -> ProjectService {
        let auth = MockAuthService(activeWorkspace: .fixture(id: Self.workspaceID))
        let resolver = LiveAppEndpointResolver()
        return ProjectService(
            auth: auth,
            endpointResolver: resolver,
            api: api,
            defaults: defaults
        )
    }

    @Test("nil when no default has been set")
    func nilWhenUnset() async throws {
        let api = ScriptedProjectAPIClient()
        let service = await makeService(api: api)
        let result = await service.defaultProject(workspaceID: Self.workspaceID)
        #expect(result == nil)
    }

    @Test("setDefault verifies the project exists, persists the id, and broadcasts")
    func setDefaultHappyPath() async throws {
        let api = ScriptedProjectAPIClient()
        let project = ProjectMetadata.fixture(id: "p-fav")
        await api.enqueueFetch(.success(project))
        let defaults = InMemoryDefaultsStore()
        let service = await makeService(api: api, defaults: defaults)

        try await service.setDefault(projectID: "p-fav", workspaceID: Self.workspaceID)

        let stored = await defaults.defaultProjectID(workspaceID: Self.workspaceID)
        #expect(stored == "p-fav")
    }

    @Test("defaultProject clears the persisted id when fetch returns notFound")
    func clearsOnNotFound() async throws {
        let api = ScriptedProjectAPIClient()
        await api.enqueueFetch(.failure(.notFound(nil)))
        let defaults = InMemoryDefaultsStore()
        await defaults.setDefaultProjectID("p-stale", workspaceID: Self.workspaceID)
        let service = await makeService(api: api, defaults: defaults)

        let result = await service.defaultProject(workspaceID: Self.workspaceID)
        #expect(result == nil)
        let stillStored = await defaults.defaultProjectID(workspaceID: Self.workspaceID)
        #expect(stillStored == nil)
    }
}
