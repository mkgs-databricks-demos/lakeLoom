import AuthenticationServices
import Foundation
import SwiftUI

/// Top-level state holder + navigation arbiter.
///
/// This v1 implementation covers the Auth + Projects + Persistence path
/// that's been merged so far: cold-start recovery, onboarding flow,
/// workspace + project switching, sign-out. Capture-related concerns
/// (the `.capturing` phase, `startQuickCapture` / `endQuickCapture`,
/// scene-phase capture handling, ingest/storage service recovery) are
/// deferred until Module 02 (CaptureEngine) lands; protocols + init
/// signature are designed to grow additively.
///
/// See `architecture/LakeLoomMarkdowns/module-05-app-coordinator.md`.
@MainActor
@Observable
public final class AppCoordinator {

    // MARK: Top-level state

    public private(set) var phase: AppPhase = .coldStart
    public private(set) var activeContext: ActiveContext?
    public private(set) var onboarding: OnboardingState?
    public private(set) var rootRoute: RootRoute?
    public private(set) var transitioning: TransitionKind?
    public private(set) var lastError: AppError?

    // MARK: Dependencies

    private let auth: any AuthServicing
    private let projects: any ProjectServicing
    private let coreDataStack: any CoreDataStacking
    private let logger: AppLogger
    private let nowProvider: @Sendable () -> Date

    // MARK: Long-running observation tasks

    private var authEventsTask: Task<Void, Never>?

    // MARK: Init

    public init(
        auth: any AuthServicing,
        projects: any ProjectServicing,
        coreDataStack: any CoreDataStacking,
        logger: AppLogger = AppLogger(category: .coordinator),
        nowProvider: @Sendable @escaping () -> Date = Date.init
    ) {
        self.auth = auth
        self.projects = projects
        self.coreDataStack = coreDataStack
        self.logger = logger
        self.nowProvider = nowProvider
    }

    // MARK: Lifecycle

    /// Bring the coordinator to a usable state. Called once from the
    /// SwiftUI `App`'s `task { ... }` modifier.
    ///
    /// Decision tree:
    /// 1. Initialize Core Data + AuthService (sequential — Auth depends
    ///    on Keychain only, but the order matches Module 05 §5).
    /// 2. If consent not yet acknowledged → onboarding at `.consent`.
    /// 3. If no active workspace → onboarding at `.workspaceURL`.
    /// 4. If active workspace but no default project for it → onboarding
    ///    at `.projectPicker` so the user picks one.
    /// 5. Otherwise → preparingReady → ready with full activeContext.
    public func bootstrap() async {
        guard phase == .coldStart else { return }
        phase = .recovering

        do {
            try await coreDataStack.initialize()
        } catch {
            await logger.error(
                "core data initialize failed",
                metadata: ["reason": .errorCode(String(describing: type(of: error)))]
            )
            phase = .error(.bootstrapFailed(reason: "core data initialize failed"))
            return
        }

        // AuthService loads workspaces + active selection from Keychain.
        // Cast through the concrete type when possible so we hit the
        // start() method directly; otherwise this is a no-op (mocks
        // don't need recovery).
        if let live = auth as? AuthService {
            await live.start()
        }

        // Subscribe to auth events so forced sign-outs (refresh failures)
        // route us back to onboarding even mid-session.
        observeAuthEvents()

        // Decide next phase.
        await routeAfterBootstrap()
    }

    /// Re-evaluate phase after a state change (sign-in, sign-out, etc.).
    /// Visible for tests; AppCoordinator's own actions call it inline.
    public func reroute() async {
        await routeAfterBootstrap()
    }

    // MARK: - Private helpers

    private func routeAfterBootstrap() async {
        guard ConsentVersion.hasAcknowledgedCurrent else {
            await beginOnboarding(at: .consent)
            return
        }

        guard let workspace = await auth.activeWorkspace else {
            await beginOnboarding(at: .workspaceURL(prefill: nil))
            return
        }

        // Have a workspace — try to pick a project (default first, then
        // first available, then prompt).
        let project: ProjectMetadata? = await {
            if let stored = await projects.defaultProject(workspaceID: workspace.id) {
                return stored
            }
            return await projects.firstAvailableProject(workspaceID: workspace.id)
        }()

        guard let project else {
            await beginOnboarding(at: .projectPicker(
                workspace: workspace,
                projects: [],
                loading: true,
                lastError: nil
            ))
            await loadProjectsForOnboarding(workspace: workspace)
            return
        }

        activeContext = ActiveContext(
            user: workspace.user,
            workspace: workspace,
            project: project,
            establishedAt: nowProvider()
        )
        await transitionToReady()
    }

    func transitionToReady() async {
        phase = .preparingReady
        await projects.start()
        rootRoute = .home
        phase = .ready
        await logger.info(
            "coordinator ready",
            metadata: [
                "workspace_id": .uuidPrefix(activeContext?.workspace.id ?? ""),
                "project_id": .uuidPrefix(activeContext?.project.id ?? "")
            ]
        )
    }

    func beginOnboarding(at step: OnboardingState) async {
        onboarding = step
        phase = .onboarding
        activeContext = nil
        rootRoute = nil
    }

    /// Loads the project list for the picker step. Updates the
    /// onboarding state with the result (or the error). Used during
    /// bootstrap and after the user picks "Use a different account"
    /// to re-enter the flow.
    func loadProjectsForOnboarding(workspace: WorkspaceCredential) async {
        do {
            let list = try await projects.list(workspaceID: workspace.id, forceRefresh: false)
            if case .projectPicker = onboarding {
                onboarding = .projectPicker(
                    workspace: workspace,
                    projects: list,
                    loading: false,
                    lastError: nil
                )
            }
        } catch let error as ProjectError {
            if case .projectPicker = onboarding {
                onboarding = .projectPicker(
                    workspace: workspace,
                    projects: [],
                    loading: false,
                    lastError: Self.message(for: error)
                )
            }
            await logger.warning(
                "project list failed during onboarding",
                metadata: ["reason": .errorCode(Self.errorCode(for: error))]
            )
        } catch {
            if case .projectPicker = onboarding {
                onboarding = .projectPicker(
                    workspace: workspace,
                    projects: [],
                    loading: false,
                    lastError: error.localizedDescription
                )
            }
        }
    }

    // MARK: AuthEvent observer

    private func observeAuthEvents() {
        authEventsTask?.cancel()
        let stream = Task<AsyncStream<AuthEvent>, Never> { [auth] in
            await auth.events
        }
        authEventsTask = Task { [weak self] in
            let events = await stream.value
            for await event in events {
                guard let self else { return }
                await self.handleAuthEvent(event)
            }
        }
    }

    private func handleAuthEvent(_ event: AuthEvent) async {
        switch event {
        case .signedOut(let workspaceID):
            // If this happened spontaneously (refresh-token revoked
            // server-side) and no transition was in progress, treat
            // it as a forced sign-out and route back to onboarding.
            if activeContext?.workspace.id == workspaceID,
               transitioning == nil {
                await handleForcedSignOut(workspaceID: workspaceID)
            }
        case .signedIn, .switchedWorkspace, .identityRefreshed:
            // These fire as part of actions we drove ourselves — the
            // action handler already updated state.
            break
        }
    }

    private func handleForcedSignOut(workspaceID: String) async {
        activeContext = nil
        if await auth.activeWorkspace != nil {
            await reroute()
        } else {
            await beginOnboarding(at: .consent)
        }
        lastError = .authError(.refreshFailed(reason: "Sign in again required"))
    }

    // MARK: Error rendering

    static func message(for error: ProjectError) -> String {
        switch error {
        case .notSignedIn: return "You're not signed in."
        case .workspaceMismatch: return "Workspace mismatch."
        case .validationFailed(let reason): return reason
        case .duplicateName: return "A project with that name already exists in this workspace."
        case .notFound: return "Project not found."
        case .permissionDenied(let reason): return "Permission denied: \(reason)"
        case .authFailed(let reason): return "Sign in again required: \(reason)"
        case .rejectedByServer(let status, let reason): return "Server rejected request (\(status)): \(reason)"
        case .serverUnavailable(let reason): return "Server unavailable: \(reason)"
        case .rateLimited: return "Too many requests — try again in a moment."
        case .networkUnavailable: return "No network connection."
        case .timeout: return "Request timed out."
        case .unknown(let reason): return reason
        }
    }

    static func errorCode(for error: ProjectError) -> String {
        switch error {
        case .notSignedIn: return "not_signed_in"
        case .workspaceMismatch: return "workspace_mismatch"
        case .validationFailed: return "validation_failed"
        case .duplicateName: return "duplicate_name"
        case .notFound: return "not_found"
        case .permissionDenied: return "permission_denied"
        case .authFailed: return "auth_failed"
        case .rejectedByServer: return "rejected_by_server"
        case .serverUnavailable: return "server_unavailable"
        case .rateLimited: return "rate_limited"
        case .networkUnavailable: return "network_unavailable"
        case .timeout: return "timeout"
        case .unknown: return "unknown"
        }
    }
}
