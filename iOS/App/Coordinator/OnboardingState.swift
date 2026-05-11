import Foundation

/// One step of the onboarding state machine. The view layer renders
/// the matching screen; user actions transition to the next state via
/// methods on ``AppCoordinator``.
///
/// The microphone pre-prompt step is deferred until Module 02
/// (CaptureEngine) lands — it doesn't make sense to pre-prompt for
/// permissions for a feature that doesn't exist yet.
public enum OnboardingState: Sendable, Equatable {
    /// Welcome / consent screen. Tap "I understand" to advance.
    case consent

    /// Workspace URL entry. `prefill` carries the raw text the user
    /// last typed if they navigated back here from `oauthLogin`.
    case workspaceURL(prefill: String?)

    /// OAuth login is presented via `ASWebAuthenticationSession`.
    /// `inProgress` reflects whether the system browser is currently
    /// open. `lastError` is set when a previous attempt failed.
    case oauthLogin(workspaceURL: URL, inProgress: Bool, lastError: String?)

    /// "Logged in as ..." confirmation step. User confirms before
    /// advancing to project selection. Optional back affordance
    /// signs the workspace out and returns to `workspaceURL`.
    case identityConfirmation(WorkspaceCredential)

    /// Project picker. `loading` reflects an in-flight list call;
    /// `lastError` carries the most recent fetch failure (if any)
    /// so the view can surface a "retry" affordance.
    case projectPicker(
        workspace: WorkspaceCredential,
        projects: [ProjectMetadata],
        loading: Bool,
        lastError: String?
    )

    /// New-project creation modal. Reachable from `projectPicker` via
    /// the "+ New Project" affordance.
    case projectCreate(
        workspace: WorkspaceCredential,
        inProgress: Bool,
        lastError: String?
    )

    /// Brief spinner state between project selection / creation and
    /// landing on the home screen. Usually <500ms.
    case finalizingOnboarding
}
