import Foundation

@testable import LakeloomApp

/// Scriptable ``DatabricksIdentityClient`` for unit tests. `@MainActor` for
/// consistency with ``FakeOAuthClient`` so test setup can configure both
/// without isolation hops.
@MainActor
public final class StubDatabricksIdentityClient: DatabricksIdentityClient {

    public enum Outcome: Sendable {
        case success(SCIMMeResponse)
        case failure(IdentityClientError)
    }

    public private(set) var fetchCalls: [(workspaceURL: URL, bearerToken: String)] = []
    public var outcomes: [Outcome] = []

    public init() {}

    public func enqueue(_ outcome: Outcome) {
        outcomes.append(outcome)
    }

    public func fetchMe(workspaceURL: URL, bearerToken: String) async throws -> SCIMMeResponse {
        fetchCalls.append((workspaceURL, bearerToken))
        guard !outcomes.isEmpty else {
            throw IdentityClientError.unexpectedResponse(reason: "StubDatabricksIdentityClient: no outcome enqueued")
        }
        let outcome = outcomes.removeFirst()
        switch outcome {
        case .success(let response): return response
        case .failure(let error): throw error
        }
    }
}
