import Foundation

/// Builds the OAuth 2.0 authorization request URL for the Databricks
/// workspace's authorization endpoint.
///
/// See Module 01 §5.4. The state parameter defends against CSRF; the
/// caller must verify it on the callback.
public enum OAuthURLBuilder {

    public struct Components: Sendable, Equatable {
        public let authorizationEndpoint: URL
        public let clientID: String
        public let redirectURI: URL
        public let scopes: [String]
        public let pkce: PKCE
        public let state: String

        public init(
            authorizationEndpoint: URL,
            clientID: String,
            redirectURI: URL,
            scopes: [String],
            pkce: PKCE,
            state: String
        ) {
            self.authorizationEndpoint = authorizationEndpoint
            self.clientID = clientID
            self.redirectURI = redirectURI
            self.scopes = scopes
            self.pkce = pkce
            self.state = state
        }
    }

    /// Generates a fresh 32-byte random state value, base64url-encoded.
    /// Throws ``PKCEError/randomGenerationFailed`` if the system RNG fails
    /// (we reuse the PKCE error type since the failure mode is identical).
    public static func generateState() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw PKCEError.randomGenerationFailed(status: status)
        }
        return Data(bytes).base64URLEncodedString()
    }

    /// Composes the authorization URL. The returned URL is what the caller
    /// passes to `ASWebAuthenticationSession`.
    public static func authorizationURL(components: Components) throws -> URL {
        guard var url = URLComponents(url: components.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw OAuthURLBuilderError.invalidAuthorizationEndpoint(components.authorizationEndpoint)
        }
        var items = url.queryItems ?? []
        items.append(URLQueryItem(name: "client_id", value: components.clientID))
        items.append(URLQueryItem(name: "response_type", value: "code"))
        items.append(URLQueryItem(name: "redirect_uri", value: components.redirectURI.absoluteString))
        items.append(URLQueryItem(name: "scope", value: components.scopes.joined(separator: " ")))
        items.append(URLQueryItem(name: "code_challenge", value: components.pkce.codeChallenge))
        items.append(URLQueryItem(name: "code_challenge_method", value: components.pkce.codeChallengeMethod))
        items.append(URLQueryItem(name: "state", value: components.state))
        url.queryItems = items
        guard let result = url.url else {
            throw OAuthURLBuilderError.invalidAuthorizationEndpoint(components.authorizationEndpoint)
        }
        return result
    }

    /// Parses an OAuth callback URL and returns either the authorization
    /// code or an OAuth-protocol error reason. The caller is responsible
    /// for verifying that the returned `state` matches the value sent on
    /// the original authorization request.
    public static func parseCallback(_ url: URL) -> CallbackResult {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems
        else {
            return .invalid
        }

        var code: String?
        var state: String?
        var error: String?
        var errorDescription: String?

        for item in items {
            switch item.name {
            case "code": code = item.value
            case "state": state = item.value
            case "error": error = item.value
            case "error_description": errorDescription = item.value
            default: break
            }
        }

        if let error {
            let reason = errorDescription.map { "\(error): \($0)" } ?? error
            return .error(reason: reason, state: state)
        }
        guard let code, let state else {
            return .invalid
        }
        return .code(code, state: state)
    }

    public enum CallbackResult: Sendable, Equatable {
        case code(String, state: String)
        case error(reason: String, state: String?)
        case invalid
    }
}

public enum OAuthURLBuilderError: Error, Sendable, Equatable {
    case invalidAuthorizationEndpoint(URL)
}
