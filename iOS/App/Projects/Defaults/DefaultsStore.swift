import Foundation

/// Per-workspace user-default storage for the user's preferred project.
///
/// Module 06 §11 keeps the default project ID device-local — moving it
/// server-side requires another endpoint and isn't worth the schema
/// cost in v1. Production uses ``LiveDefaultsStore`` over `UserDefaults`;
/// tests use ``InMemoryDefaultsStore``.
public protocol DefaultsStore: Sendable {
    func defaultProjectID(workspaceID: String) async -> String?
    func setDefaultProjectID(_ projectID: String, workspaceID: String) async
    func clearDefault(workspaceID: String) async
}
