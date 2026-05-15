import Foundation
import Testing

@testable import LakeloomApp

@Suite("InMemoryKeychainStore")
struct InMemoryKeychainStoreTests {

    private func makeCredential(id: String = "ws-1") -> WorkspaceCredential {
        WorkspaceCredential(
            id: id,
            workspaceURL: URL(string: "https://acme.cloud.databricks.com")!,
            workspaceName: "ACME",
            cloud: .aws,
            region: "us-west-2",
            user: UserIdentity(userID: "u-1", userName: "u@a.com", displayName: "U", email: "u@a.com", active: true),
            isDefault: true,
            signedInAt: Date(timeIntervalSince1970: 1_700_000_000),
            identityRefreshedAt: Date(timeIntervalSince1970: 1_700_000_010),
            appBaseURL: URL(string: "https://lakeloom-ai.aws.databricksapps.com")!,
            authMethod: .qrPaired(
                pairedSessionID: "paired-1",
                sessionExpiresAt: Date(timeIntervalSince1970: 1_700_604_810)
            )
        )
    }

    @Test("credential round trip preserves all fields")
    func credentialRoundTrip() async throws {
        let store = InMemoryKeychainStore()
        let credential = makeCredential()
        try await store.saveCredential(credential)
        let loaded = try await store.loadCredential(workspaceID: credential.id)
        #expect(loaded == credential)
    }

    @Test("loadCredential throws .itemNotFound when missing")
    func loadCredentialMissing() async throws {
        let store = InMemoryKeychainStore()
        do {
            _ = try await store.loadCredential(workspaceID: "missing")
            Issue.record("expected itemNotFound")
        } catch KeychainError.itemNotFound {
            #expect(Bool(true))
        }
    }

    @Test("access token round trip and isExpired honors expiresAt")
    func accessTokenRoundTrip() async throws {
        let store = InMemoryKeychainStore()
        let token = AccessToken(
            value: "atk",
            expiresAt: Date(timeIntervalSince1970: 1_700_000_500),
            workspaceID: "ws-1"
        )
        try await store.saveAccessToken(token)
        let loaded = try await store.loadAccessToken(workspaceID: "ws-1")
        #expect(loaded.value == "atk")
        #expect(loaded.workspaceID == "ws-1")
        #expect(loaded.expiresAt == token.expiresAt)
        // Past `expiresAt` we're expired even with skew.
        let past = Date(timeIntervalSince1970: 1_700_000_499)
        #expect(loaded.isExpired(now: past, skew: 0) == false)
        #expect(loaded.isExpired(now: past, skew: 30) == true)
    }

    @Test("refresh token round trip + deleteTokens removes both")
    func refreshTokenAndDelete() async throws {
        let store = InMemoryKeychainStore()
        try await store.saveAccessToken(AccessToken(value: "a", expiresAt: .distantFuture, workspaceID: "ws-1"))
        try await store.saveRefreshToken("rtk", workspaceID: "ws-1")
        let loadedRefresh = try await store.loadRefreshToken(workspaceID: "ws-1")
        #expect(loadedRefresh == "rtk")

        try await store.deleteTokens(workspaceID: "ws-1")
        do {
            _ = try await store.loadRefreshToken(workspaceID: "ws-1")
            Issue.record("expected itemNotFound after delete")
        } catch KeychainError.itemNotFound {
            #expect(Bool(true))
        }
        do {
            _ = try await store.loadAccessToken(workspaceID: "ws-1")
            Issue.record("expected itemNotFound for access token after delete")
        } catch KeychainError.itemNotFound {
            #expect(Bool(true))
        }
    }

    @Test("workspaces index round trip; missing returns empty array")
    func workspacesIndex() async throws {
        let store = InMemoryKeychainStore()
        let initial = try await store.loadWorkspacesIndex()
        #expect(initial.isEmpty)
        try await store.saveWorkspacesIndex(["a", "b", "c"])
        let loaded = try await store.loadWorkspacesIndex()
        #expect(loaded == ["a", "b", "c"])
    }

    @Test("active workspace ID lifecycle")
    func activeWorkspaceID() async throws {
        let store = InMemoryKeychainStore()
        #expect(try await store.loadActiveWorkspaceID() == nil)
        try await store.saveActiveWorkspaceID("ws-42")
        #expect(try await store.loadActiveWorkspaceID() == "ws-42")
        try await store.clearActiveWorkspaceID()
        #expect(try await store.loadActiveWorkspaceID() == nil)
    }

    @Test("clearAll empties everything")
    func clearAll() async throws {
        let store = InMemoryKeychainStore()
        try await store.saveCredential(makeCredential())
        try await store.saveAccessToken(AccessToken(value: "a", expiresAt: .distantFuture, workspaceID: "ws-1"))
        try await store.saveRefreshToken("r", workspaceID: "ws-1")
        try await store.saveWorkspacesIndex(["ws-1"])
        try await store.saveActiveWorkspaceID("ws-1")

        let beforeCount = await store.entryCount()
        #expect(beforeCount > 0)

        try await store.clearAll()

        let afterCount = await store.entryCount()
        #expect(afterCount == 0)
    }
}
