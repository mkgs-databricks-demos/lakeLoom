import AuthenticationServices
import Foundation

/// OAuth 2.0 U2M operations against a Databricks workspace.
///
/// Implementations are stateless — no token storage, no workspace
/// management. AuthService composes this with the Keychain layer to
/// produce the user-visible behavior.
public protocol OAuthClient: Sendable {

    /// Validates that `workspaceURL` exposes a Databricks OIDC discovery
    /// endpoint. Returns the discovered authorization + token endpoints.
    func discoverEndpoints(workspaceURL: URL) async throws -> OAuthDiscoveryDocument

    /// Performs the full OAuth code-for-token exchange. The implementation
    /// chooses the redirect URI strategy — production uses an in-app
    /// loopback HTTP listener (Databricks U2M's `databricks-cli` client
    /// is registered with `http://localhost` redirects only). Tests stub
    /// the whole flow.
    @MainActor
    func performAuthorizationCodeFlow(
        workspaceURL: URL,
        clientID: String,
        scopes: [String],
        presenting: ASWebAuthenticationPresentationContextProviding
    ) async throws -> OAuthTokenResponse

    /// Refreshes an access token using a stored refresh token.
    func refreshTokens(
        workspaceURL: URL,
        clientID: String,
        refreshToken: String
    ) async throws -> OAuthTokenResponse
}

/// The fields of an OIDC discovery response we use.
public struct OAuthDiscoveryDocument: Sendable, Equatable, Codable {
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let issuer: URL?

    public init(authorizationEndpoint: URL, tokenEndpoint: URL, issuer: URL?) {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.issuer = issuer
    }

    private enum CodingKeys: String, CodingKey {
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case issuer
    }
}

/// Errors produced by ``OAuthClient``. AuthService translates these onto
/// its own ``AuthError`` cases per Module 01 §9.
public enum OAuthError: Error, Sendable, Equatable {
    case invalidWorkspaceURL(reason: String)
    case discoveryFailed(reason: String)
    case userCancelled
    case stateMismatch
    case authorizationFailed(reason: String)
    case tokenExchangeFailed(reason: String)
    case invalidGrant
    case unauthorizedClient
    case networkUnavailable
    case timeout
    case unexpectedResponse(reason: String)
    case randomGenerationFailed(status: OSStatus)
}

extension OAuthError {
    /// True when the refresh token has been revoked or expired and the user
    /// must sign in again.
    public var isInvalidGrant: Bool {
        if case .invalidGrant = self { return true }
        return false
    }
}
