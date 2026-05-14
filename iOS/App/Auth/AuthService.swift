import Foundation

/// Production ``AuthServicing`` actor.
///
/// All mutable state — workspaces, active workspace ID, diagnostics —
/// is actor-isolated. Public methods serialize through the actor
/// executor.
///
/// Token logic lives in ``LakeloomAppClient`` (Layer 0 M2M cache +
/// near-expiry refresh); AuthService is the coordinator that wires
/// the QR-pair flow, persistence, and event broadcast.
public actor AuthService: AuthServicing {

    // MARK: Dependencies

    private let lakeloomApp: any LakeloomAppClient
    private let deviceKeyStore: any DeviceKeyStoring
    private let keychain: KeychainStore
    private let nowProvider: @Sendable () -> Date
    private let logger: AppLogger

    // MARK: State

    /// Cached workspace metadata. Mirrors what's persisted in Keychain
    /// so callers get sync semantics through the actor executor.
    /// Refreshed on sign-in / sign-out / switch.
    private var workspacesCache: [WorkspaceCredential] = []

    /// Active workspace ID. Nil before first pairing.
    private var activeWorkspaceID: String?

    /// Counters surfaced via ``diagnostics()``.
    private var diagnosticsState = AuthDiagnostics.zero

    /// Multicast event continuations. ``events`` returns a fresh stream
    /// per subscriber, all backed by the actor's own event broadcast.
    private var eventContinuations: [UUID: AsyncStream<AuthEvent>.Continuation] = [:]

    /// Tracks whether `start()` has run so it's idempotent.
    private var started = false

    // MARK: Init

    public init(
        lakeloomApp: any LakeloomAppClient,
        deviceKeyStore: any DeviceKeyStoring,
        keychain: KeychainStore,
        logger: AppLogger = AppLogger(category: .auth),
        nowProvider: @Sendable @escaping () -> Date = Date.init
    ) {
        self.lakeloomApp = lakeloomApp
        self.deviceKeyStore = deviceKeyStore
        self.keychain = keychain
        self.logger = logger
        self.nowProvider = nowProvider
    }

    // MARK: Lifecycle

    /// Loads persisted workspaces and re-configures ``LakeloomAppClient``
    /// for each one. Idempotent. Called by AppCoordinator's bootstrap.
    public func start() async {
        guard !started else { return }
        started = true

        let ids: [String]
        do {
            ids = try await keychain.loadWorkspacesIndex()
        } catch {
            await logger.error(
                "auth.start.index_load_failed",
                metadata: ["reason": .errorCode(String(describing: type(of: error)))]
            )
            return
        }

        var loaded: [WorkspaceCredential] = []
        for id in ids {
            do {
                let credential = try await keychain.loadCredential(workspaceID: id)
                let session = try await keychain.loadSessionToken(workspaceID: id)
                let xcodeSPN = try await keychain.loadXcodeSPNCredentials(workspaceID: id)
                await lakeloomApp.configure(
                    workspaceID: id,
                    config: LakeloomAppClientConfig(
                        workspaceURL: credential.workspaceURL,
                        appBaseURL: credential.appBaseURL,
                        xcodeSPN: xcodeSPN,
                        sessionToken: session
                    )
                )
                loaded.append(credential)
            } catch {
                await logger.warning(
                    "auth.start.dropping_unreadable_credential",
                    metadata: [
                        "workspace_id": .uuidPrefix(id),
                        "reason": .errorCode(String(describing: type(of: error)))
                    ]
                )
            }
        }
        workspacesCache = loaded

        do {
            activeWorkspaceID = try await keychain.loadActiveWorkspaceID()
        } catch {
            activeWorkspaceID = nil
        }
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
            // returns the subscriber is already in the broadcast set.
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
        // `forceRefresh` is preserved for the protocol contract, but the
        // M2M cache inside LakeloomAppClient transparently re-acquires
        // on near-expiry — we never need to bypass it.
        _ = forceRefresh
        let bearer: String
        do {
            bearer = try await lakeloomApp.currentBearer(workspaceID: workspaceID)
        } catch let error as LakeloomAppError {
            throw mapAuthError(error)
        } catch {
            throw AuthError.unexpectedResponse(reason: error.localizedDescription)
        }
        // We don't have a server-supplied exact expiry on this path —
        // LakeloomAppClient holds it internally for its caching needs.
        // Callers of `currentToken()` only need the value + workspaceID;
        // the AccessToken `expiresAt` field is informational, so we
        // synthesize a near-term "good for at least 60s" expiry.
        return AccessToken(
            value: bearer,
            expiresAt: nowProvider().addingTimeInterval(60),
            workspaceID: workspaceID
        )
    }

    public func signInViaPairing(
        qrText: String,
        deviceLabel: String
    ) async throws -> WorkspaceCredential {
        await logger.info("signin.start", metadata: ["device_label": .redacted(label: "device_label")])
        recordSignInAttempt()

        // Best-effort: log this device's outbound public IP so the
        // user can configure the workspace IP allowlist that gates
        // the Databricks App. Doesn't block sign-in if the lookup
        // fails (no network, ipify down, etc.). Runs concurrently
        // with the rest of the flow.
        Task.detached { [logger] in
            await Self.logPublicIP(logger: logger)
        }

        // 1. Decode QR payload.
        let payload: PairingPayload
        do {
            payload = try PairingPayload.decode(from: qrText)
        } catch let error as PairingPayload.DecodingError {
            recordSignInOutcome(error: AuthError.invalidPairingPayload(reason: String(describing: error)))
            await logger.error(
                "signin.qr_decode_failed",
                metadata: ["reason": .string(String(describing: error))],
                errorCode: "invalid_pairing_payload"
            )
            throw AuthError.invalidPairingPayload(reason: String(describing: error))
        } catch {
            recordSignInOutcome(error: nil)
            throw AuthError.invalidPairingPayload(reason: error.localizedDescription)
        }
        await logger.info(
            "signin.qr_decoded",
            metadata: [
                "workspace_host": .string(payload.workspace.url.host ?? "<no-host>"),
                "user": .redacted(label: "scim_id"),
                // Same prefix shape as M2MTokenClient's m2m.token.attempt
                // — visually compare these two log lines to confirm the
                // QR-delivered client_id is what's exchanged for the
                // M2M token. Both should match the workspace UI's
                // Xcode SPN application_id.
                "xcode_client_id_prefix": .string(String(payload.xcodeSPN.clientID.prefix(12)))
            ]
        )

        // 2. Generate / load device pubkey (Secure Enclave).
        let devicePubKeyDER: Data
        do {
            devicePubKeyDER = try await deviceKeyStore.publicKeyDER()
        } catch let error as DeviceKeyStoreError {
            recordSignInOutcome(error: nil)
            await logger.error(
                "signin.device_key_failed",
                metadata: ["reason": .string(String(describing: error))],
                errorCode: "device_key_failed"
            )
            throw AuthError.deviceKeyFailed(reason: String(describing: error))
        } catch {
            recordSignInOutcome(error: nil)
            throw AuthError.deviceKeyFailed(reason: error.localizedDescription)
        }

        // 3. Configure LakeloomAppClient for this workspace so the
        // /api/pairing/confirm call (and all future calls) can sign +
        // mint M2M against the new payload.
        let workspaceID = Self.derivedWorkspaceID(from: payload.workspace.url)
        await lakeloomApp.configure(
            workspaceID: workspaceID,
            config: LakeloomAppClientConfig(
                workspaceURL: payload.workspace.url,
                appBaseURL: payload.app.baseURL,
                xcodeSPN: XcodeSPNCredentials(payload.xcodeSPN),
                sessionToken: payload.session.token
            )
        )

        // 4. POST /api/pairing/confirm.
        struct ConfirmRequest: Encodable {
            let device_pubkey: String
            let device_label: String
        }
        struct ConfirmResponse: Decodable {
            let paired_session_id: String
            let paired_at: Date?
            let expires_at: Date?
        }
        let bodyData: Data
        do {
            let encoder = JSONEncoder()
            bodyData = try encoder.encode(ConfirmRequest(
                device_pubkey: devicePubKeyDER.base64URLEncodedString(),
                device_label: deviceLabel
            ))
        } catch {
            recordSignInOutcome(error: nil)
            throw AuthError.unexpectedResponse(reason: "could not encode confirm body: \(error)")
        }

        let response: ConfirmResponse
        do {
            response = try await lakeloomApp.request(
                workspaceID: workspaceID,
                method: .post,
                path: "/api/pairing/confirm",
                body: bodyData,
                decode: ConfirmResponse.self
            )
        } catch let error as LakeloomAppError {
            await lakeloomApp.removeConfiguration(workspaceID: workspaceID)
            recordSignInOutcome(error: nil)
            await logger.error(
                "signin.confirm_failed",
                metadata: ["reason": .string(String(describing: error))],
                errorCode: "pairing_failed"
            )
            throw mapAuthError(error)
        } catch {
            await lakeloomApp.removeConfiguration(workspaceID: workspaceID)
            recordSignInOutcome(error: nil)
            throw AuthError.pairingFailed(reason: error.localizedDescription)
        }
        await logger.info(
            "signin.confirm_ok",
            metadata: ["paired_session_id": .uuidPrefix(response.paired_session_id)]
        )

        // 5. Persist to Keychain and broadcast.
        let credential = try await persistPairing(
            payload: payload,
            pairedSessionID: response.paired_session_id,
            workspaceID: workspaceID
        )

        recordSignInOutcome(error: nil)
        broadcast(.signedIn(credential))
        await logger.info(
            "signin.persisted",
            metadata: ["workspace_id": .uuidPrefix(credential.id)]
        )
        return credential
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
        await lakeloomApp.removeConfiguration(workspaceID: workspaceID)

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

    private func recordSignInOutcome(error: AuthError?) {
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

    private func persistPairing(
        payload: PairingPayload,
        pairedSessionID: String,
        workspaceID: String
    ) async throws -> WorkspaceCredential {
        let now = nowProvider()
        let identity = UserIdentity(
            userID: payload.user.scimID,
            userName: payload.user.userName,
            displayName: payload.user.displayName,
            email: payload.user.userName.contains("@") ? payload.user.userName : nil,
            active: true
        )
        let credential = WorkspaceCredential(
            id: workspaceID,
            workspaceURL: payload.workspace.url,
            workspaceName: payload.workspace.name,
            cloud: payload.workspace.cloudCase,
            region: nil,
            user: identity,
            isDefault: workspacesCache.isEmpty,
            signedInAt: now,
            identityRefreshedAt: now,
            appBaseURL: payload.app.baseURL,
            authMethod: .qrPaired(
                pairedSessionID: pairedSessionID,
                sessionExpiresAt: payload.session.expiresAt
            )
        )

        try await keychain.saveCredential(credential)
        try await keychain.saveSessionToken(payload.session.token, workspaceID: workspaceID)
        try await keychain.saveXcodeSPNCredentials(
            XcodeSPNCredentials(payload.xcodeSPN),
            workspaceID: workspaceID
        )

        if let index = workspacesCache.firstIndex(where: { $0.id == workspaceID }) {
            workspacesCache[index] = credential
        } else {
            workspacesCache.append(credential)
        }
        try await keychain.saveWorkspacesIndex(workspacesCache.map(\.id))
        activeWorkspaceID = workspaceID
        try await keychain.saveActiveWorkspaceID(workspaceID)

        return credential
    }

    // MARK: - Pure helpers

    /// Hits `https://api.ipify.org?format=text` to learn this device's
    /// outbound public IP, then logs it. Useful for configuring the
    /// workspace IP allowlist that gates the Databricks App. Cellular
    /// connections typically return a CGN address that's part of the
    /// carrier's pool (a range; allowlisting it grants traffic from any
    /// device on that carrier — generally too broad). Wi-Fi behind a
    /// home/office router returns that network's NAT'd public IP, which
    /// is the right unit for an allowlist entry.
    ///
    /// Best-effort — failure is logged at .debug and never propagates.
    /// nonisolated so it can run from a Task.detached without dragging
    /// the actor in.
    nonisolated static func logPublicIP(logger: AppLogger) async {
        guard let url = URL(string: "https://api.ipify.org?format=text") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                await logger.debug("signin.public_ip_lookup_failed", metadata: ["reason": .string("non-200")])
                return
            }
            let ip = (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            await logger.info(
                "signin.public_ip",
                metadata: [
                    "public_ip": .string(ip.isEmpty ? "<empty>" : ip),
                    "hint": .string("add to workspace IP allowlist if the App rejects with 403")
                ]
            )
        } catch {
            await logger.debug(
                "signin.public_ip_lookup_failed",
                metadata: ["reason": .string(error.localizedDescription)]
            )
        }
    }

    static func derivedWorkspaceID(from url: URL) -> String {
        // Until SCIM `meta.location` parsing is wired up (Module 01 §5.7
        // open item), use the host as a stable opaque identifier.
        url.host ?? url.absoluteString
    }

    nonisolated private func mapAuthError(_ error: any Error) -> AuthError {
        if let authError = error as? AuthError { return authError }
        if let appError = error as? LakeloomAppError {
            switch appError {
            case .networkUnavailable: return .networkUnavailable
            case .timeout: return .unexpectedResponse(reason: "timeout")
            case .tokenExchangeFailed(let reason): return .refreshFailed(reason: reason)
            case .unauthorized(let kind, let detail):
                switch kind {
                case .tokenNotFound, .tokenExpired:
                    return .refreshFailed(reason: detail)
                case .signatureInvalid, .timestampSkew, .unknown:
                    return .pairingFailed(reason: detail)
                }
            case .workspaceNotConfigured(let id):
                return .unknownWorkspace(id)
            case .transport(let reason), .decodeFailed(let reason):
                return .unexpectedResponse(reason: reason)
            case .httpError(let status, let detail):
                return .pairingFailed(reason: "HTTP \(status): \(detail)")
            }
        }
        return .unexpectedResponse(reason: error.localizedDescription)
    }
}
