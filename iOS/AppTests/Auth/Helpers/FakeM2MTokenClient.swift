import Foundation

@testable import LakeloomApp

/// Scriptable in-memory ``M2MTokenClient`` for unit tests.
///
/// Tests seed the responses ``acquireToken`` should return for each
/// call. Each call records its arguments so assertions can verify
/// caching / refresh behavior end-to-end.
public actor FakeM2MTokenClient: M2MTokenClient {

    public enum Outcome: Sendable {
        case success(accessToken: String, expiresIn: Int)
        case failure(M2MTokenError)
    }

    public struct Call: Sendable {
        public let workspaceURL: URL
        public let clientID: String
        public let scopes: [String]
    }

    public private(set) var calls: [Call] = []
    public var outcomes: [Outcome] = []

    public init() {}

    public func enqueue(_ outcome: Outcome) {
        outcomes.append(outcome)
    }

    public func acquireToken(
        workspaceURL: URL,
        clientID: String,
        clientSecret: String,
        scopes: [String]
    ) async throws -> OAuthTokenResponse {
        calls.append(Call(workspaceURL: workspaceURL, clientID: clientID, scopes: scopes))
        guard !outcomes.isEmpty else {
            throw M2MTokenError.unexpectedResponse(reason: "FakeM2MTokenClient: no outcome enqueued")
        }
        let outcome = outcomes.removeFirst()
        switch outcome {
        case .success(let accessToken, let expiresIn):
            return OAuthTokenResponse(
                accessToken: accessToken,
                refreshToken: nil,
                tokenType: "Bearer",
                expiresIn: expiresIn,
                scope: scopes.joined(separator: " ")
            )
        case .failure(let error):
            throw error
        }
    }
}
