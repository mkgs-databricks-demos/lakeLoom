import Foundation
import UIKit

/// Onboarding-flow methods for ``AppCoordinator``. Each method maps to
/// a user action in one specific ``OnboardingState``; invalid actions
/// from other states are silently ignored (defense in depth — the UI
/// shouldn't surface them in the wrong state, but a stale tap during
/// a transition shouldn't crash).
extension AppCoordinator {

    // MARK: Step 1 — consent

    public func acknowledgeConsent() async {
        guard case .onboarding = phase, case .consent = onboarding else { return }
        ConsentVersion.recordAcknowledgement(at: Date())
        onboarding = .qrScan(inProgress: false, lastError: nil)
    }

    // MARK: Step 2 — QR scan + pair

    /// Called by ``QRScanStepView`` when AVFoundation decodes a QR
    /// string from the camera. Drives the entire sign-in via
    /// ``AuthServicing/signInViaPairing(qrText:deviceLabel:)``.
    public func submitQRCode(_ qrText: String) async {
        guard case .onboarding = phase, case .qrScan(let inProgress, _) = onboarding else { return }
        // Debounce — if a sign-in is already in flight from a previous
        // scan, ignore further scans until the App responds.
        guard !inProgress else { return }
        onboarding = .qrScan(inProgress: true, lastError: nil)
        transitioning = .signingIn
        defer { transitioning = nil }

        let deviceLabel = await Self.currentDeviceLabel()
        do {
            let credential = try await auth.signInViaPairing(
                qrText: qrText,
                deviceLabel: deviceLabel
            )
            // Seed the endpoint resolver with the freshly-paired App URL
            // so ProjectService's subsequent calls route correctly.
            await endpointResolver.seed(
                workspaceID: credential.id,
                appBaseURL: credential.appBaseURL
            )
            onboarding = .identityConfirmation(credential)
        } catch let error as AuthError {
            onboarding = .qrScan(inProgress: false, lastError: Self.message(for: error))
        } catch {
            onboarding = .qrScan(inProgress: false, lastError: error.localizedDescription)
        }
    }

    /// Returns the user's device name (e.g. "Matthew's iPhone"),
    /// hopping to the main actor since `UIDevice.current.name` is
    /// `@MainActor` in Swift 6.
    @MainActor
    private static func currentDeviceLabel() async -> String {
        UIDevice.current.name
    }

    // MARK: Step 3 — identity confirmation

    public func confirmIdentity() async {
        guard case .onboarding = phase,
              case .identityConfirmation(let credential) = onboarding else { return }
        // Move to the project picker and start the list fetch.
        onboarding = .projectPicker(
            workspace: credential,
            projects: [],
            loading: true,
            lastError: nil
        )
        await loadProjectsForOnboarding(workspace: credential)
    }

    public func useDifferentAccount() async {
        guard case .onboarding = phase,
              case .identityConfirmation(let credential) = onboarding else { return }
        // Sign out and return to the QR scan step.
        try? await auth.signOut(workspaceID: credential.id)
        onboarding = .qrScan(inProgress: false, lastError: nil)
    }

    // MARK: Step 4 — project picker

    public func selectProject(_ projectID: String) async {
        guard case .onboarding = phase,
              case .projectPicker(let workspace, let projects, _, _) = onboarding else { return }
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        onboarding = .finalizingOnboarding
        await finalizeOnboarding(workspace: workspace, project: project)
    }

    public func goToCreateProject() async {
        guard case .onboarding = phase,
              case .projectPicker(let workspace, _, _, _) = onboarding else { return }
        onboarding = .projectCreate(workspace: workspace, inProgress: false, lastError: nil)
    }

    public func reloadProjectPicker() async {
        guard case .onboarding = phase,
              case .projectPicker(let workspace, let existing, _, _) = onboarding else { return }
        onboarding = .projectPicker(
            workspace: workspace,
            projects: existing,
            loading: true,
            lastError: nil
        )
        await loadProjectsForOnboarding(workspace: workspace)
    }

    // MARK: Post-onboarding project switching

    /// Switch the active project to a different one in the same
    /// workspace without re-pairing. Fetches fresh metadata for the
    /// target project (so a switch picks up server-side renames),
    /// persists it as the workspace's new default, and replaces
    /// ``activeContext`` so the home view and downstream services
    /// pick up the change on the next render tick.
    ///
    /// Silently no-ops if there's no active context. Logs + returns
    /// on fetch failure so a transient network blip doesn't tear the
    /// existing context down.
    public func switchActiveProject(to projectID: String) async {
        guard let context = activeContext else { return }
        if context.project.id == projectID { return }
        let workspaceID = context.workspace.id

        let resolved: ProjectMetadata
        do {
            resolved = try await projects.fetch(
                projectID: projectID,
                workspaceID: workspaceID
            )
        } catch {
            await logger.warning(
                "switchActiveProject: fetch failed",
                metadata: [
                    "project_id": .uuidPrefix(projectID),
                    "reason": .string(String(describing: error))
                ]
            )
            return
        }

        // Best-effort persistence — failure here doesn't roll back
        // the in-memory switch (the user explicitly asked for it).
        // Next cold launch will fall through to firstAvailableProject
        // if setDefault didn't stick, which is recoverable.
        try? await projects.setDefault(
            projectID: resolved.id,
            workspaceID: workspaceID
        )

        activeContext = ActiveContext(
            user: context.user,
            workspace: context.workspace,
            project: resolved,
            establishedAt: nowProvider()
        )

        await logger.info(
            "project switched",
            metadata: [
                "workspace_id": .uuidPrefix(workspaceID),
                "project_id": .uuidPrefix(resolved.id)
            ]
        )
    }

    /// Create a new project in the active workspace and switch the
    /// active context to it in one round trip. The post-onboarding
    /// analog of ``createProject(name:description:)`` — bypasses the
    /// onboarding state machine because the user already has an
    /// active context; we're just adding a project to it and
    /// activating it.
    ///
    /// Returns the created project's name on success so the caller
    /// (the project switcher sheet) can show a brief confirmation
    /// before dismissing. Throws ``ProjectError`` on failure so the
    /// caller can render the typed error inline.
    @discardableResult
    public func createAndSwitchToProject(
        name: String,
        description: String?
    ) async throws -> ProjectMetadata {
        guard let context = activeContext else {
            throw ProjectError.notSignedIn
        }
        let workspace = context.workspace
        let project = try await projects.create(
            name: name,
            description: description,
            workspaceID: workspace.id
        )
        // Persist as the new default — failure is non-fatal (the
        // user explicitly chose this project, in-memory swap stands).
        try? await projects.setDefault(
            projectID: project.id,
            workspaceID: workspace.id
        )
        activeContext = ActiveContext(
            user: context.user,
            workspace: workspace,
            project: project,
            establishedAt: nowProvider()
        )
        await logger.info(
            "project created + switched",
            metadata: [
                "workspace_id": .uuidPrefix(workspace.id),
                "project_id": .uuidPrefix(project.id)
            ]
        )
        return project
    }

    // MARK: Step 5 — project create

    public func createProject(name: String, description: String?) async {
        guard case .onboarding = phase,
              case .projectCreate(let workspace, _, _) = onboarding else { return }
        onboarding = .projectCreate(workspace: workspace, inProgress: true, lastError: nil)

        do {
            let project = try await projects.create(
                name: name,
                description: description,
                workspaceID: workspace.id
            )
            onboarding = .finalizingOnboarding
            await finalizeOnboarding(workspace: workspace, project: project)
        } catch let error as ProjectError {
            onboarding = .projectCreate(
                workspace: workspace,
                inProgress: false,
                lastError: Self.message(for: error)
            )
        } catch {
            onboarding = .projectCreate(
                workspace: workspace,
                inProgress: false,
                lastError: error.localizedDescription
            )
        }
    }

    public func cancelCreateProject() async {
        guard case .onboarding = phase,
              case .projectCreate(let workspace, _, _) = onboarding else { return }
        onboarding = .projectPicker(
            workspace: workspace,
            projects: [],
            loading: true,
            lastError: nil
        )
        await loadProjectsForOnboarding(workspace: workspace)
    }

    // MARK: Step 6 — finalize

    private func finalizeOnboarding(
        workspace: WorkspaceCredential,
        project: ProjectMetadata
    ) async {
        do {
            try await projects.setDefault(projectID: project.id, workspaceID: workspace.id)
        } catch {
            await logger.warning(
                "setDefault failed; continuing",
                metadata: ["reason": .errorCode(String(describing: type(of: error)))]
            )
        }
        activeContext = ActiveContext(
            user: workspace.user,
            workspace: workspace,
            project: project,
            establishedAt: Date()
        )
        await transitionToReady()
        onboarding = nil
    }

    // MARK: Backward navigation

    public func goBackInOnboarding() async {
        guard case .onboarding = phase, let current = onboarding else { return }
        switch current {
        case .consent:
            break
        case .qrScan:
            // No further back from the scanner; bouncing back to consent
            // would lose the ack timestamp which is recorded forever.
            break
        case .identityConfirmation(let credential):
            try? await auth.signOut(workspaceID: credential.id)
            onboarding = .qrScan(inProgress: false, lastError: nil)
        case .projectPicker(let workspace, _, _, _):
            // Going back from the picker signs out and returns to QR scan.
            // UI should warn before triggering.
            try? await auth.signOut(workspaceID: workspace.id)
            onboarding = .qrScan(inProgress: false, lastError: nil)
        case .projectCreate(let workspace, _, _):
            onboarding = .projectPicker(
                workspace: workspace,
                projects: [],
                loading: true,
                lastError: nil
            )
            await loadProjectsForOnboarding(workspace: workspace)
        case .finalizingOnboarding:
            break
        }
    }
}
