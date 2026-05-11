import Foundation

/// Errors surfaced through ``AppCoordinator``. Most cases wrap a
/// lower-layer error so views can present a useful message; some
/// (the `*BlockedByActiveCapture` cases) are deferred until Module 02
/// lands.
public enum AppError: Error, Sendable, Equatable {
    case bootstrapFailed(reason: String)
    case authError(AuthError)
    case projectFetchFailed(reason: String)
    case projectCreateFailed(reason: String)
    case workspaceSwitchBlockedByActiveCapture
    case projectSwitchBlockedByActiveCapture
    case signOutBlockedByActiveCapture
    case unknown(reason: String)
}
