import Foundation

/// In-memory implementation of ``KeychainStore`` for unit tests.
///
/// Stores everything in a single actor-protected dictionary so tests can
/// run in parallel without leaking state. Intentionally available to
/// production builds (so test helpers can be used in SwiftUI previews
/// and `#Preview` Macros), but should never be used as the auth store
/// in a release build.
public actor InMemoryKeychainStore: KeychainStore {

    private var entries: [String: Data] = [:]

    public init() {}

    // MARK: KeychainStore

    public func loadCredential(workspaceID: String) async throws -> WorkspaceCredential {
        let data = try data(for: Self.credentialKey(workspaceID: workspaceID))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(WorkspaceCredential.self, from: data)
        } catch {
            throw KeychainError.decodeFailed(reason: String(describing: error))
        }
    }

    public func saveCredential(_ credential: WorkspaceCredential) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            entries[Self.credentialKey(workspaceID: credential.id)] = try encoder.encode(credential)
        } catch {
            throw KeychainError.encodeFailed(reason: String(describing: error))
        }
    }

    public func deleteCredential(workspaceID: String) async throws {
        entries.removeValue(forKey: Self.credentialKey(workspaceID: workspaceID))
    }

    public func loadAccessToken(workspaceID: String) async throws -> AccessToken {
        let data = try data(for: Self.accessTokenKey(workspaceID: workspaceID))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let stored = try decoder.decode(StoredAccessToken.self, from: data)
            return AccessToken(value: stored.value, expiresAt: stored.expiresAt, workspaceID: workspaceID)
        } catch {
            throw KeychainError.decodeFailed(reason: String(describing: error))
        }
    }

    public func saveAccessToken(_ token: AccessToken) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let stored = StoredAccessToken(value: token.value, expiresAt: token.expiresAt)
            entries[Self.accessTokenKey(workspaceID: token.workspaceID)] = try encoder.encode(stored)
        } catch {
            throw KeychainError.encodeFailed(reason: String(describing: error))
        }
    }

    public func loadRefreshToken(workspaceID: String) async throws -> String {
        let data = try data(for: Self.refreshTokenKey(workspaceID: workspaceID))
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodeFailed(reason: "refresh token is not valid UTF-8")
        }
        return value
    }

    public func saveRefreshToken(_ refreshToken: String, workspaceID: String) async throws {
        guard let data = refreshToken.data(using: .utf8) else {
            throw KeychainError.encodeFailed(reason: "refresh token is not encodable as UTF-8")
        }
        entries[Self.refreshTokenKey(workspaceID: workspaceID)] = data
    }

    public func deleteTokens(workspaceID: String) async throws {
        entries.removeValue(forKey: Self.accessTokenKey(workspaceID: workspaceID))
        entries.removeValue(forKey: Self.refreshTokenKey(workspaceID: workspaceID))
    }

    public func loadWorkspacesIndex() async throws -> [String] {
        guard let data = entries[Self.indexKey] else {
            return []
        }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode([String].self, from: data)
        } catch {
            throw KeychainError.decodeFailed(reason: String(describing: error))
        }
    }

    public func saveWorkspacesIndex(_ ids: [String]) async throws {
        let encoder = JSONEncoder()
        do {
            entries[Self.indexKey] = try encoder.encode(ids)
        } catch {
            throw KeychainError.encodeFailed(reason: String(describing: error))
        }
    }

    public func loadActiveWorkspaceID() async throws -> String? {
        guard let data = entries[Self.activeKey] else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func saveActiveWorkspaceID(_ id: String) async throws {
        guard let data = id.data(using: .utf8) else {
            throw KeychainError.encodeFailed(reason: "active workspace id is not encodable as UTF-8")
        }
        entries[Self.activeKey] = data
    }

    public func clearActiveWorkspaceID() async throws {
        entries.removeValue(forKey: Self.activeKey)
    }

    public func clearAll() async throws {
        entries.removeAll()
    }

    // MARK: Test introspection

    /// Test-only — returns the internal entry count so test cases can
    /// assert that ``clearAll`` actually cleared things.
    public func entryCount() async -> Int {
        entries.count
    }

    // MARK: Helpers

    private static func credentialKey(workspaceID: String) -> String { "credential:\(workspaceID)" }
    private static func accessTokenKey(workspaceID: String) -> String { "access:\(workspaceID)" }
    private static func refreshTokenKey(workspaceID: String) -> String { "refresh:\(workspaceID)" }
    private static let indexKey = "workspaces.index"
    private static let activeKey = "active.id"

    private func data(for key: String) throws -> Data {
        guard let data = entries[key] else {
            throw KeychainError.itemNotFound
        }
        return data
    }
}

private struct StoredAccessToken: Codable {
    let value: String
    let expiresAt: Date
}
