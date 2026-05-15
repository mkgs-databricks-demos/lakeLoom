import Foundation
import Testing

@testable import LakeloomApp

@Suite("AppCoordinator — bootstrap routing")
@MainActor
struct AppCoordinatorBootstrapTests {

    private func makeStack() async throws -> CoreDataStack {
        let stack = try CoreDataStack.makeInMemory()
        try await stack.initialize()
        return stack
    }

    @Test("no consent acknowledged → onboarding(.consent)")
    func noConsentRoutesToConsent() async throws {
        ConsentVersion.clearForTesting()
        let auth = MockAuthService()
        let api = ScriptedProjectAPIClient()
        let projects = ProjectService(
            auth: auth,
            endpointResolver: LiveAppEndpointResolver(),
            api: api,
            defaults: InMemoryDefaultsStore()
        )
        let stack = try await makeStack()
        let coordinator = AppCoordinator(auth: auth, projects: projects, coreDataStack: stack, endpointResolver: LiveAppEndpointResolver())

        await coordinator.bootstrap()

        #expect(coordinator.phase == .onboarding)
        if case .consent = coordinator.onboarding {
            #expect(Bool(true))
        } else {
            Issue.record("expected .consent, got \(String(describing: coordinator.onboarding))")
        }
    }

    @Test("consent acknowledged + no active workspace → onboarding(.qrScan)")
    func consentButNoWorkspaceRoutesToQRScan() async throws {
        ConsentVersion.recordAcknowledgement()
        defer { ConsentVersion.clearForTesting() }

        let auth = MockAuthService()
        let api = ScriptedProjectAPIClient()
        let projects = ProjectService(
            auth: auth,
            endpointResolver: LiveAppEndpointResolver(),
            api: api,
            defaults: InMemoryDefaultsStore()
        )
        let stack = try await makeStack()
        let coordinator = AppCoordinator(auth: auth, projects: projects, coreDataStack: stack, endpointResolver: LiveAppEndpointResolver())

        await coordinator.bootstrap()

        #expect(coordinator.phase == .onboarding)
        if case .qrScan = coordinator.onboarding {
            #expect(Bool(true))
        } else {
            Issue.record("expected .qrScan, got \(String(describing: coordinator.onboarding))")
        }
    }

    @Test("consent + active workspace + first-available project → ready")
    func fullContextRoutesToReady() async throws {
        ConsentVersion.recordAcknowledgement()
        defer { ConsentVersion.clearForTesting() }

        let workspace = WorkspaceCredential.fixture(id: "ws-1")
        let auth = MockAuthService(activeWorkspace: workspace)
        let api = ScriptedProjectAPIClient()
        let project = ProjectMetadata.fixture(id: "p-1", workspaceID: "ws-1")
        await api.enqueueList(.success(ProjectListResponse(projects: [project], hasMore: false)))
        let projects = ProjectService(
            auth: auth,
            endpointResolver: LiveAppEndpointResolver(),
            api: api,
            defaults: InMemoryDefaultsStore()
        )
        let stack = try await makeStack()
        let coordinator = AppCoordinator(auth: auth, projects: projects, coreDataStack: stack, endpointResolver: LiveAppEndpointResolver())

        await coordinator.bootstrap()

        #expect(coordinator.phase == .ready)
        #expect(coordinator.activeContext?.workspace.id == "ws-1")
        #expect(coordinator.activeContext?.project.id == "p-1")
    }

    @Test("workspace but no projects → onboarding(.projectPicker) with the (empty) list loaded")
    func workspaceButNoProjectsRoutesToPicker() async throws {
        ConsentVersion.recordAcknowledgement()
        defer { ConsentVersion.clearForTesting() }

        let workspace = WorkspaceCredential.fixture(id: "ws-1")
        let auth = MockAuthService(activeWorkspace: workspace)
        let api = ScriptedProjectAPIClient()
        // firstAvailableProject() calls list() internally — give it an
        // empty response. Then onboarding bootstrap triggers
        // loadProjectsForOnboarding which calls list() again. Two empty
        // outcomes cover both paths.
        await api.enqueueList(.success(ProjectListResponse(projects: [], hasMore: false)))
        await api.enqueueList(.success(ProjectListResponse(projects: [], hasMore: false)))
        let projects = ProjectService(
            auth: auth,
            endpointResolver: LiveAppEndpointResolver(),
            api: api,
            defaults: InMemoryDefaultsStore()
        )
        let stack = try await makeStack()
        let coordinator = AppCoordinator(auth: auth, projects: projects, coreDataStack: stack, endpointResolver: LiveAppEndpointResolver())

        await coordinator.bootstrap()

        #expect(coordinator.phase == .onboarding)
        if case .projectPicker(let ws, let list, let loading, _) = coordinator.onboarding {
            #expect(ws.id == "ws-1")
            #expect(list.isEmpty)
            #expect(loading == false)
        } else {
            Issue.record("expected .projectPicker, got \(String(describing: coordinator.onboarding))")
        }
    }

    @Test("bootstrap is idempotent — second call is a no-op")
    func bootstrapIsIdempotent() async throws {
        ConsentVersion.clearForTesting()

        let auth = MockAuthService()
        let api = ScriptedProjectAPIClient()
        let projects = ProjectService(
            auth: auth,
            endpointResolver: LiveAppEndpointResolver(),
            api: api,
            defaults: InMemoryDefaultsStore()
        )
        let stack = try await makeStack()
        let coordinator = AppCoordinator(auth: auth, projects: projects, coreDataStack: stack, endpointResolver: LiveAppEndpointResolver())

        await coordinator.bootstrap()
        let phaseAfterFirst = coordinator.phase
        await coordinator.bootstrap()
        let phaseAfterSecond = coordinator.phase
        #expect(phaseAfterFirst == phaseAfterSecond)
    }
}

@Suite("AppCoordinator — onboarding state machine")
@MainActor
struct AppCoordinatorOnboardingTests {

    private func makeStack() async throws -> CoreDataStack {
        let stack = try CoreDataStack.makeInMemory()
        try await stack.initialize()
        return stack
    }

    @Test("acknowledgeConsent transitions consent → qrScan")
    func acknowledgeConsentAdvances() async throws {
        ConsentVersion.clearForTesting()
        defer { ConsentVersion.clearForTesting() }

        let auth = MockAuthService()
        let api = ScriptedProjectAPIClient()
        let projects = ProjectService(
            auth: auth,
            endpointResolver: LiveAppEndpointResolver(),
            api: api,
            defaults: InMemoryDefaultsStore()
        )
        let stack = try await makeStack()
        let coordinator = AppCoordinator(auth: auth, projects: projects, coreDataStack: stack, endpointResolver: LiveAppEndpointResolver())

        await coordinator.bootstrap()
        await coordinator.acknowledgeConsent()

        if case .qrScan = coordinator.onboarding {
            #expect(Bool(true))
            #expect(ConsentVersion.hasAcknowledgedCurrent)
        } else {
            Issue.record("expected .qrScan after acknowledge")
        }
    }
}

@Suite("AppCoordinator — error rendering")
@MainActor
struct AppCoordinatorErrorRenderingTests {

    @Test("ProjectError → human message")
    func projectErrorMessages() {
        #expect(AppCoordinator.message(for: .duplicateName(existingProjectID: "p-1"))
                .contains("already exists"))
        #expect(AppCoordinator.message(for: ProjectError.networkUnavailable)
                .contains("network"))
        #expect(AppCoordinator.message(for: ProjectError.timeout) == "Request timed out.")
        #expect(AppCoordinator.message(for: ProjectError.validationFailed(reason: "name empty"))
                == "name empty")
    }

    @Test("ProjectError → stable error code")
    func projectErrorCodes() {
        #expect(AppCoordinator.errorCode(for: .duplicateName(existingProjectID: "p")) == "duplicate_name")
        #expect(AppCoordinator.errorCode(for: .networkUnavailable) == "network_unavailable")
        #expect(AppCoordinator.errorCode(for: .timeout) == "timeout")
    }
}

// MARK: - Test helper

extension ConsentVersion {
    /// Clears UserDefaults entries for tests so each test starts with
    /// a clean slate.
    static func clearForTesting() {
        UserDefaults.standard.removeObject(forKey: "consent.acknowledged.version")
        UserDefaults.standard.removeObject(forKey: "consent.acknowledged.at")
    }
}
