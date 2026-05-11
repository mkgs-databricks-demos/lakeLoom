import Foundation

/// Top-level tab the user is currently on. Module 05 stays minimal
/// at v1: home / sessions / settings. The full set of tab
/// destinations and their navigation stacks lives in Module 08.
public enum RootRoute: Sendable, Equatable {
    case home
    case sessions
    case settings
}
