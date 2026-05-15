import Foundation

/// Decoded form of a Databricks OIDC token endpoint response.
/// Used for both the initial code-for-token exchange and refresh-token
/// exchanges.
///
/// Databricks rotates refresh tokens on each refresh, so `refreshToken`
/// is optional but typically present. The auth service persists the new
/// refresh token on every response that includes one.
public struct OAuthTokenResponse: Sendable, Equatable, Codable {
    public let accessToken: String
    public let refreshToken: String?
    public let tokenType: String
    public let expiresIn: Int
    public let scope: String?

    public init(
        accessToken: String,
        refreshToken: String?,
        tokenType: String,
        expiresIn: Int,
        scope: String?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.scope = scope
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
    }
}

/// Decoded form of an OAuth token-endpoint *error* response per RFC 6749 §5.2.
/// We pattern-match on `error` (`invalid_grant`, `invalid_client`, etc.) to
/// drive the AuthService's recovery path — particularly distinguishing a
/// permanently-revoked refresh token (`invalid_grant`) from transient
/// failures.
public struct OAuthTokenErrorResponse: Sendable, Equatable, Codable {
    public let error: String
    public let errorDescription: String?
    public let errorURI: String?

    public init(error: String, errorDescription: String?, errorURI: String?) {
        self.error = error
        self.errorDescription = errorDescription
        self.errorURI = errorURI
    }

    private enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case errorURI = "error_uri"
    }

    /// True when the refresh token has been revoked or expired and the user
    /// must sign in again. RFC 6749 §5.2 specifies `invalid_grant` for this.
    public var isInvalidGrant: Bool {
        error == "invalid_grant"
    }
}
