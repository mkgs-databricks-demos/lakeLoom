import AuthenticationServices
import Foundation

// MARK: - Public protocol

/// The single source of truth for Databricks workspace authentication.
///
/// Implementations own the OAuth 2.0 U2M flow with PKCE, per-workspace token
/// storage in Keychain, silent refresh on 401, and the active-workspace
/// selection. Other modules call ``currentToken(forceRefresh:)`` before each
/// authenticated request and never touch tokens or Keychain directly.
///
/// See `architecture/LakeLoomMarkdowns/module-01-auth-service.md`.
public protocol AuthServicing: Sendable {

    /// All workspaces the user has signed into. Empty if never signed in.
    var workspaces: [WorkspaceCredential] { get async }

    /// The currently active workspace, if any. Nil before first login.
    var activeWorkspace: WorkspaceCredential? { get async }

    /// Stream of identity-relevant changes (sign-in, sign-out, workspace switch,
    /// identity refresh). Multicast — multiple subscribers (e.g. AppCoordinator,
    /// IngestService) can listen in parallel.
    ///
    /// `get async` because subscription registration runs on the actor.
    /// By the time `await service.events` returns, the subscriber's
    /// continuation is already in the broadcast set — any event fired
    /// after the await reaches this subscriber.
    var events: AsyncStream<AuthEvent> { get async }

    /// Returns a valid bearer token for the active workspace.
    ///
    /// Refreshes silently if the cached token is expired or near expiry.
    /// `forceRefresh: true` skips the expiry check and forces a refresh —
    /// used by callers that received a 401 and want to retry once.
    /// Concurrent callers during an in-flight refresh await the same task
    /// rather than triggering N parallel refreshes.
    ///
    /// Throws ``AuthError/noActiveWorkspace`` if no workspace is active,
    /// ``AuthError/refreshFailed(reason:)`` if the refresh token is rejected,
    /// or ``AuthError/networkUnavailable`` if the token endpoint is unreachable.
    func currentToken(forceRefresh: Bool) async throws -> AccessToken

    /// Initiates the OAuth login flow for a new workspace.
    ///
    /// Presents `ASWebAuthenticationSession` via `presenting`. On success the
    /// new workspace is added to the workspaces list and made active.
    @MainActor
    func signIn(
        workspaceURL: URL,
        presenting: ASWebAuthenticationPresentationContextProviding
    ) async throws -> WorkspaceCredential

    /// Validates that `workspaceURL` is reachable and exposes a Databricks OIDC
    /// discovery endpoint. Used by the onboarding step before the OAuth flow
    /// is presented so the user gets fast feedback on a bad URL.
    func validateWorkspaceURL(_ workspaceURL: URL) async throws

    /// Switches the active workspace. The target must already be in the
    /// workspaces list (i.e. the user must have signed into it before).
    func switchWorkspace(to workspaceID: String) async throws

    /// Signs out of a specific workspace. Removes its credential and tokens.
    /// If it was the active workspace, the next available workspace becomes
    /// active (or nil if no others remain).
    func signOut(workspaceID: String) async throws

    /// Signs out of all workspaces and clears all stored credentials.
    func signOutAll() async throws

    /// Forces a refresh of the cached SCIM identity for the active workspace.
    func refreshIdentity() async throws -> UserIdentity
}

extension AuthServicing {
    /// Convenience overload — equivalent to `currentToken(forceRefresh: false)`.
    public func currentToken() async throws -> AccessToken {
        try await currentToken(forceRefresh: false)
    }
}

// MARK: - Value types

/// A signed-in Databricks workspace, including the user identity for that
/// workspace. Tokens are NOT stored here; they live in Keychain keyed by
/// ``id`` so this value can cross actor boundaries safely.
public struct WorkspaceCredential: Sendable, Identifiable, Equatable, Hashable, Codable {
    public let id: String
    public let workspaceURL: URL
    public let workspaceName: String
    public let cloud: Cloud
    public let region: String?
    public let user: UserIdentity
    public let isDefault: Bool
    public let signedInAt: Date
    public let identityRefreshedAt: Date

    public init(
        id: String,
        workspaceURL: URL,
        workspaceName: String,
        cloud: Cloud,
        region: String?,
        user: UserIdentity,
        isDefault: Bool,
        signedInAt: Date,
        identityRefreshedAt: Date
    ) {
        self.id = id
        self.workspaceURL = workspaceURL
        self.workspaceName = workspaceName
        self.cloud = cloud
        self.region = region
        self.user = user
        self.isDefault = isDefault
        self.signedInAt = signedInAt
        self.identityRefreshedAt = identityRefreshedAt
    }
}

/// SCIM-derived identity for a user in a specific workspace.
public struct UserIdentity: Sendable, Equatable, Hashable, Codable {
    public let userID: String
    public let userName: String
    public let displayName: String
    public let email: String?
    public let active: Bool

    public init(userID: String, userName: String, displayName: String, email: String?, active: Bool) {
        self.userID = userID
        self.userName = userName
        self.displayName = displayName
        self.email = email
        self.active = active
    }
}

/// A bearer token for a specific workspace, with its absolute expiry.
public struct AccessToken: Sendable, Equatable, Hashable {
    public let value: String
    public let expiresAt: Date
    public let workspaceID: String

    public init(value: String, expiresAt: Date, workspaceID: String) {
        self.value = value
        self.expiresAt = expiresAt
        self.workspaceID = workspaceID
    }

    /// True when the token is past its expiry (or within `skew` of it).
    public func isExpired(now: Date = Date(), skew: TimeInterval = 30) -> Bool {
        expiresAt <= now.addingTimeInterval(skew)
    }
}

/// The cloud the workspace is hosted on. Best-effort; derived from workspace
/// URL or from a Databricks API response if available.
public enum Cloud: String, Sendable, Codable, CaseIterable {
    case aws
    case azure
    case gcp
    case unknown
}

// MARK: - Events

/// Identity-relevant events emitted by ``AuthServicing/events``.
public enum AuthEvent: Sendable, Equatable {
    case signedIn(WorkspaceCredential)
    case signedOut(workspaceID: String)
    case switchedWorkspace(WorkspaceCredential)
    case identityRefreshed(WorkspaceCredential)
}

// MARK: - Errors

/// Typed errors surfaced by ``AuthServicing``. Internal helpers may throw
/// other error types (`OAuthError`, `KeychainError`, `URLError`); the public
/// surface translates them into one of these cases.
public enum AuthError: Error, Sendable, Equatable {
    case noActiveWorkspace
    case unknownWorkspace(String)

    /// User dismissed `ASWebAuthenticationSession`.
    case userCancelled

    /// Provided URL didn't parse, didn't have a host, or didn't expose an
    /// OIDC discovery endpoint.
    case invalidWorkspaceURL(String)

    /// Server-returned error during the OAuth code-for-token exchange.
    case oauthFailed(reason: String)

    /// Refresh token was rejected (`invalid_grant`) or otherwise can't be
    /// renewed. The user must sign in again. Tokens have been cleared but
    /// the credential record is preserved so the UI can show "Re-login
    /// required" without losing the workspace.
    case refreshFailed(reason: String)

    /// SCIM `/Me` lookup failed.
    case identityFetchFailed(reason: String)

    /// Keychain operation failed. Carries the OS status code for diagnostics.
    case keychainFailed(OSStatus)

    /// No network reachable when an authenticated call was attempted.
    case networkUnavailable

    /// The server returned an unexpected response (missing fields, wrong
    /// shape, etc.). Carries a short reason string for logging.
    case unexpectedResponse(reason: String)
}
