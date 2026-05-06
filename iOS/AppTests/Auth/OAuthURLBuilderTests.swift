import Foundation
import Testing

@testable import LakeloomApp

@Suite("OAuthURLBuilder.authorizationURL")
struct OAuthURLBuilderAuthorizationURLTests {
    private let endpoint = URL(string: "https://acme.cloud.databricks.com/oidc/v1/authorize")!
    private let redirect = URL(string: "lakeloom://oauth/callback")!

    private func makeComponents() -> OAuthURLBuilder.Components {
        OAuthURLBuilder.Components(
            authorizationEndpoint: endpoint,
            clientID: "client-123",
            redirectURI: redirect,
            scopes: ["all-apis", "offline_access"],
            pkce: PKCE.from(verifier: "v"),
            state: "state-xyz"
        )
    }

    @Test("contains all required query parameters")
    func containsRequiredParameters() throws {
        let url = try OAuthURLBuilder.authorizationURL(components: makeComponents())
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try #require(components.queryItems)
        let names = Set(items.map(\.name))
        #expect(names.contains("client_id"))
        #expect(names.contains("response_type"))
        #expect(names.contains("redirect_uri"))
        #expect(names.contains("scope"))
        #expect(names.contains("code_challenge"))
        #expect(names.contains("code_challenge_method"))
        #expect(names.contains("state"))
    }

    @Test("scope is space-joined")
    func scopeIsSpaceJoined() throws {
        let url = try OAuthURLBuilder.authorizationURL(components: makeComponents())
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let scope = components.queryItems?.first(where: { $0.name == "scope" })?.value
        #expect(scope == "all-apis offline_access")
    }

    @Test("response_type=code and code_challenge_method=S256")
    func staticParameters() throws {
        let url = try OAuthURLBuilder.authorizationURL(components: makeComponents())
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let responseType = components.queryItems?.first(where: { $0.name == "response_type" })?.value
        let method = components.queryItems?.first(where: { $0.name == "code_challenge_method" })?.value
        #expect(responseType == "code")
        #expect(method == "S256")
    }
}

@Suite("OAuthURLBuilder.parseCallback")
struct OAuthURLBuilderParseCallbackTests {

    @Test("parses code + state on success")
    func parsesCodeAndState() throws {
        let url = try #require(URL(string: "lakeloom://oauth/callback?code=abc&state=xyz"))
        switch OAuthURLBuilder.parseCallback(url) {
        case .code(let code, let state):
            #expect(code == "abc")
            #expect(state == "xyz")
        default:
            Issue.record("expected .code")
        }
    }

    @Test("parses error with state when present")
    func parsesErrorWithState() throws {
        let url = try #require(URL(string: "lakeloom://oauth/callback?error=access_denied&error_description=User%20declined&state=xyz"))
        switch OAuthURLBuilder.parseCallback(url) {
        case .error(let reason, let state):
            #expect(reason.contains("access_denied"))
            #expect(reason.contains("User declined"))
            #expect(state == "xyz")
        default:
            Issue.record("expected .error")
        }
    }

    @Test("returns invalid when code and error both missing")
    func returnsInvalidWhenBothMissing() throws {
        let url = try #require(URL(string: "lakeloom://oauth/callback?something=else"))
        switch OAuthURLBuilder.parseCallback(url) {
        case .invalid:
            #expect(Bool(true))
        default:
            Issue.record("expected .invalid")
        }
    }

    @Test("returns invalid when code present but state missing")
    func returnsInvalidWhenStateMissing() throws {
        let url = try #require(URL(string: "lakeloom://oauth/callback?code=abc"))
        switch OAuthURLBuilder.parseCallback(url) {
        case .invalid:
            #expect(Bool(true))
        default:
            Issue.record("expected .invalid for missing state")
        }
    }
}

@Suite("OAuthURLBuilder.generateState")
struct OAuthURLBuilderGenerateStateTests {

    @Test("returns a URL-safe 43-character string")
    func returnsURLSafeString() throws {
        let state = try OAuthURLBuilder.generateState()
        #expect(state.count == 43)
        let forbidden = CharacterSet(charactersIn: "+/=")
        #expect(state.unicodeScalars.allSatisfy { !forbidden.contains($0) })
    }

    @Test("two consecutive calls produce different values")
    func twoCallsDiffer() throws {
        let a = try OAuthURLBuilder.generateState()
        let b = try OAuthURLBuilder.generateState()
        #expect(a != b)
    }
}
