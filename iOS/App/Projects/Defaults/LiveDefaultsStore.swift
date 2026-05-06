import Foundation

/// `UserDefaults`-backed default-project store. Keys are
/// `project.default.<workspaceID>` so multiple workspaces don't
/// collide. `UserDefaults` is thread-safe per Apple's documentation
/// but its type is non-Sendable in Swift 6 strict concurrency; an
/// actor wrapper satisfies the protocol without resorting to
/// `@unchecked Sendable`.
public actor LiveDefaultsStore: DefaultsStore {

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func defaultProjectID(workspaceID: String) async -> String? {
        userDefaults.string(forKey: Self.key(workspaceID: workspaceID))
    }

    public func setDefaultProjectID(_ projectID: String, workspaceID: String) async {
        userDefaults.set(projectID, forKey: Self.key(workspaceID: workspaceID))
    }

    public func clearDefault(workspaceID: String) async {
        userDefaults.removeObject(forKey: Self.key(workspaceID: workspaceID))
    }

    private static func key(workspaceID: String) -> String {
        "project.default.\(workspaceID)"
    }
}
