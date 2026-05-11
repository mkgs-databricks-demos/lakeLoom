import Foundation

/// Identifies an in-progress transition that the UI should reflect
/// (typically a spinner + disabled button until the transition
/// completes). Set by ``AppCoordinator/transitioning`` for the
/// duration of the work.
public enum TransitionKind: Sendable, Equatable {
    case signingIn
    case signingOut(workspaceID: String)
    case switchingWorkspace(toID: String)
    case switchingProject(toID: String)
}
