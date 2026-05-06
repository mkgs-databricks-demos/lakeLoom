import Foundation
import Security

/// Production ``KeychainStore`` backed by the Security framework.
///
/// All entries use:
/// - `kSecClass` = `kSecClassGenericPassword`
/// - `kSecAttrService` = `"com.databricks.lakeloom.auth"` (or override)
/// - `kSecAttrAccount` = the per-account key (see ``Account``)
/// - `kSecAttrAccessible` = `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// - `kSecAttrSynchronizable` = `false` — no iCloud sync, ever
///
/// See Module 01 §8.
public struct LiveKeychainStore: KeychainStore {

    // MARK: Account naming

    private enum Account {
        static func credential(workspaceID: String) -> String { "workspace.\(workspaceID).credential" }
        static func accessToken(workspaceID: String) -> String { "workspace.\(workspaceID).access_token" }
        static func refreshToken(workspaceID: String) -> String { "workspace.\(workspaceID).refresh_token" }
        static let workspacesIndex = "workspaces.index"
        static let activeWorkspaceID = "active_workspace_id"
    }

    /// Schema version for the stored ``WorkspaceCredential`` DTO. Bump when
    /// the on-disk shape changes; the load path can perform an in-place
    /// migration or surface ``KeychainError/unsupportedSchemaVersion``.
    public static let credentialSchemaVersion: Int = 1

    public let service: String

    public init(service: String = "com.databricks.lakeloom.auth") {
        self.service = service
    }

    // MARK: Credential records

    public func loadCredential(workspaceID: String) async throws -> WorkspaceCredential {
        let data = try loadData(account: Account.credential(workspaceID: workspaceID))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let dto = try decoder.decode(WorkspaceCredentialDTO.self, from: data)
            try validateSchemaVersion(dto.schemaVersion)
            return dto.toCredential()
        } catch let error as KeychainError {
            throw error
        } catch {
            throw KeychainError.decodeFailed(reason: String(describing: error))
        }
    }

    public func saveCredential(_ credential: WorkspaceCredential) async throws {
        let dto = WorkspaceCredentialDTO(credential: credential, schemaVersion: Self.credentialSchemaVersion)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(dto)
        } catch {
            throw KeychainError.encodeFailed(reason: String(describing: error))
        }
        try saveData(data, account: Account.credential(workspaceID: credential.id))
    }

    public func deleteCredential(workspaceID: String) async throws {
        try deleteIfExists(account: Account.credential(workspaceID: workspaceID))
    }

    // MARK: Tokens

    public func loadAccessToken(workspaceID: String) async throws -> AccessToken {
        let data = try loadData(account: Account.accessToken(workspaceID: workspaceID))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let dto = try decoder.decode(AccessTokenDTO.self, from: data)
            return AccessToken(value: dto.value, expiresAt: dto.expiresAt, workspaceID: workspaceID)
        } catch {
            throw KeychainError.decodeFailed(reason: String(describing: error))
        }
    }

    public func saveAccessToken(_ token: AccessToken) async throws {
        let dto = AccessTokenDTO(value: token.value, expiresAt: token.expiresAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(dto)
        } catch {
            throw KeychainError.encodeFailed(reason: String(describing: error))
        }
        try saveData(data, account: Account.accessToken(workspaceID: token.workspaceID))
    }

    public func loadRefreshToken(workspaceID: String) async throws -> String {
        let data = try loadData(account: Account.refreshToken(workspaceID: workspaceID))
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodeFailed(reason: "refresh token is not valid UTF-8")
        }
        return value
    }

    public func saveRefreshToken(_ refreshToken: String, workspaceID: String) async throws {
        guard let data = refreshToken.data(using: .utf8) else {
            throw KeychainError.encodeFailed(reason: "refresh token is not encodable as UTF-8")
        }
        try saveData(data, account: Account.refreshToken(workspaceID: workspaceID))
    }

    public func deleteTokens(workspaceID: String) async throws {
        try deleteIfExists(account: Account.accessToken(workspaceID: workspaceID))
        try deleteIfExists(account: Account.refreshToken(workspaceID: workspaceID))
    }

    // MARK: Workspaces index and active selection

    public func loadWorkspacesIndex() async throws -> [String] {
        do {
            let data = try loadData(account: Account.workspacesIndex)
            let decoder = JSONDecoder()
            do {
                return try decoder.decode([String].self, from: data)
            } catch {
                throw KeychainError.decodeFailed(reason: String(describing: error))
            }
        } catch KeychainError.itemNotFound {
            return []
        }
    }

    public func saveWorkspacesIndex(_ ids: [String]) async throws {
        let encoder = JSONEncoder()
        let data: Data
        do {
            data = try encoder.encode(ids)
        } catch {
            throw KeychainError.encodeFailed(reason: String(describing: error))
        }
        try saveData(data, account: Account.workspacesIndex)
    }

    public func loadActiveWorkspaceID() async throws -> String? {
        do {
            let data = try loadData(account: Account.activeWorkspaceID)
            return String(data: data, encoding: .utf8)
        } catch KeychainError.itemNotFound {
            return nil
        }
    }

    public func saveActiveWorkspaceID(_ id: String) async throws {
        guard let data = id.data(using: .utf8) else {
            throw KeychainError.encodeFailed(reason: "active workspace id is not encodable as UTF-8")
        }
        try saveData(data, account: Account.activeWorkspaceID)
    }

    public func clearActiveWorkspaceID() async throws {
        try deleteIfExists(account: Account.activeWorkspaceID)
    }

    // MARK: Bulk reset

    public func clearAll() async throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }

    // MARK: - Internals

    private func validateSchemaVersion(_ version: Int) throws {
        guard version == Self.credentialSchemaVersion else {
            throw KeychainError.unsupportedSchemaVersion(
                found: version,
                supported: Self.credentialSchemaVersion
            )
        }
    }

    private func baseQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false
        ]
    }

    private func loadData(account: String) throws -> Data {
        var query = baseQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.decodeFailed(reason: "Keychain returned non-Data result")
            }
            return data
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        default:
            throw KeychainError.osStatus(status)
        }
    }

    private func saveData(_ data: Data, account: String) throws {
        let baseQuery = baseQuery(account: account)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        // Try update first; fall back to add. This pattern avoids the race
        // window of "delete then add" where another caller could read the
        // key in between.
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.osStatus(updateStatus)
        }

        var addQuery = baseQuery
        for (key, value) in attributes {
            addQuery[key] = value
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.osStatus(addStatus)
        }
    }

    private func deleteIfExists(account: String) throws {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }
}

// MARK: - DTOs

/// Internal storage shape for ``WorkspaceCredential``. We deliberately keep
/// it separate from the public type so we can evolve disk encoding via
/// `schemaVersion` without changing the in-memory contract.
private struct WorkspaceCredentialDTO: Codable {
    let id: String
    let workspaceURL: URL
    let workspaceName: String
    let cloud: Cloud
    let region: String?
    let user: UserIdentity
    let isDefault: Bool
    let signedInAt: Date
    let identityRefreshedAt: Date
    let schemaVersion: Int

    init(credential: WorkspaceCredential, schemaVersion: Int) {
        self.id = credential.id
        self.workspaceURL = credential.workspaceURL
        self.workspaceName = credential.workspaceName
        self.cloud = credential.cloud
        self.region = credential.region
        self.user = credential.user
        self.isDefault = credential.isDefault
        self.signedInAt = credential.signedInAt
        self.identityRefreshedAt = credential.identityRefreshedAt
        self.schemaVersion = schemaVersion
    }

    func toCredential() -> WorkspaceCredential {
        WorkspaceCredential(
            id: id,
            workspaceURL: workspaceURL,
            workspaceName: workspaceName,
            cloud: cloud,
            region: region,
            user: user,
            isDefault: isDefault,
            signedInAt: signedInAt,
            identityRefreshedAt: identityRefreshedAt
        )
    }
}

private struct AccessTokenDTO: Codable {
    let value: String
    let expiresAt: Date
}
