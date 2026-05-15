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

    /// Pre-rewrite (OAuth U2M) flow stored a workspace OAuth refresh
    /// token here. Post-rewrite (QR-pair) does not — M2M client_credentials
    /// grant has no refresh token. These methods stick around through
    /// commits 1–2 of the rewrite so existing code compiles; they're
    /// deleted in commit 3 along with the OAuth signIn path.
    func loadRefreshToken(workspaceID: String) async throws -> String
    func saveRefreshToken(_ refreshToken: String, workspaceID: String) async throws

    /// Delete access token + (legacy) refresh token + session token +
    /// Xcode SPN credentials for `workspaceID`. Idempotent — missing
    /// items do not throw.
    func deleteTokens(workspaceID: String) async throws

    // MARK: QR-pair credentials (post-Module 01 rewrite)

    /// The opaque per-paired-session token iOS sends as
    /// `X-Lakeloom-Session`. Loaded once per session refresh in
    /// AuthService; persistence keyed by workspace.
    func loadSessionToken(workspaceID: String) async throws -> String
    func saveSessionToken(_ token: String, workspaceID: String) async throws

    /// The Xcode SPN's OAuth client credentials, delivered via the QR
    /// payload's `xcode_spn` field. iOS exchanges these for an M2M
    /// bearer at the workspace's `/oidc/v1/token` endpoint on every
    /// near-expiry refresh.
    func loadXcodeSPNCredentials(workspaceID: String) async throws -> XcodeSPNCredentials
    func saveXcodeSPNCredentials(_ credentials: XcodeSPNCredentials, workspaceID: String) async throws

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
