import Foundation

/// Test-friendly ``DefaultsStore`` backed by a single actor-protected
/// dictionary. Available in the production target so SwiftUI previews
/// can use it without polluting `UserDefaults.standard`.
public actor InMemoryDefaultsStore: DefaultsStore {

    private var defaults: [String: String] = [:]

    public init() {}

    public func defaultProjectID(workspaceID: String) async -> String? {
        defaults[workspaceID]
    }

    public func setDefaultProjectID(_ projectID: String, workspaceID: String) async {
        defaults[workspaceID] = projectID
    }

    public func clearDefault(workspaceID: String) async {
        defaults.removeValue(forKey: workspaceID)
    }

    /// Test introspection — current entry count.
    public var entryCount: Int { defaults.count }
}
