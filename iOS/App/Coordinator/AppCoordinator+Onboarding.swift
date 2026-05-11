import AuthenticationServices
import Foundation

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
        onboarding = .workspaceURL(prefill: nil)
    }

    // MARK: Step 2 — workspace URL

    public func submitWorkspaceURL(_ urlString: String) async {
        guard case .onboarding = phase, case .workspaceURL = onboarding else { return }
        let normalized = WorkspaceURLNormalizer.normalize(urlString)
        do {
            try await auth.validateWorkspaceURL(normalized)
            onboarding = .oauthLogin(workspaceURL: normalized, inProgress: false, lastError: nil)
        } catch let error as AuthError {
            onboarding = .workspaceURL(prefill: urlString)
            lastError = .authError(error)
        } catch {
            onboarding = .workspaceURL(prefill: urlString)
            lastError = .unknown(reason: error.localizedDescription)
        }
    }

    // MARK: Step 3 — OAuth

    @MainActor
    public func startOAuthSignIn(presenting: ASWebAuthenticationPresentationContextProviding) async {
        guard case .onboarding = phase,
              case .oauthLogin(let url, _, _) = onboarding else { return }
        onboarding = .oauthLogin(workspaceURL: url, inProgress: true, lastError: nil)
        transitioning = .signingIn
        defer { transitioning = nil }

        do {
            let credential = try await auth.signIn(workspaceURL: url, presenting: presenting)
            onboarding = .identityConfirmation(credential)
        } catch AuthError.userCancelled {
            onboarding = .oauthLogin(workspaceURL: url, inProgress: false, lastError: nil)
        } catch let error as AuthError {
            onboarding = .oauthLogin(
                workspaceURL: url,
                inProgress: false,
                lastError: error.localizedDescription
            )
        } catch {
            onboarding = .oauthLogin(
                workspaceURL: url,
                inProgress: false,
                lastError: error.localizedDescription
            )
        }
    }

    // MARK: Step 4 — identity confirmation

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
        // Sign out and return to the workspace URL step. We keep the
        // host pre-filled so the user doesn't have to retype it.
        try? await auth.signOut(workspaceID: credential.id)
        onboarding = .workspaceURL(prefill: credential.workspaceURL.host)
    }

    // MARK: Step 5 — project picker

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

    // MARK: Step 6 — project create

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

    // MARK: Step 7 — finalize

    private func finalizeOnboarding(
        workspace: WorkspaceCredential,
        project: ProjectMetadata
    ) async {
        // Persist the chosen project as the workspace's default for
        // next launch, then build the active context.
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
            // Already at the start; no-op.
            break
        case .workspaceURL:
            // No further back from here.
            break
        case .oauthLogin(let url, _, _):
            onboarding = .workspaceURL(prefill: url.host)
        case .identityConfirmation(let credential):
            try? await auth.signOut(workspaceID: credential.id)
            onboarding = .workspaceURL(prefill: credential.workspaceURL.host)
        case .projectPicker(let workspace, _, _, _):
            // Going back from the picker signs out and returns to the
            // workspace URL step. UI should warn before triggering.
            try? await auth.signOut(workspaceID: workspace.id)
            onboarding = .workspaceURL(prefill: workspace.workspaceURL.host)
        case .projectCreate(let workspace, _, _):
            onboarding = .projectPicker(
                workspace: workspace,
                projects: [],
                loading: true,
                lastError: nil
            )
            await loadProjectsForOnboarding(workspace: workspace)
        case .finalizingOnboarding:
            // Final step has no back; ignore.
            break
        }
    }
}

// MARK: - Workspace URL normalization

/// Cleans up a workspace URL the user typed: prepends `https://`,
/// strips path / query / fragment, lowercases the host. Intentionally
/// permissive — anything that parses to a host gets through; the OIDC
/// discovery probe is the actual gate.
enum WorkspaceURLNormalizer {
    static func normalize(_ raw: String) -> URL {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "https://\(trimmed)"
        }
        guard let parsed = URL(string: trimmed),
              let host = parsed.host,
              !host.isEmpty
        else {
            // Return a structurally-correct URL with the raw host;
            // AuthService.validateWorkspaceURL will reject it cleanly.
            return URL(string: "https://invalid.invalid") ?? URL(fileURLWithPath: "/")
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host.lowercased()
        return components.url ?? parsed
    }
}
