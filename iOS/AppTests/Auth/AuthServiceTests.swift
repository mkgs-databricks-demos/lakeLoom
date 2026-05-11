import Foundation
import Testing

@testable import LakeloomApp

@Suite("AuthService")
@MainActor
struct AuthServiceTests {

    // MARK: Fixture helpers

    private static let workspaceURL = URL(string: "https://acme.cloud.databricks.com")!
    private static let clientID = "lakeloom-test-client"

    private func makeService(
        oauth: FakeOAuthClient = FakeOAuthClient(),
        keychain: InMemoryKeychainStore = InMemoryKeychainStore(),
        identity: StubDatabricksIdentityClient = StubDatabricksIdentityClient(),
        now: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> (AuthService, FakeOAuthClient, InMemoryKeychainStore, StubDatabricksIdentityClient) {
        let config = AuthConfig(clientID: Self.clientID)
        let service = AuthService(
            config: config,
            oauth: oauth,
            keychain: keychain,
            identity: identity,
            nowProvider: { now }
        )
        return (service, oauth, keychain, identity)
    }

    private func successTokens(
        accessToken: String = "atk-1",
        refreshToken: String? = "rtk-1",
        expiresIn: Int = 3600
    ) -> OAuthTokenResponse {
        OAuthTokenResponse(
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: "Bearer",
            expiresIn: expiresIn,
            scope: "all-apis offline_access"
        )
    }

    private func successMe(id: String = "user-1", userName: String = "u@example.com") -> SCIMMeResponse {
        SCIMMeResponse(
            id: id,
            userName: userName,
            displayName: "User One",
            active: true,
            emails: [.init(value: userName, primary: true)]
        )
    }

    // MARK: signIn happy path

    @Test("signIn persists credential, sets active workspace, broadcasts .signedIn")
    func signInHappyPath() async throws {
        let (service, oauth, keychain, identity) = makeService()
        oauth.enqueueAuthorization(.success(successTokens()))
        identity.enqueue(.success(successMe()))

        let presenter = TestPresentationProvider()
        let stream = await service.events
        var iterator = stream.makeAsyncIterator()
        async let firstEvent = iterator.next()

        let credential = try await service.signIn(workspaceURL: Self.workspaceURL, presenting: presenter)

        #expect(credential.user.userID == "user-1")
        #expect(credential.workspaceURL.host == "acme.cloud.databricks.com")
        let active = await service.activeWorkspace
        #expect(active?.id == credential.id)

        let storedAccess = try await keychain.loadAccessToken(workspaceID: credential.id)
        #expect(storedAccess.value == "atk-1")
        let storedRefresh = try await keychain.loadRefreshToken(workspaceID: credential.id)
        #expect(storedRefresh == "rtk-1")
        let activeStored = try await keychain.loadActiveWorkspaceID()
        #expect(activeStored == credential.id)
        let index = try await keychain.loadWorkspacesIndex()
        #expect(index == [credential.id])

        let event = await firstEvent
        if case .signedIn(let cred) = event {
            #expect(cred.id == credential.id)
        } else {
            Issue.record("expected .signedIn event")
        }
    }

    @Test("signIn surfaces .userCancelled when ASWAS is dismissed")
    func signInUserCancelled() async throws {
        let (service, oauth, _, _) = makeService()
        oauth.enqueueAuthorization(.failure(.userCancelled))
        let presenter = TestPresentationProvider()
        do {
            _ = try await service.signIn(workspaceURL: Self.workspaceURL, presenting: presenter)
            Issue.record("expected userCancelled to throw")
        } catch AuthError.userCancelled {
            #expect(Bool(true))
        }
    }

    // MARK: currentToken

    @Test("currentToken returns cached token when not near expiry")
    func currentTokenReturnsCached() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let (service, oauth, _, identity) = makeService(now: now)
        // Sign in first; token has expiresIn=3600 so it's fresh at `now`.
        oauth.enqueueAuthorization(.success(successTokens(accessToken: "fresh", expiresIn: 3600)))
        identity.enqueue(.success(successMe()))
        _ = try await service.signIn(workspaceURL: Self.workspaceURL, presenting: TestPresentationProvider())

        let token = try await service.currentToken(forceRefresh: false)
        #expect(token.value == "fresh")
        let calls = oauth.calls
        // Authorization happened; refresh did NOT.
        #expect(calls.refreshCalls.isEmpty)
    }

    @Test("currentToken with forceRefresh triggers a refresh against the token endpoint")
    func currentTokenForceRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let (service, oauth, _, identity) = makeService(now: now)
        oauth.enqueueAuthorization(.success(successTokens(accessToken: "stale", expiresIn: 3600)))
        identity.enqueue(.success(successMe()))
        _ = try await service.signIn(workspaceURL: Self.workspaceURL, presenting: TestPresentationProvider())

        oauth.enqueueRefresh(.success(successTokens(accessToken: "fresh", refreshToken: "rtk-2", expiresIn: 3600)))
        let token = try await service.currentToken(forceRefresh: true)
        #expect(token.value == "fresh")
        let calls = oauth.calls
        #expect(calls.refreshCalls.count == 1)
    }

    @Test("concurrent currentToken(forceRefresh:) calls dedupe on a single refresh")
    func currentTokenDedupesConcurrentRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let (service, oauth, _, identity) = makeService(now: now)
        oauth.enqueueAuthorization(.success(successTokens(accessToken: "stale", expiresIn: 3600)))
        identity.enqueue(.success(successMe()))
        _ = try await service.signIn(workspaceURL: Self.workspaceURL, presenting: TestPresentationProvider())

        // Only one refresh outcome — if dedup fails the second call would
        // throw because no second outcome is enqueued.
        oauth.enqueueRefresh(.success(successTokens(accessToken: "fresh", expiresIn: 3600)))

        async let a = service.currentToken(forceRefresh: true)
        async let b = service.currentToken(forceRefresh: true)
        let (tokenA, tokenB) = try await (a, b)
        #expect(tokenA.value == "fresh")
        #expect(tokenB.value == "fresh")
        let calls = oauth.calls
        #expect(calls.refreshCalls.count == 1)
    }

    @Test("invalid_grant on refresh clears tokens but keeps credential")
    func invalidGrantClearsTokensKeepsCredential() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let (service, oauth, keychain, identity) = makeService(now: now)
        oauth.enqueueAuthorization(.success(successTokens(accessToken: "stale", expiresIn: 30)))
        identity.enqueue(.success(successMe()))
        let credential = try await service.signIn(workspaceURL: Self.workspaceURL, presenting: TestPresentationProvider())

        oauth.enqueueRefresh(.failure(.invalidGrant))
        do {
            _ = try await service.currentToken(forceRefresh: true)
            Issue.record("expected refreshFailed")
        } catch AuthError.refreshFailed {
            #expect(Bool(true))
        }

        // Credential record should still be loadable.
        let stillThere = try await keychain.loadCredential(workspaceID: credential.id)
        #expect(stillThere.id == credential.id)
        // But tokens are gone.
        do {
            _ = try await keychain.loadAccessToken(workspaceID: credential.id)
            Issue.record("expected access token to be cleared")
        } catch KeychainError.itemNotFound {
            #expect(Bool(true))
        }
        do {
            _ = try await keychain.loadRefreshToken(workspaceID: credential.id)
            Issue.record("expected refresh token to be cleared")
        } catch KeychainError.itemNotFound {
            #expect(Bool(true))
        }
    }

    // MARK: signOut

    @Test("signOut of active workspace promotes the next available")
    func signOutPromotesNextWorkspace() async throws {
        let (service, oauth, keychain, identity) = makeService()
        // Sign in two workspaces.
        oauth.enqueueAuthorization(.success(successTokens(accessToken: "a")))
        identity.enqueue(.success(successMe(id: "u-a", userName: "a@a.com")))
        let first = try await service.signIn(
            workspaceURL: URL(string: "https://acme-a.cloud.databricks.com")!,
            presenting: TestPresentationProvider()
        )

        oauth.enqueueAuthorization(.success(successTokens(accessToken: "b")))
        identity.enqueue(.success(successMe(id: "u-b", userName: "b@b.com")))
        let second = try await service.signIn(
            workspaceURL: URL(string: "https://acme-b.cloud.databricks.com")!,
            presenting: TestPresentationProvider()
        )

        let activeBefore = await service.activeWorkspace
        #expect(activeBefore?.id == second.id)

        try await service.signOut(workspaceID: second.id)
        let activeAfter = await service.activeWorkspace
        #expect(activeAfter?.id == first.id)
        let stored = try await keychain.loadActiveWorkspaceID()
        #expect(stored == first.id)
    }

    @Test("signOut of last workspace clears active selection")
    func signOutLastWorkspaceClearsActive() async throws {
        let (service, oauth, keychain, identity) = makeService()
        oauth.enqueueAuthorization(.success(successTokens()))
        identity.enqueue(.success(successMe()))
        let credential = try await service.signIn(workspaceURL: Self.workspaceURL, presenting: TestPresentationProvider())
        try await service.signOut(workspaceID: credential.id)
        let active = await service.activeWorkspace
        #expect(active == nil)
        let stored = try await keychain.loadActiveWorkspaceID()
        #expect(stored == nil)
    }

    // MARK: switchWorkspace

    @Test("switchWorkspace updates active and broadcasts .switchedWorkspace")
    func switchWorkspaceBroadcasts() async throws {
        let (service, oauth, _, identity) = makeService()
        oauth.enqueueAuthorization(.success(successTokens()))
        identity.enqueue(.success(successMe(id: "u-a")))
        let first = try await service.signIn(
            workspaceURL: URL(string: "https://acme-a.cloud.databricks.com")!,
            presenting: TestPresentationProvider()
        )
        oauth.enqueueAuthorization(.success(successTokens()))
        identity.enqueue(.success(successMe(id: "u-b")))
        let second = try await service.signIn(
            workspaceURL: URL(string: "https://acme-b.cloud.databricks.com")!,
            presenting: TestPresentationProvider()
        )

        try await service.switchWorkspace(to: first.id)
        let active = await service.activeWorkspace
        #expect(active?.id == first.id)
        // Round-trip: switch back.
        try await service.switchWorkspace(to: second.id)
        let active2 = await service.activeWorkspace
        #expect(active2?.id == second.id)
    }

    @Test("switchWorkspace throws .unknownWorkspace for an unsigned-in id")
    func switchUnknownWorkspaceFails() async throws {
        let (service, _, _, _) = makeService()
        do {
            try await service.switchWorkspace(to: "nonexistent")
            Issue.record("expected unknownWorkspace")
        } catch AuthError.unknownWorkspace(let id) {
            #expect(id == "nonexistent")
        }
    }

    // MARK: validateWorkspaceURL

    @Test("validateWorkspaceURL succeeds when discovery succeeds")
    func validateOK() async throws {
        let (service, _, _, _) = makeService()
        try await service.validateWorkspaceURL(Self.workspaceURL)
    }

    @Test("validateWorkspaceURL maps discovery failure to invalidWorkspaceURL")
    func validateFails() async throws {
        let (service, oauth, _, _) = makeService()
        oauth.setDiscoveryOutcome(.failure(.discoveryFailed(reason: "404 not found")))
        do {
            try await service.validateWorkspaceURL(Self.workspaceURL)
            Issue.record("expected invalidWorkspaceURL")
        } catch AuthError.invalidWorkspaceURL {
            #expect(Bool(true))
        }
    }

    // MARK: normalize

    @Test("normalize strips path / query / fragment, keeps https + host")
    func normalizeStripsPath() throws {
        let messy = URL(string: "https://Acme.cloud.databricks.com/some/path?x=1#frag")!
        let normalized = try AuthService.normalize(workspaceURL: messy)
        #expect(normalized.scheme == "https")
        #expect(normalized.host == "Acme.cloud.databricks.com")
        #expect(normalized.path.isEmpty)
        #expect(normalized.query == nil)
        #expect(normalized.fragment == nil)
    }

    @Test("normalize throws for URL without a host")
    func normalizeRejectsHostless() {
        let bad = URL(string: "https:///oauth/callback")!
        do {
            _ = try AuthService.normalize(workspaceURL: bad)
            Issue.record("expected invalidWorkspaceURL")
        } catch AuthError.invalidWorkspaceURL {
            #expect(Bool(true))
        } catch {
            Issue.record("expected AuthError.invalidWorkspaceURL, got \(error)")
        }
    }

    // MARK: derivedCloud

    @Test("derivedCloud detects azure, gcp, and defaults to aws")
    func derivedCloud() {
        let azure = URL(string: "https://acme.azuredatabricks.net")!
        let gcp = URL(string: "https://acme.gcp.databricks.com")!
        let aws = URL(string: "https://acme.cloud.databricks.com")!
        #expect(AuthService.derivedCloud(from: azure) == .azure)
        #expect(AuthService.derivedCloud(from: gcp) == .gcp)
        #expect(AuthService.derivedCloud(from: aws) == .aws)
    }
}
