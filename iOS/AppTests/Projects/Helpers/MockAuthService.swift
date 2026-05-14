import AuthenticationServices
import Foundation

@testable import LakeloomApp

/// Mock ``AuthServicing`` for ProjectService tests. Returns a token
/// that the scripted API client can compare against; can be
/// reconfigured per-test for force-refresh paths.
public actor MockAuthService: AuthServicing {

    public private(set) var currentTokenCalls: [Bool] = []  // forceRefresh values
    public private(set) var workspacesCache: [WorkspaceCredential] = []
    public private(set) var activeID: String?
    public private(set) var nextTokenValue: String
    public private(set) var nextTokenAfterForceRefresh: String?
    public var tokenError: AuthError?

    public init(
        initialToken: String = "token-1",
        activeWorkspace: WorkspaceCredential? = nil
    ) {
        self.nextTokenValue = initialToken
        if let workspace = activeWorkspace {
            self.workspacesCache = [workspace]
            self.activeID = workspace.id
        }
    }

    public func setActiveWorkspace(_ workspace: WorkspaceCredential) {
        if !workspacesCache.contains(where: { $0.id == workspace.id }) {
            workspacesCache.append(workspace)
        }
        activeID = workspace.id
    }

    public func setNextTokenAfterForceRefresh(_ value: String) {
        nextTokenAfterForceRefresh = value
    }

    public func setTokenError(_ error: AuthError?) {
        tokenError = error
    }

    // MARK: AuthServicing

    public var workspaces: [WorkspaceCredential] {
        workspacesCache
    }

    public var activeWorkspace: WorkspaceCredential? {
        activeID.flatMap { id in workspacesCache.first(where: { $0.id == id }) }
    }

    public var events: AsyncStream<AuthEvent> {
        get async {
            // Tests for ProjectService don't subscribe; return a stream
            // whose continuation is never yielded to.
            AsyncStream { _ in }
        }
    }

    public func currentToken(forceRefresh: Bool) async throws -> AccessToken {
        currentTokenCalls.append(forceRefresh)
        if let error = tokenError {
            throw error
        }
        let value: String
        if forceRefresh, let rotated = nextTokenAfterForceRefresh {
            value = rotated
            nextTokenValue = rotated
            nextTokenAfterForceRefresh = nil
        } else {
            value = nextTokenValue
        }
        return AccessToken(
            value: value,
            expiresAt: Date(timeIntervalSinceNow: 3_600),
            workspaceID: activeID ?? "ws-1"
        )
    }

    @MainActor
    public func signIn(
        workspaceURL: URL,
        presenting: ASWebAuthenticationPresentationContextProviding
    ) async throws -> WorkspaceCredential {
        throw AuthError.unexpectedResponse(reason: "MockAuthService.signIn not implemented")
    }

    public func validateWorkspaceURL(_ workspaceURL: URL) async throws {
        // No-op for tests.
    }

    public func switchWorkspace(to workspaceID: String) async throws {
        guard workspacesCache.contains(where: { $0.id == workspaceID }) else {
            throw AuthError.unknownWorkspace(workspaceID)
        }
        activeID = workspaceID
    }

    public func signOut(workspaceID: String) async throws {
        workspacesCache.removeAll { $0.id == workspaceID }
        if activeID == workspaceID { activeID = workspacesCache.first?.id }
    }

    public func signOutAll() async throws {
        workspacesCache.removeAll()
        activeID = nil
    }

    public func refreshIdentity() async throws -> UserIdentity {
        throw AuthError.unexpectedResponse(reason: "MockAuthService.refreshIdentity not implemented")
    }
}

extension WorkspaceCredential {
    public static func fixture(
        id: String = "ws-1",
        host: String = "acme.cloud.databricks.com"
    ) -> WorkspaceCredential {
        WorkspaceCredential(
            id: id,
            workspaceURL: URL(string: "https://\(host)") ?? URL(fileURLWithPath: "/"),
            workspaceName: "ACME",
            cloud: .aws,
            region: "us-west-2",
            user: UserIdentity(
                userID: "u-1",
                userName: "u@example.com",
                displayName: "User",
                email: "u@example.com",
                active: true
            ),
            isDefault: true,
            signedInAt: Date(timeIntervalSince1970: 1_700_000_000),
            identityRefreshedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appBaseURL: URL(string: "https://lakeloom-ai.aws.databricksapps.com") ?? URL(fileURLWithPath: "/"),
            authMethod: .qrPaired(
                pairedSessionID: "paired-fixture",
                sessionExpiresAt: Date(timeIntervalSince1970: 1_700_604_800)
            )
        )
    }
}
