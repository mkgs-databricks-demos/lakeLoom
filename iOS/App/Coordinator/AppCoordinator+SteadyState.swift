import Foundation

/// Steady-state user actions on ``AppCoordinator``: switching
/// workspace, switching project, signing out.
///
/// Capture-blocked guards (Module 05 §7.1, §7.2, §7.3) are designed
/// in but currently no-op stubs — the active-capture-session check
/// requires Module 02 (CaptureEngine). Once Module 02 lands, the
/// guards become real and ``AppError/workspaceSwitchBlockedByActiveCapture``
/// etc. start being thrown.
extension AppCoordinator {

    // MARK: Switch workspace

    public func switchWorkspace(to workspaceID: String) async throws {
        // TODO(Module 02): block on activeCaptureSession != nil.
        transitioning = .switchingWorkspace(toID: workspaceID)
        defer { transitioning = nil }

        try await auth.switchWorkspace(to: workspaceID)
        guard let workspace = await auth.activeWorkspace else {
            throw AppError.unknown(reason: "active workspace nil after switch")
        }

        // Pick the project for the new workspace: default first, then
        // first available, then route to onboarding's picker.
        let project: ProjectMetadata? = await {
            if let stored = await projects.defaultProject(workspaceID: workspace.id) {
                return stored
            }
            return await projects.firstAvailableProject(workspaceID: workspace.id)
        }()

        if let project {
            activeContext = ActiveContext(
                user: workspace.user,
                workspace: workspace,
                project: project,
                establishedAt: nowProvider()
            )
        } else {
            await beginOnboarding(at: .projectPicker(
                workspace: workspace,
                projects: [],
                loading: true,
                lastError: nil
            ))
            await loadProjectsForOnboarding(workspace: workspace)
        }
    }

    // MARK: Switch project

    public func switchProject(to projectID: String) async throws {
        // TODO(Module 02): block on activeCaptureSession != nil.
        guard let context = activeContext else {
            throw AppError.unknown(reason: "no active context")
        }
        transitioning = .switchingProject(toID: projectID)
        defer { transitioning = nil }

        let project = try await projects.fetch(
            projectID: projectID,
            workspaceID: context.workspace.id
        )
        try await projects.setDefault(projectID: projectID, workspaceID: context.workspace.id)
        activeContext = ActiveContext(
            user: context.user,
            workspace: context.workspace,
            project: project,
            establishedAt: nowProvider()
        )
    }

    // MARK: Sign out

    public func signOut(workspaceID: String) async throws {
        // TODO(Module 02): block on activeCaptureSession != nil
        // for the workspace being signed out.
        transitioning = .signingOut(workspaceID: workspaceID)
        defer { transitioning = nil }

        // TODO(Module 03/04): cooperative drain of IngestService and
        // StorageService for the workspace being signed out.

        try await auth.signOut(workspaceID: workspaceID)

        // Decide next state.
        if let next = await auth.activeWorkspace {
            // Promote the next workspace.
            let project: ProjectMetadata? = await {
                if let stored = await projects.defaultProject(workspaceID: next.id) {
                    return stored
                }
                return await projects.firstAvailableProject(workspaceID: next.id)
            }()
            if let project {
                activeContext = ActiveContext(
                    user: next.user,
                    workspace: next,
                    project: project,
                    establishedAt: nowProvider()
                )
            } else {
                await beginOnboarding(at: .projectPicker(
                    workspace: next,
                    projects: [],
                    loading: true,
                    lastError: nil
                ))
                await loadProjectsForOnboarding(workspace: next)
            }
        } else {
            activeContext = nil
            await beginOnboarding(at: .consent)
        }
    }

    public func signOutAll() async throws {
        // TODO(Module 02): block on activeCaptureSession != nil.
        let ids = await auth.workspaces.map(\.id)
        for id in ids {
            try await auth.signOut(workspaceID: id)
        }
        try await auth.signOutAll()
        activeContext = nil
        await beginOnboarding(at: .consent)
    }

    // MARK: One-shot error read

    /// Returns and clears ``lastError``. Views can call this in
    /// response to dismissing an error banner so the same error
    /// doesn't keep re-showing.
    public func consumeError() -> AppError? {
        let value = lastError
        lastError = nil
        return value
    }
}
