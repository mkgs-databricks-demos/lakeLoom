import AuthenticationServices
import Foundation

/// Production ``OAuthClient`` backed by `URLSession` for HTTP and
/// `ASWebAuthenticationSession` for the interactive authorization step.
public struct LiveOAuthClient: OAuthClient {

    private let urlSession: URLSession
    private let decoder: JSONDecoder
    private let nowProvider: @Sendable () -> Date
    private let logger: AppLogger

    public init(
        urlSession: URLSession = .shared,
        logger: AppLogger = AppLogger(category: .auth),
        nowProvider: @Sendable @escaping () -> Date = Date.init
    ) {
        self.urlSession = urlSession
        self.decoder = JSONDecoder()
        self.logger = logger
        self.nowProvider = nowProvider
    }

    // MARK: Discovery

    public func discoverEndpoints(workspaceURL: URL) async throws -> OAuthDiscoveryDocument {
        let url = workspaceURL.appendingPathComponent("oidc/.well-known/oauth-authorization-server")
        await logger.debug(
            "oauth.discovery.attempt",
            metadata: [
                "workspace_host": .string(workspaceURL.host ?? "<no-host>"),
                "discovery_url": .string(url.absoluteString)
            ]
        )

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            await logger.error("oauth.discovery.network_unavailable", errorCode: "network_unavailable")
            throw OAuthError.networkUnavailable
        } catch let error as URLError where error.code == .timedOut {
            await logger.error("oauth.discovery.timeout", errorCode: "timeout")
            throw OAuthError.timeout
        } catch {
            await logger.error(
                "oauth.discovery.failed",
                metadata: ["reason": .string(error.localizedDescription)],
                errorCode: "discovery_failed"
            )
            throw OAuthError.discoveryFailed(reason: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            await logger.error("oauth.discovery.non_http_response", errorCode: "discovery_failed")
            throw OAuthError.discoveryFailed(reason: "non-HTTP response")
        }
        guard http.statusCode == 200 else {
            await logger.error(
                "oauth.discovery.http_error",
                metadata: ["http_status": .int(Int64(http.statusCode))],
                errorCode: "discovery_failed"
            )
            throw OAuthError.discoveryFailed(reason: "HTTP \(http.statusCode)")
        }
        let document: OAuthDiscoveryDocument
        do {
            document = try decoder.decode(OAuthDiscoveryDocument.self, from: data)
        } catch {
            await logger.error(
                "oauth.discovery.decode_failed",
                metadata: ["reason": .string(error.localizedDescription)],
                errorCode: "discovery_failed"
            )
            throw OAuthError.discoveryFailed(reason: "decode failed: \(error.localizedDescription)")
        }
        await logger.info(
            "oauth.discovery.ok",
            metadata: [
                "authorize": .string(document.authorizationEndpoint.absoluteString),
                "token": .string(document.tokenEndpoint.absoluteString)
            ]
        )
        return document
    }

    // MARK: Authorization code flow

    @MainActor
    public func performAuthorizationCodeFlow(
        workspaceURL: URL,
        clientID: String,
        scopes: [String],
        presenting: ASWebAuthenticationPresentationContextProviding
    ) async throws -> OAuthTokenResponse {
        await logger.info(
            "oauth.flow.start",
            metadata: [
                "workspace_host": .string(workspaceURL.host ?? "<no-host>"),
                "client_id": .string(clientID),
                "scopes": .string(scopes.joined(separator: " "))
            ]
        )

        // 1. Discover endpoints.
        let endpoints = try await discoverEndpoints(workspaceURL: workspaceURL)

        // 2. Generate PKCE + state.
        let pkce: PKCE
        let state: String
        do {
            pkce = try PKCE.generate()
            state = try OAuthURLBuilder.generateState()
        } catch let error as PKCEError {
            switch error {
            case .randomGenerationFailed(let status):
                await logger.error(
                    "oauth.flow.pkce_failed",
                    metadata: ["os_status": .int(Int64(status))],
                    errorCode: "random_generation_failed"
                )
                throw OAuthError.randomGenerationFailed(status: status)
            }
        }
        await logger.debug("oauth.flow.pkce_generated")

        // 3. Stand up an in-app loopback HTTP listener on a random
        // ephemeral port, then build the redirect URI the OAuth server
        // should send the code to. Databricks U2M's `databricks-cli`
        // client is registered with `http://localhost` redirects only,
        // so we have to capture the code via a local listener — ASWAS's
        // `callbackURLScheme:` can't capture an `http://localhost` URL.
        let listener = LoopbackCallbackListener(logger: logger)
        let port = try await listener.start()
        guard let redirectURI = URL(
            string: "http://localhost:\(port)\(LoopbackCallbackListener.callbackPath)"
        ) else {
            await listener.stop()
            throw OAuthError.authorizationFailed(reason: "could not build loopback redirect URI")
        }

        do {
            // 4. Build authorization URL.
            let components = OAuthURLBuilder.Components(
                authorizationEndpoint: endpoints.authorizationEndpoint,
                clientID: clientID,
                redirectURI: redirectURI,
                scopes: scopes,
                pkce: pkce,
                state: state
            )
            let authURL = try OAuthURLBuilder.authorizationURL(components: components)
            await logger.debug(
                "oauth.flow.authorization_url_built",
                metadata: ["redirect_port": .int(Int64(port))]
            )

            // 5. Present ASWebAuthenticationSession; capture the code
            // via the loopback listener (NOT via ASWAS's callback URL
            // scheme — that doesn't fire for http://localhost).
            await logger.info("oauth.flow.presenting_aswas")
            let callbackURL: URL
            do {
                callbackURL = try await presentBrowserAndCaptureViaLoopback(
                    authorizationURL: authURL,
                    listener: listener,
                    presenting: presenting
                )
            } catch OAuthError.userCancelled {
                await logger.notice("oauth.flow.user_cancelled")
                throw OAuthError.userCancelled
            } catch {
                await logger.error(
                    "oauth.flow.aswas_failed",
                    metadata: ["reason": .string(String(describing: error))],
                    errorCode: "authorization_failed"
                )
                throw error
            }
            await logger.debug("oauth.flow.callback_received")

            // 6. Validate the callback (state, error, code).
            let code: String
            switch OAuthURLBuilder.parseCallback(callbackURL) {
            case .invalid:
                await logger.error(
                    "oauth.flow.callback_invalid",
                    errorCode: "callback_invalid"
                )
                throw OAuthError.unexpectedResponse(reason: "callback URL missing code or state")
            case .error(let reason, let returnedState):
                // Confirm state where present even on the error path so a
                // hostile redirect can't steer us into showing a misleading
                // message via a fabricated reason.
                if let returnedState, returnedState != state {
                    await logger.error("oauth.flow.state_mismatch_on_error", errorCode: "state_mismatch")
                    throw OAuthError.stateMismatch
                }
                await logger.error(
                    "oauth.flow.authorization_error",
                    metadata: ["reason": .string(reason)],
                    errorCode: "authorization_failed"
                )
                throw OAuthError.authorizationFailed(reason: reason)
            case .code(let returnedCode, let returnedState):
                guard returnedState == state else {
                    await logger.error("oauth.flow.state_mismatch", errorCode: "state_mismatch")
                    throw OAuthError.stateMismatch
                }
                await logger.info("oauth.flow.code_received")
                code = returnedCode
            }

            // 7. Exchange code for tokens. The token endpoint requires
            // the same redirect_uri we sent on /authorize.
            await logger.info("oauth.flow.exchanging_code")
            let tokens = try await exchangeCodeForToken(
                tokenEndpoint: endpoints.tokenEndpoint,
                code: code,
                clientID: clientID,
                redirectURI: redirectURI,
                verifier: pkce.codeVerifier
            )
            await listener.stop()
            return tokens
        } catch {
            await listener.stop()
            throw error
        }
    }

    // MARK: Refresh

    public func refreshTokens(
        workspaceURL: URL,
        clientID: String,
        refreshToken: String
    ) async throws -> OAuthTokenResponse {
        let endpoints = try await discoverEndpoints(workspaceURL: workspaceURL)
        let body = formURLEncoded([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ])
        return try await postToTokenEndpoint(endpoints.tokenEndpoint, body: body)
    }

    // MARK: - Private

    /// Presents the OAuth authorize URL in `ASWebAuthenticationSession`
    /// and resolves with the loopback callback URL that the listener
    /// captures. `ASWebAuthenticationSession.callbackURLScheme:` does
    /// not capture `http://localhost` callbacks, so the code only ever
    /// arrives via `listener.captureCallback()`. ASWAS still owns the
    /// browser sheet (presents it, dismisses it on cancel) — its
    /// completion handler exists purely to detect user dismiss so we
    /// can short-circuit the listener.
    @MainActor
    private func presentBrowserAndCaptureViaLoopback(
        authorizationURL: URL,
        listener: LoopbackCallbackListener,
        presenting: ASWebAuthenticationPresentationContextProviding
    ) async throws -> URL {
        // Race the loopback capture against the ASWAS completion
        // handler. Whichever fires first wins; the loser becomes a
        // no-op (cancelling a finished Task does nothing).
        let captureTask: Task<URL, any Error> = Task {
            try await listener.captureCallback()
        }

        let session = ASWebAuthenticationSession(
            url: authorizationURL,
            callbackURLScheme: nil
        ) { _, error in
            // Fires when:
            //   - user dismissed the browser sheet (`canceledLogin`),
            //   - we programmatically cancelled the session after the
            //     listener captured the code (`canceledLogin` again),
            //   - or some ASWAS-internal failure.
            // Cancel the capture in all error paths; if it already
            // resolved (case 2) the cancel is a no-op.
            if error != nil {
                captureTask.cancel()
            }
        }
        session.presentationContextProvider = presenting
        // Share cookies with the system browser so SSO / passkey logins
        // feel native (no re-entering credentials each time). Override
        // per-customer if a security team requires ephemeral.
        session.prefersEphemeralWebBrowserSession = false

        guard session.start() else {
            captureTask.cancel()
            throw OAuthError.authorizationFailed(reason: "ASWebAuthenticationSession failed to start")
        }

        return try await withTaskCancellationHandler {
            do {
                let url = try await captureTask.value
                session.cancel()
                return url
            } catch is CancellationError {
                session.cancel()
                throw OAuthError.userCancelled
            } catch {
                session.cancel()
                throw error
            }
        } onCancel: {
            captureTask.cancel()
        }
    }

    private func exchangeCodeForToken(
        tokenEndpoint: URL,
        code: String,
        clientID: String,
        redirectURI: URL,
        verifier: String
    ) async throws -> OAuthTokenResponse {
        let body = formURLEncoded([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI.absoluteString,
            "client_id": clientID,
            "code_verifier": verifier
        ])
        return try await postToTokenEndpoint(tokenEndpoint, body: body)
    }

    private func postToTokenEndpoint(_ endpoint: URL, body: Data) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            await logger.error("oauth.token.network_unavailable", errorCode: "network_unavailable")
            throw OAuthError.networkUnavailable
        } catch let error as URLError where error.code == .timedOut {
            await logger.error("oauth.token.timeout", errorCode: "timeout")
            throw OAuthError.timeout
        } catch {
            await logger.error(
                "oauth.token.transport_failed",
                metadata: ["reason": .string(error.localizedDescription)],
                errorCode: "token_exchange_failed"
            )
            throw OAuthError.tokenExchangeFailed(reason: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            await logger.error("oauth.token.non_http_response", errorCode: "unexpected_response")
            throw OAuthError.unexpectedResponse(reason: "non-HTTP response")
        }

        switch http.statusCode {
        case 200:
            do {
                let response = try decoder.decode(OAuthTokenResponse.self, from: data)
                await logger.info(
                    "oauth.token.ok",
                    metadata: [
                        "expires_in_s": .int(Int64(response.expiresIn)),
                        "has_refresh_token": .bool(response.refreshToken != nil)
                    ]
                )
                return response
            } catch {
                await logger.error(
                    "oauth.token.decode_failed",
                    metadata: ["reason": .string(error.localizedDescription)],
                    errorCode: "unexpected_response"
                )
                throw OAuthError.unexpectedResponse(reason: "decode token: \(error.localizedDescription)")
            }
        case 400, 401:
            // Try to parse a structured error response.
            if let err = try? decoder.decode(OAuthTokenErrorResponse.self, from: data) {
                if err.isInvalidGrant {
                    await logger.warning(
                        "oauth.token.invalid_grant",
                        metadata: ["http_status": .int(Int64(http.statusCode))]
                    )
                    throw OAuthError.invalidGrant
                }
                if err.error == "unauthorized_client" {
                    await logger.error(
                        "oauth.token.unauthorized_client",
                        metadata: ["http_status": .int(Int64(http.statusCode))],
                        errorCode: "unauthorized_client"
                    )
                    throw OAuthError.unauthorizedClient
                }
                let detail = err.errorDescription.map { "\(err.error): \($0)" } ?? err.error
                await logger.error(
                    "oauth.token.error_response",
                    metadata: [
                        "http_status": .int(Int64(http.statusCode)),
                        "oauth_error": .string(err.error),
                        "oauth_error_description": .string(err.errorDescription ?? "<none>")
                    ],
                    errorCode: "token_exchange_failed"
                )
                throw OAuthError.tokenExchangeFailed(reason: detail)
            }
            await logger.error(
                "oauth.token.bad_request",
                metadata: ["http_status": .int(Int64(http.statusCode))],
                errorCode: "token_exchange_failed"
            )
            throw OAuthError.tokenExchangeFailed(reason: "HTTP \(http.statusCode)")
        default:
            await logger.error(
                "oauth.token.unexpected_status",
                metadata: ["http_status": .int(Int64(http.statusCode))],
                errorCode: "token_exchange_failed"
            )
            throw OAuthError.tokenExchangeFailed(reason: "HTTP \(http.statusCode)")
        }
    }

    private func formURLEncoded(_ pairs: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = pairs.map { URLQueryItem(name: $0.key, value: $0.value) }
        let body = components.percentEncodedQuery ?? ""
        return Data(body.utf8)
    }
}
