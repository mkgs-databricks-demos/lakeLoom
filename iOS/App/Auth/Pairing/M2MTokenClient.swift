import Foundation

/// Workspace data-plane token client for the QR-paired SPN
/// (`grant_type=client_credentials`).
///
/// iOS holds the SPN's `client_id` + `client_secret` from the QR
/// payload and exchanges them for short-lived workspace access tokens
/// at `<workspace>/oidc/v1/token`. There is no refresh token (M2M
/// flows don't issue one); when the cached access token nears
/// expiry, the caller re-acquires by calling ``acquireToken(...)``
/// again.
public protocol M2MTokenClient: Sendable {

    /// Exchange SPN credentials for a workspace access token.
    ///
    /// Throws ``M2MTokenError`` for typed failures; transports failure
    /// reason in the case payload for diagnostics. The caller maps
    /// these onto `AuthError` for UI surfacing.
    func acquireToken(
        workspaceURL: URL,
        clientID: String,
        clientSecret: String,
        scopes: [String]
    ) async throws -> OAuthTokenResponse
}

public enum M2MTokenError: Error, Sendable, Equatable {
    case networkUnavailable
    case timeout
    /// The SPN credentials were rejected — either revoked, rotated, or
    /// the client_id and client_secret don't match. Caller should
    /// surface "re-pair required" UX.
    case invalidClient(reason: String)
    /// The SPN exists but doesn't have the requested scopes. Likely a
    /// provisioning bug on the workspace side.
    case insufficientScope(reason: String)
    case unexpectedResponse(reason: String)
    case transport(reason: String)
}

public struct LiveM2MTokenClient: M2MTokenClient {

    private let urlSession: URLSession
    private let decoder: JSONDecoder
    private let logger: AppLogger

    public init(
        urlSession: URLSession = .shared,
        logger: AppLogger = AppLogger(category: .auth)
    ) {
        self.urlSession = urlSession
        self.decoder = JSONDecoder()
        self.logger = logger
    }

    public func acquireToken(
        workspaceURL: URL,
        clientID: String,
        clientSecret: String,
        scopes: [String]
    ) async throws -> OAuthTokenResponse {
        let tokenURL = workspaceURL.appendingPathComponent("oidc/v1/token")
        await logger.debug(
            "m2m.token.attempt",
            metadata: [
                "workspace_host": .string(workspaceURL.host ?? "<no-host>"),
                "scopes": .string(scopes.joined(separator: " ")),
                // First 12 chars of the SPN application_id so we can
                // visually verify the QR's xcode_spn.client_id matches
                // whatever's listed as CAN_USE on the deployed App.
                // SPN application_ids are UUIDs (e.g. "686d32bf-a6a4-…"),
                // so 12 chars covers the first segment + first dash + 3
                // chars of the second segment — enough to disambiguate
                // visually without leaking the whole identifier.
                "client_id_prefix": .string(String(clientID.prefix(12)))
            ]
        )

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // HTTP Basic auth with client_id:client_secret per RFC 6749 §2.3.1.
        // Databricks accepts both Basic-auth and form-body credentials;
        // Basic is the canonical client_credentials grant style and
        // keeps the secret out of the request body.
        let basic = "\(clientID):\(clientSecret)"
        let basicEncoded = Data(basic.utf8).base64EncodedString()
        request.setValue("Basic \(basicEncoded)", forHTTPHeaderField: "Authorization")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " "))
        ]
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            await logger.error("m2m.token.network_unavailable", errorCode: "network_unavailable")
            throw M2MTokenError.networkUnavailable
        } catch let error as URLError where error.code == .timedOut {
            await logger.error("m2m.token.timeout", errorCode: "timeout")
            throw M2MTokenError.timeout
        } catch {
            await logger.error(
                "m2m.token.transport_failed",
                metadata: ["reason": .string(error.localizedDescription)],
                errorCode: "transport_failed"
            )
            throw M2MTokenError.transport(reason: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            await logger.error("m2m.token.non_http_response", errorCode: "unexpected_response")
            throw M2MTokenError.unexpectedResponse(reason: "non-HTTP response")
        }

        switch http.statusCode {
        case 200:
            do {
                let response = try decoder.decode(OAuthTokenResponse.self, from: data)
                await logger.info(
                    "m2m.token.ok",
                    metadata: [
                        "expires_in_s": .int(Int64(response.expiresIn)),
                        "scope": .string(response.scope ?? "<none>")
                    ]
                )
                return response
            } catch {
                await logger.error(
                    "m2m.token.decode_failed",
                    metadata: ["reason": .string(error.localizedDescription)],
                    errorCode: "unexpected_response"
                )
                throw M2MTokenError.unexpectedResponse(
                    reason: "decode token: \(error.localizedDescription)"
                )
            }

        case 400, 401:
            if let err = try? decoder.decode(OAuthTokenErrorResponse.self, from: data) {
                let detail = err.errorDescription.map { "\(err.error): \($0)" } ?? err.error
                switch err.error {
                case "invalid_client", "unauthorized_client":
                    await logger.error(
                        "m2m.token.invalid_client",
                        metadata: ["http_status": .int(Int64(http.statusCode))],
                        errorCode: "invalid_client"
                    )
                    throw M2MTokenError.invalidClient(reason: detail)
                case "invalid_scope":
                    await logger.error(
                        "m2m.token.insufficient_scope",
                        metadata: ["http_status": .int(Int64(http.statusCode))],
                        errorCode: "insufficient_scope"
                    )
                    throw M2MTokenError.insufficientScope(reason: detail)
                default:
                    await logger.error(
                        "m2m.token.error_response",
                        metadata: [
                            "http_status": .int(Int64(http.statusCode)),
                            "oauth_error": .string(err.error)
                        ],
                        errorCode: "unexpected_response"
                    )
                    throw M2MTokenError.unexpectedResponse(reason: detail)
                }
            }
            await logger.error(
                "m2m.token.bad_request",
                metadata: ["http_status": .int(Int64(http.statusCode))],
                errorCode: "unexpected_response"
            )
            throw M2MTokenError.unexpectedResponse(reason: "HTTP \(http.statusCode)")

        default:
            await logger.error(
                "m2m.token.unexpected_status",
                metadata: ["http_status": .int(Int64(http.statusCode))],
                errorCode: "unexpected_response"
            )
            throw M2MTokenError.unexpectedResponse(reason: "HTTP \(http.statusCode)")
        }
    }
}
