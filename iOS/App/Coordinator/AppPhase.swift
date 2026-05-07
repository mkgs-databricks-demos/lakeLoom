import Foundation

/// Top-level app phase driven by ``AppCoordinator``. Views switch on
/// this to decide what to render. Module 05 §4 documents the full
/// state machine and invariants.
///
/// `.capturing` is intentionally absent from this v1 build — it
/// arrives with Module 02 (CaptureEngine) when active-session
/// state has a real `SessionHandle` to carry.
public enum AppPhase: Sendable, Equatable {
    /// Before ``AppCoordinator/bootstrap()`` runs. Splash visible.
    case coldStart

    /// Recovery passes are running (load workspaces from Keychain,
    /// initialize Core Data). Splash visible.
    case recovering

    /// No active workspace + project context yet — onboarding
    /// flow is presented. ``AppCoordinator/onboarding`` carries
    /// the current step.
    case onboarding

    /// Bootstrap complete; services starting up before the home
    /// screen is allowed to render. Splash → ready cross-fade.
    case preparingReady

    /// Steady state. Home / Sessions / Settings tabs are live.
    case ready

    /// Scene-phase backgrounded. View tree stable but invisible.
    case backgrounded

    /// Unrecoverable error. User needs to act (typically "Reset
    /// local data"). Carries the underlying ``AppError``.
    case error(AppError)
}
