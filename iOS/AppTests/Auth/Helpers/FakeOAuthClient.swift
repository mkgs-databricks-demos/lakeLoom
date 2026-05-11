import AuthenticationServices
import Foundation
import UIKit

@testable import LakeloomApp

/// Scriptable in-memory ``OAuthClient`` for unit tests. Instead of running a
/// real OAuth flow, callers seed the responses ``performAuthorizationCodeFlow``
/// and ``refreshTokens`` should return for each call. Each method also
/// records the arguments it was invoked with so tests can assert on them.
///
/// `@MainActor`-isolated to match the protocol's `@MainActor` requirement on
/// `performAuthorizationCodeFlow` (which carries a non-Sendable
/// `ASWebAuthenticationPresentationContextProviding`).
@MainActor
public final class FakeOAuthClient: OAuthClient {

    public struct CallLog: Sendable {
        public var discoveryCalls: Int = 0
        public var authorizationCalls: Int = 0
        public var refreshCalls: [(workspaceURL: URL, refreshToken: String)] = []
    }

    public enum AuthorizationOutcome: Sendable {
        case success(OAuthTokenResponse)
        case failure(OAuthError)
    }

    public enum RefreshOutcome: Sendable {
        case success(OAuthTokenResponse)
        case failure(OAuthError)
    }

    public enum DiscoveryOutcome: Sendable {
        case success(OAuthDiscoveryDocument)
        case failure(OAuthError)
    }

    public private(set) var calls = CallLog()
    public var authorizationOutcomes: [AuthorizationOutcome] = []
    public var refreshOutcomes: [RefreshOutcome] = []
    public var discoveryOutcome: DiscoveryOutcome

    public init(
        defaultDiscovery: OAuthDiscoveryDocument = OAuthDiscoveryDocument(
            authorizationEndpoint: URL(string: "https://acme.example.com/oidc/v1/authorize") ?? URL(fileURLWithPath: "/"),
            tokenEndpoint: URL(string: "https://acme.example.com/oidc/v1/token") ?? URL(fileURLWithPath: "/"),
            issuer: nil
        )
    ) {
        self.discoveryOutcome = .success(defaultDiscovery)
    }

    public func setDiscoveryOutcome(_ outcome: DiscoveryOutcome) {
        discoveryOutcome = outcome
    }

    public func enqueueAuthorization(_ outcome: AuthorizationOutcome) {
        authorizationOutcomes.append(outcome)
    }

    public func enqueueRefresh(_ outcome: RefreshOutcome) {
        refreshOutcomes.append(outcome)
    }

    public func discoverEndpoints(workspaceURL: URL) async throws -> OAuthDiscoveryDocument {
        calls.discoveryCalls += 1
        switch discoveryOutcome {
        case .success(let doc): return doc
        case .failure(let error): throw error
        }
    }

    public func performAuthorizationCodeFlow(
        workspaceURL: URL,
        clientID: String,
        scopes: [String],
        presenting: ASWebAuthenticationPresentationContextProviding
    ) async throws -> OAuthTokenResponse {
        calls.authorizationCalls += 1
        guard !authorizationOutcomes.isEmpty else {
            throw OAuthError.unexpectedResponse(reason: "FakeOAuthClient: no authorization outcome enqueued")
        }
        let outcome = authorizationOutcomes.removeFirst()
        switch outcome {
        case .success(let response): return response
        case .failure(let error): throw error
        }
    }

    public func refreshTokens(
        workspaceURL: URL,
        clientID: String,
        refreshToken: String
    ) async throws -> OAuthTokenResponse {
        calls.refreshCalls.append((workspaceURL, refreshToken))
        guard !refreshOutcomes.isEmpty else {
            throw OAuthError.unexpectedResponse(reason: "FakeOAuthClient: no refresh outcome enqueued")
        }
        let outcome = refreshOutcomes.removeFirst()
        switch outcome {
        case .success(let response): return response
        case .failure(let error): throw error
        }
    }
}

/// Minimal context provider for tests. ``FakeOAuthClient`` short-circuits
/// before any UI is presented, so the anchor returned here is never
/// actually consulted by `ASWebAuthenticationSession`.
@MainActor
public final class TestPresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // In iOS 26, ASPresentationAnchor.init() is deprecated in favor of
        // init(windowScene:). Since FakeOAuthClient short-circuits before
        // ASWAS is started, we return a scene-attached anchor only when a
        // scene happens to be available; otherwise we trip the unreachable
        // path because the test setup is incorrect.
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            return ASPresentationAnchor(windowScene: scene)
        }
        fatalError("TestPresentationProvider was actually consulted; configure FakeOAuthClient to short-circuit.")
    }
}
