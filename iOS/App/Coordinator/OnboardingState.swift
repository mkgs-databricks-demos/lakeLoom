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

    /// QR scanner. iOS reads the QR rendered by the lakeLoom Databricks
    /// App's "Pair iPhone" page. `inProgress` reflects whether a scan
    /// is currently being processed (App round-trip). `lastError` is
    /// the most recent failure (decode failure, network failure, App
    /// rejection) — shown above the camera preview with a retry CTA.
    case qrScan(inProgress: Bool, lastError: String?)

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
