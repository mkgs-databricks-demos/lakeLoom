import SwiftUI

/// Dispatches to the right onboarding step view based on
/// `coordinator.onboarding`. RootView only forwards to this when
/// `phase == .onboarding`.
struct OnboardingFlowView: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        Group {
            switch coordinator.onboarding {
            case .consent:
                ConsentStepView(
                    onContinue: { Task { await coordinator.acknowledgeConsent() } }
                )
            case .workspaceURL(let prefill):
                WorkspaceURLStepView(
                    prefill: prefill,
                    onSubmit: { input in
                        Task { await coordinator.submitWorkspaceURL(input) }
                    }
                )
            case .oauthLogin(let url, let inProgress, let lastError):
                OAuthLoginStepView(
                    workspaceURL: url,
                    inProgress: inProgress,
                    lastError: lastError,
                    coordinator: coordinator
                )
            case .identityConfirmation(let credential):
                IdentityConfirmationStepView(
                    credential: credential,
                    onContinue: { Task { await coordinator.confirmIdentity() } },
                    onUseDifferent: { Task { await coordinator.useDifferentAccount() } }
                )
            case .projectPicker(let workspace, let projects, let loading, let lastError):
                ProjectPickerStepView(
                    workspace: workspace,
                    projects: projects,
                    loading: loading,
                    lastError: lastError,
                    onSelect: { id in Task { await coordinator.selectProject(id) } },
                    onCreateNew: { Task { await coordinator.goToCreateProject() } },
                    onReload: { Task { await coordinator.reloadProjectPicker() } }
                )
            case .projectCreate(let workspace, let inProgress, let lastError):
                ProjectCreateStepView(
                    workspace: workspace,
                    inProgress: inProgress,
                    lastError: lastError,
                    onCreate: { name, description in
                        Task { await coordinator.createProject(name: name, description: description) }
                    },
                    onCancel: { Task { await coordinator.cancelCreateProject() } }
                )
            case .finalizingOnboarding:
                SplashView()
            case .none:
                SplashView()
            }
        }
        .animation(.default, value: coordinator.onboarding)
    }
}
