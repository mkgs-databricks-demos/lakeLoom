import Foundation

/// Per-workspace credential and token storage.
///
/// All implementations must:
/// - Store secrets with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
/// - Disable iCloud sync (`kSecAttrSynchronizable = false`).
/// - Use the same `kSecAttrService` namespace so a future "clear all
///   lakeLoom auth" sweep can target it.
///
/// The protocol is designed for testability — the production
/// ``LiveKeychainStore`` is backed by the Security framework; the
/// ``InMemoryKeychainStore`` test impl is a plain dictionary.
public protocol KeychainStore: Sendable {

    // MARK: Credential records

    func loadCredential(workspaceID: String) async throws -> WorkspaceCredential
    func saveCredential(_ credential: WorkspaceCredential) async throws
    func deleteCredential(workspaceID: String) async throws

    // MARK: Tokens

    func loadAccessToken(workspaceID: String) async throws -> AccessToken
    func saveAccessToken(_ token: AccessToken) async throws

    func loadRefreshToken(workspaceID: String) async throws -> String
    func saveRefreshToken(_ refreshToken: String, workspaceID: String) async throws

    /// Delete both access and refresh tokens for `workspaceID`. Idempotent —
    /// missing items do not throw.
    func deleteTokens(workspaceID: String) async throws

    // MARK: Workspaces index and active selection

    func loadWorkspacesIndex() async throws -> [String]
    func saveWorkspacesIndex(_ ids: [String]) async throws

    func loadActiveWorkspaceID() async throws -> String?
    func saveActiveWorkspaceID(_ id: String) async throws
    func clearActiveWorkspaceID() async throws

    // MARK: Bulk reset

    /// Removes every Keychain entry created by lakeLoom auth. Used by
    /// "Reset local data" in Settings and by the first-launch sentinel
    /// hygiene path.
    func clearAll() async throws
}
