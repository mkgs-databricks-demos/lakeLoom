import AuthenticationServices
import Foundation

/// Configuration baked into the app binary.
///
/// `clientID` is the published Databricks OAuth client ID. PKCE replaces
/// the client_secret; `clientID` is not a secret. `redirectURI` matches
/// the URL scheme registered in `Info.plist` (Module 01 §11.1).
public struct AuthConfig: Sendable {
    public let clientID: String
    public let redirectURI: URL
    public let scopes: [String]

    public init(clientID: String, redirectURI: URL, scopes: [String] = ["all-apis", "offline_access"]) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
    }
}

/// Production ``AuthServicing`` actor.
///
/// All mutable state — workspaces, active workspace ID, in-flight refresh
/// tasks — is actor-isolated. Public methods serialize through the actor
/// executor. The OAuth interactive flow is the only `@MainActor` part;
/// it hops back into the actor for persistence.
///
/// See Module 01 §4 (concurrency model) and §6 (refresh flow).
public actor AuthService: AuthServicing {

    // MARK: Dependencies

    private let config: AuthConfig
    private let oauth: OAuthClient
    private let keychain: KeychainStore
    private let identity: DatabricksIdentityClient
    private let nowProvider: @Sendable () -> Date
    private let logger: AppLogger

    // MARK: State

    /// Cached workspace metadata. Mirrors what's persisted in Keychain so
    /// callers get sync semantics through the actor executor without an
    /// I/O hop on every read. Refreshed on sign-in / sign-out / switch.
    private var workspacesCache: [WorkspaceCredential] = []

    /// Active workspace ID. nil before first sign-in.
    private var activeWorkspaceID: String?

    /// Per-workspace in-flight refresh task. Concurrent callers awaiting
    /// the same refresh share the result instead of triggering N parallel
    /// network calls.
    private var refreshTasks: [String: Task<AccessToken, any Error>] = [:]

    /// Counters surfaced via ``diagnostics()``.
    private var diagnosticsState = AuthDiagnostics.zero

    /// Multicast event continuations. ``events`` returns a fresh stream
    /// per subscriber, all backed by the actor's own event broadcast.
    private var eventContinuations: [UUID: AsyncStream<AuthEvent>.Continuation] = [:]

    /// Tracks whether `start()` has run so it's idempotent.
    private var started = false

    // MARK: Init

    public init(
        config: AuthConfig,
        oauth: OAuthClient,
        keychain: KeychainStore,
        identity: DatabricksIdentityClient,
        logger: AppLogger = AppLogger(category: .auth),
        nowProvider: @Sendable @escaping () -> Date = Date.init
    ) {
        self.config = config
        self.oauth = oauth
        self.keychain = keychain
        self.identity = identity
        self.logger = logger
        self.nowProvider = nowProvider
    }

    // MARK: Lifecycle

    /// Loads persisted workspaces and active selection from Keychain.
    /// Idempotent. Call once at app launch from AppCoordinator's bootstrap.
    public func start() async {
        guard !started else { return }
        started = true
        do {
            let ids = try await keychain.loadWorkspacesIndex()
            var loaded: [WorkspaceCredential] = []
            for id in ids {
                do {
                    let credential = try await keychain.loadCredential(workspaceID: id)
                    loaded.append(credential)
                } catch {
                    await logger.warning(
                        "dropping unreadable credential",
                        metadata: [
                            "workspace_id": .uuidPrefix(id),
                            "reason": .errorCode(String(describing: type(of: error)))
                        ]
                    )
                }
            }
            workspacesCache = loaded
            activeWorkspaceID = try await keychain.loadActiveWorkspaceID()
            // If the cached active ID points at a workspace we couldn't load,
            // promote the first available workspace (or clear).
            if let active = activeWorkspaceID, !workspacesCache.contains(where: { $0.id == active }) {
                if let next = workspacesCache.first {
                    activeWorkspaceID = next.id
                    try? await keychain.saveActiveWorkspaceID(next.id)
                } else {
                    activeWorkspaceID = nil
                    try? await keychain.clearActiveWorkspaceID()
                }
            }
        } catch {
            await logger.error(
                "failed to load persisted state",
                metadata: ["reason": .errorCode(String(describing: type(of: error)))]
            )
        }
    }

    // MARK: Public surface

    public var workspaces: [WorkspaceCredential] {
        workspacesCache
    }

    public var activeWorkspace: WorkspaceCredential? {
        guard let id = activeWorkspaceID else { return nil }
        return workspacesCache.first(where: { $0.id == id })
    }

    public var events: AsyncStream<AuthEvent> {
        get async {
            let (stream, continuation) = AsyncStream<AuthEvent>.makeStream()
            let id = UUID()
            // Synchronous registration: by the time `await service.events`
            // returns the subscriber is already in the broadcast set, so
            // immediately-following events reach this subscriber.
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.unsubscribe(id: id) }
            }
            return stream
        }
    }

    public func currentToken(forceRefresh: Bool) async throws -> AccessToken {
        guard let workspaceID = activeWorkspaceID else {
            throw AuthError.noActiveWorkspace
        }

        if let inflight = refreshTasks[workspaceID] {
            do {
                return try await inflight.value
            } catch {
                throw mapAuthError(error)
            }
        }

        // Fast path: cached token is fresh and forceRefresh wasn't requested.
        if !forceRefresh {
            do {
                let stored = try await keychain.loadAccessToken(workspaceID: workspaceID)
                if !stored.isExpired(now: nowProvider()) {
                    return stored
                }
            } catch KeychainError.itemNotFound {
                // Fall through to refresh.
            } catch {
                throw mapAuthError(error)
            }
        }

        // Slow path: dedup-on-workspace-id refresh task.
        let task = Task<AccessToken, any Error> { [self] in
            try await performRefresh(workspaceID: workspaceID)
        }
        refreshTasks[workspaceID] = task
        defer { refreshTasks[workspaceID] = nil }
        do {
            return try await task.value
        } catch {
            throw mapAuthError(error)
        }
    }

    @MainActor
    public func signIn(
        workspaceURL: URL,
        presenting: ASWebAuthenticationPresentationContextProviding
    ) async throws -> WorkspaceCredential {
        let normalizedURL: URL
        do {
            normalizedURL = try Self.normalize(workspaceURL: workspaceURL)
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.invalidWorkspaceURL(workspaceURL.absoluteString)
        }

        await self.recordSignInAttempt()

        let tokens: OAuthTokenResponse
        do {
            tokens = try await oauth.performAuthorizationCodeFlow(
                workspaceURL: normalizedURL,
                clientID: config.clientID,
                redirectURI: config.redirectURI,
                scopes: config.scopes,
                presenting: presenting
            )
        } catch let error as OAuthError {
            await self.recordSignInOutcome(error: error)
            throw mapAuthError(error)
        } catch {
            await self.recordSignInOutcome(error: nil)
            throw AuthError.oauthFailed(reason: error.localizedDescription)
        }

        // Fetch identity using the freshly-issued bearer.
        let me: SCIMMeResponse
        do {
            me = try await identity.fetchMe(workspaceURL: normalizedURL, bearerToken: tokens.accessToken)
        } catch let error as IdentityClientError {
            await self.recordSignInOutcome(error: nil)
            throw mapAuthError(error)
        } catch {
            await self.recordSignInOutcome(error: nil)
            throw AuthError.identityFetchFailed(reason: error.localizedDescription)
        }

        // Hop into actor isolation to persist + activate.
        let credential = try await self.persistNewSignIn(
            normalizedURL: normalizedURL,
            user: me.toUserIdentity(),
            tokens: tokens
        )
        return credential
    }

    public func validateWorkspaceURL(_ workspaceURL: URL) async throws {
        let normalized: URL
        do {
            normalized = try Self.normalize(workspaceURL: workspaceURL)
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.invalidWorkspaceURL(workspaceURL.absoluteString)
        }
        do {
            _ = try await oauth.discoverEndpoints(workspaceURL: normalized)
        } catch let error as OAuthError {
            throw mapAuthError(error)
        } catch {
            throw AuthError.invalidWorkspaceURL(workspaceURL.absoluteString)
        }
    }

    public func switchWorkspace(to workspaceID: String) async throws {
        guard workspacesCache.contains(where: { $0.id == workspaceID }) else {
            throw AuthError.unknownWorkspace(workspaceID)
        }
        activeWorkspaceID = workspaceID
        try await keychain.saveActiveWorkspaceID(workspaceID)
        if let credential = workspacesCache.first(where: { $0.id == workspaceID }) {
            broadcast(.switchedWorkspace(credential))
        }
    }

    public func signOut(workspaceID: String) async throws {
        try await keychain.deleteCredential(workspaceID: workspaceID)
        try await keychain.deleteTokens(workspaceID: workspaceID)
        workspacesCache.removeAll { $0.id == workspaceID }
        try await keychain.saveWorkspacesIndex(workspacesCache.map(\.id))

        if activeWorkspaceID == workspaceID {
            if let next = workspacesCache.first {
                activeWorkspaceID = next.id
                try await keychain.saveActiveWorkspaceID(next.id)
            } else {
                activeWorkspaceID = nil
                try await keychain.clearActiveWorkspaceID()
            }
        }
        broadcast(.signedOut(workspaceID: workspaceID))
    }

    public func signOutAll() async throws {
        let ids = workspacesCache.map(\.id)
        for id in ids {
            try await signOut(workspaceID: id)
        }
        try await keychain.clearAll()
    }

    public func refreshIdentity() async throws -> UserIdentity {
        guard let active = activeWorkspace else {
            throw AuthError.noActiveWorkspace
        }
        let token = try await currentToken(forceRefresh: false)
        let me: SCIMMeResponse
        do {
            me = try await identity.fetchMe(workspaceURL: active.workspaceURL, bearerToken: token.value)
        } catch let error as IdentityClientError {
            throw mapAuthError(error)
        } catch {
            throw AuthError.identityFetchFailed(reason: error.localizedDescription)
        }
        let user = me.toUserIdentity()
        let updated = WorkspaceCredential(
            id: active.id,
            workspaceURL: active.workspaceURL,
            workspaceName: active.workspaceName,
            cloud: active.cloud,
            region: active.region,
            user: user,
            isDefault: active.isDefault,
            signedInAt: active.signedInAt,
            identityRefreshedAt: nowProvider()
        )
        try await keychain.saveCredential(updated)
        if let index = workspacesCache.firstIndex(where: { $0.id == active.id }) {
            workspacesCache[index] = updated
        }
        broadcast(.identityRefreshed(updated))
        return user
    }

    /// Snapshot of the diagnostic counters.
    public func diagnostics() async -> AuthDiagnostics {
        diagnosticsState
    }

    // MARK: - Private

    private func unsubscribe(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func broadcast(_ event: AuthEvent) {
        for cont in eventContinuations.values {
            cont.yield(event)
        }
    }

    private func recordSignInAttempt() {
        diagnosticsState = AuthDiagnostics(
            signInsAttempted: diagnosticsState.signInsAttempted + 1,
            signInsSucceeded: diagnosticsState.signInsSucceeded,
            signInsCancelled: diagnosticsState.signInsCancelled,
            signInsFailed: diagnosticsState.signInsFailed,
            refreshesAttempted: diagnosticsState.refreshesAttempted,
            refreshesSucceeded: diagnosticsState.refreshesSucceeded,
            refreshesFailed: diagnosticsState.refreshesFailed,
            lastSuccessfulRefreshAt: diagnosticsState.lastSuccessfulRefreshAt,
            lastRefreshFailureAt: diagnosticsState.lastRefreshFailureAt,
            perWorkspaceRefreshFailures: diagnosticsState.perWorkspaceRefreshFailures
        )
    }

    private func recordSignInOutcome(error: OAuthError?) {
        let cancelledDelta = error == .userCancelled ? 1 : 0
        let failedDelta = error.map { $0 == .userCancelled ? 0 : 1 } ?? 0
        let succeededDelta = error == nil ? 1 : 0
        diagnosticsState = AuthDiagnostics(
            signInsAttempted: diagnosticsState.signInsAttempted,
            signInsSucceeded: diagnosticsState.signInsSucceeded + succeededDelta,
            signInsCancelled: diagnosticsState.signInsCancelled + cancelledDelta,
            signInsFailed: diagnosticsState.signInsFailed + failedDelta,
            refreshesAttempted: diagnosticsState.refreshesAttempted,
            refreshesSucceeded: diagnosticsState.refreshesSucceeded,
            refreshesFailed: diagnosticsState.refreshesFailed,
            lastSuccessfulRefreshAt: diagnosticsState.lastSuccessfulRefreshAt,
            lastRefreshFailureAt: diagnosticsState.lastRefreshFailureAt,
            perWorkspaceRefreshFailures: diagnosticsState.perWorkspaceRefreshFailures
        )
    }

    private func recordRefreshOutcome(workspaceID: String, success: Bool) {
        if success {
            diagnosticsState = AuthDiagnostics(
                signInsAttempted: diagnosticsState.signInsAttempted,
                signInsSucceeded: diagnosticsState.signInsSucceeded,
                signInsCancelled: diagnosticsState.signInsCancelled,
                signInsFailed: diagnosticsState.signInsFailed,
                refreshesAttempted: diagnosticsState.refreshesAttempted + 1,
                refreshesSucceeded: diagnosticsState.refreshesSucceeded + 1,
                refreshesFailed: diagnosticsState.refreshesFailed,
                lastSuccessfulRefreshAt: nowProvider(),
                lastRefreshFailureAt: diagnosticsState.lastRefreshFailureAt,
                perWorkspaceRefreshFailures: diagnosticsState.perWorkspaceRefreshFailures
            )
        } else {
            var failures = diagnosticsState.perWorkspaceRefreshFailures
            failures[workspaceID, default: 0] += 1
            diagnosticsState = AuthDiagnostics(
                signInsAttempted: diagnosticsState.signInsAttempted,
                signInsSucceeded: diagnosticsState.signInsSucceeded,
                signInsCancelled: diagnosticsState.signInsCancelled,
                signInsFailed: diagnosticsState.signInsFailed,
                refreshesAttempted: diagnosticsState.refreshesAttempted + 1,
                refreshesSucceeded: diagnosticsState.refreshesSucceeded,
                refreshesFailed: diagnosticsState.refreshesFailed + 1,
                lastSuccessfulRefreshAt: diagnosticsState.lastSuccessfulRefreshAt,
                lastRefreshFailureAt: nowProvider(),
                perWorkspaceRefreshFailures: failures
            )
        }
    }

    private func persistNewSignIn(
        normalizedURL: URL,
        user: UserIdentity,
        tokens: OAuthTokenResponse
    ) async throws -> WorkspaceCredential {
        let workspaceID = Self.derivedWorkspaceID(from: normalizedURL)
        let now = nowProvider()
        let credential = WorkspaceCredential(
            id: workspaceID,
            workspaceURL: normalizedURL,
            workspaceName: Self.derivedWorkspaceName(from: normalizedURL),
            cloud: Self.derivedCloud(from: normalizedURL),
            region: nil,
            user: user,
            isDefault: workspacesCache.isEmpty,
            signedInAt: now,
            identityRefreshedAt: now
        )
        let accessToken = AccessToken(
            value: tokens.accessToken,
            expiresAt: now.addingTimeInterval(TimeInterval(max(tokens.expiresIn - 60, 60))),
            workspaceID: workspaceID
        )

        try await keychain.saveCredential(credential)
        try await keychain.saveAccessToken(accessToken)
        if let refreshToken = tokens.refreshToken {
            try await keychain.saveRefreshToken(refreshToken, workspaceID: workspaceID)
        }
        // Update the workspaces index in a stable order: existing then new.
        if let index = workspacesCache.firstIndex(where: { $0.id == workspaceID }) {
            workspacesCache[index] = credential
        } else {
            workspacesCache.append(credential)
        }
        try await keychain.saveWorkspacesIndex(workspacesCache.map(\.id))
        activeWorkspaceID = workspaceID
        try await keychain.saveActiveWorkspaceID(workspaceID)

        recordSignInOutcome(error: nil)
        broadcast(.signedIn(credential))
        return credential
    }

    private func performRefresh(workspaceID: String) async throws -> AccessToken {
        let credential = try await keychain.loadCredential(workspaceID: workspaceID)
        let refreshToken = try await keychain.loadRefreshToken(workspaceID: workspaceID)
        let response: OAuthTokenResponse
        do {
            response = try await oauth.refreshTokens(
                workspaceURL: credential.workspaceURL,
                clientID: config.clientID,
                refreshToken: refreshToken
            )
        } catch let error as OAuthError {
            recordRefreshOutcome(workspaceID: workspaceID, success: false)
            if error.isInvalidGrant {
                // Clear tokens but keep the credential record so the UI can
                // surface "Re-login required" without losing the workspace.
                try? await keychain.deleteTokens(workspaceID: workspaceID)
            }
            throw error
        } catch {
            recordRefreshOutcome(workspaceID: workspaceID, success: false)
            throw error
        }
        let now = nowProvider()
        let access = AccessToken(
            value: response.accessToken,
            expiresAt: now.addingTimeInterval(TimeInterval(max(response.expiresIn - 60, 60))),
            workspaceID: workspaceID
        )
        try await keychain.saveAccessToken(access)
        if let newRefresh = response.refreshToken {
            try await keychain.saveRefreshToken(newRefresh, workspaceID: workspaceID)
        }
        recordRefreshOutcome(workspaceID: workspaceID, success: true)
        return access
    }

    // MARK: - Pure helpers

    static func normalize(workspaceURL: URL) throws -> URL {
        guard
            let host = workspaceURL.host,
            !host.isEmpty
        else {
            throw AuthError.invalidWorkspaceURL(workspaceURL.absoluteString)
        }
        // Build a clean https://<host> URL with no path / query / fragment.
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        guard let url = components.url else {
            throw AuthError.invalidWorkspaceURL(workspaceURL.absoluteString)
        }
        return url
    }

    static func derivedWorkspaceID(from url: URL) -> String {
        // Until SCIM `meta.location` parsing is wired up (Module 01 §5.7 open
        // item), use the host as a stable opaque identifier. The bronze table
        // accepts whatever string we send.
        url.host ?? url.absoluteString
    }

    static func derivedWorkspaceName(from url: URL) -> String {
        url.host ?? url.absoluteString
    }

    static func derivedCloud(from url: URL) -> Cloud {
        guard let host = url.host?.lowercased() else { return .unknown }
        if host.contains("azuredatabricks") { return .azure }
        if host.contains("gcp") { return .gcp }
        return .aws
    }

    nonisolated private func mapAuthError(_ error: any Error) -> AuthError {
        if let authError = error as? AuthError { return authError }
        if let oauthError = error as? OAuthError {
            switch oauthError {
            case .userCancelled: return .userCancelled
            case .invalidGrant: return .refreshFailed(reason: "refresh_token expired or revoked; re-login required")
            case .networkUnavailable: return .networkUnavailable
            case .timeout: return .oauthFailed(reason: "timeout")
            case .stateMismatch: return .oauthFailed(reason: "state mismatch")
            case .invalidWorkspaceURL(let reason): return .invalidWorkspaceURL(reason)
            case .discoveryFailed(let reason): return .invalidWorkspaceURL(reason)
            case .authorizationFailed(let reason),
                 .tokenExchangeFailed(let reason),
                 .unexpectedResponse(let reason):
                return .oauthFailed(reason: reason)
            case .unauthorizedClient: return .oauthFailed(reason: "unauthorized_client")
            case .randomGenerationFailed(let status): return .keychainFailed(status)
            }
        }
        if let identityError = error as? IdentityClientError {
            switch identityError {
            case .unauthorized: return .refreshFailed(reason: "identity 401 — re-login required")
            case .forbidden: return .identityFetchFailed(reason: "forbidden")
            case .networkUnavailable: return .networkUnavailable
            case .timeout: return .identityFetchFailed(reason: "timeout")
            case .serverUnavailable(let status): return .identityFetchFailed(reason: "HTTP \(status)")
            case .decodeFailed(let reason): return .identityFetchFailed(reason: reason)
            case .transport(let reason): return .identityFetchFailed(reason: reason)
            case .unexpectedResponse(let reason): return .identityFetchFailed(reason: reason)
            }
        }
        if let keychainError = error as? KeychainError {
            switch keychainError {
            case .osStatus(let status):
                return .keychainFailed(status)
            case .unsupportedSchemaVersion(let found, let supported):
                return .unexpectedResponse(reason: "keychain schema v\(found), expected v\(supported)")
            case .itemNotFound:
                return .refreshFailed(reason: "credential or token not found")
            case .decodeFailed(let reason), .encodeFailed(let reason):
                return .unexpectedResponse(reason: reason)
            }
        }
        return .unexpectedResponse(reason: error.localizedDescription)
    }
}
