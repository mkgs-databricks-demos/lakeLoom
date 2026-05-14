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
