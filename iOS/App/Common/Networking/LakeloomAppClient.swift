import Foundation

/// Shared transport-layer primitive for **every** iOS → Databricks
/// App HTTPS request.
///
/// Owns the two-layer auth model from
/// `architecture/hi_genie/qr-pair-auth-model.md`:
///   - **Layer 0** (Databricks Apps platform): mints + caches an M2M
///     OAuth token via ``M2MTokenClient`` against the workspace's
///     `/oidc/v1/token` using the QR-delivered Xcode SPN credentials.
///     Sent as `Authorization: Bearer <token>`. Validated by Databricks
///     Apps' sidecar before the App's code sees the request.
///   - **Layer 1** (lakeLoom App authz): attaches `X-Lakeloom-Session`,
///     `X-Lakeloom-Timestamp`, and `X-Lakeloom-Signature` headers per
///     the canonical-form signing protocol locked in Genie's
///     `architecture/hey_isaac/2026-05-13_upload-traceability-response.md`
///     (unix seconds, sha256 hex of body).
///
/// Per-workspace state (Xcode SPN creds + session token + workspace URL
/// + App base URL) is registered at sign-in time via ``configure(...)``
/// and accessed by callers via ``request(...)`` keyed by workspace ID.
public protocol LakeloomAppClient: Sendable, AnyObject {

    /// Register the per-workspace pairing material so subsequent
    /// requests against this workspace ID work. Called by AuthService
    /// at the end of a successful pairing (and on cold-launch hydrate
    /// from Keychain).
    func configure(workspaceID: String, config: LakeloomAppClientConfig) async

    /// Drop the per-workspace pairing material. Called on sign-out.
    func removeConfiguration(workspaceID: String) async

    /// Send an authenticated request and decode the response as `T`.
    /// Adds both auth layers; throws ``LakeloomAppError`` on failure.
    func request<T: Decodable & Sendable>(
        workspaceID: String,
        method: HTTPMethod,
        path: String,
        body: Data?,
        decode: T.Type
    ) async throws -> T

    /// Send an authenticated request and return the raw response body.
    /// Used by callers that want to control decoding themselves (e.g.
    /// multipart streaming uploads).
    func requestRaw(
        workspaceID: String,
        method: HTTPMethod,
        path: String,
        body: Data?
    ) async throws -> Data

    /// Returns the cached Layer 0 bearer token, minting a fresh one
    /// if the cache is empty or near expiry. Exposed so consumers that
    /// need to attach the bearer to a request they're building outside
    /// the standard ``request`` path (notably multipart uploads with
    /// custom streaming) can still get a valid token.
    func currentBearer(workspaceID: String) async throws -> String
}

// MARK: - Config

public struct LakeloomAppClientConfig: Sendable, Equatable {
    public let workspaceURL: URL
    public let appBaseURL: URL
    public let xcodeSPN: XcodeSPNCredentials
    public let sessionToken: String

    public init(
        workspaceURL: URL,
        appBaseURL: URL,
        xcodeSPN: XcodeSPNCredentials,
        sessionToken: String
    ) {
        self.workspaceURL = workspaceURL
        self.appBaseURL = appBaseURL
        self.xcodeSPN = xcodeSPN
        self.sessionToken = sessionToken
    }
}

// MARK: - HTTP method

public enum HTTPMethod: String, Sendable, Equatable, Hashable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

// MARK: - Errors

public enum LakeloomAppError: Error, Sendable, Equatable {
    /// `configure(workspaceID:...)` hasn't been called for this workspace.
    /// Usually means the user signed out or hasn't paired yet.
    case workspaceNotConfigured(String)

    case networkUnavailable
    case timeout
    case transport(reason: String)

    /// Layer 0 (M2M token exchange) failed. iOS surfaces "Re-pair to
    /// continue" — usually the Xcode SPN secret was rotated.
    case tokenExchangeFailed(reason: String)

    /// Layer 1 (session/signature) rejected by the App middleware.
    /// `kind` carries the App's RFC 9457 `type` URI suffix
    /// (`token_not_found`, `token_expired`, `signature_invalid`,
    /// `timestamp_skew`) so callers can drive UX without parsing.
    case unauthorized(kind: UnauthorizedReason, detail: String)

    /// Non-200 response that wasn't a Layer 1 unauthorized.
    case httpError(status: Int, detail: String)

    /// Successful HTTP but body didn't decode into the expected type.
    case decodeFailed(reason: String)
}

public enum UnauthorizedReason: String, Sendable, Equatable {
    case tokenNotFound = "token_not_found"
    case tokenExpired = "token_expired"
    case signatureInvalid = "signature_invalid"
    case timestampSkew = "timestamp_skew"
    case unknown = "unknown"
}

// MARK: - Live implementation

/// Production ``LakeloomAppClient``. State lives inside the actor —
/// per-workspace configs + cached M2M tokens. Per-call signing happens
/// through the injected ``RequestSigner``.
public actor LiveLakeloomAppClient: LakeloomAppClient {

    public typealias HTTPRequest = (URLRequest) async throws -> (Data, URLResponse)

    private struct CachedM2MToken {
        let value: String
        let expiresAt: Date
    }

    private let m2mTokenClient: any M2MTokenClient
    private let requestSigner: RequestSigner
    private let logger: AppLogger
    private let nowProvider: @Sendable () -> Date
    private let httpRequest: HTTPRequest
    private let decoder: JSONDecoder

    /// M2M cache key = workspaceID.
    private var m2mCache: [String: CachedM2MToken] = [:]
    /// Per-workspace pairing material.
    private var configs: [String: LakeloomAppClientConfig] = [:]

    public init(
        m2mTokenClient: any M2MTokenClient,
        requestSigner: RequestSigner,
        urlSession: URLSession = .shared,
        logger: AppLogger = AppLogger(category: .auth),
        nowProvider: @Sendable @escaping () -> Date = Date.init
    ) {
        self.m2mTokenClient = m2mTokenClient
        self.requestSigner = requestSigner
        self.logger = logger
        self.nowProvider = nowProvider
        self.httpRequest = { request in
            try await urlSession.data(for: request)
        }
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    /// Test-friendly init that swaps the HTTP transport for a closure
    /// (e.g. a `StubURLProtocol`-backed `URLSession.data(for:)` or a
    /// pure in-memory stub).
    public init(
        m2mTokenClient: any M2MTokenClient,
        requestSigner: RequestSigner,
        httpRequest: @escaping HTTPRequest,
        logger: AppLogger = AppLogger(category: .auth),
        nowProvider: @Sendable @escaping () -> Date = Date.init
    ) {
        self.m2mTokenClient = m2mTokenClient
        self.requestSigner = requestSigner
        self.logger = logger
        self.nowProvider = nowProvider
        self.httpRequest = httpRequest
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: Config

    public func configure(workspaceID: String, config: LakeloomAppClientConfig) async {
        configs[workspaceID] = config
        // Invalidate any cached M2M token for this workspace — the
        // Xcode SPN credentials may have rotated since last use.
        m2mCache[workspaceID] = nil
    }

    public func removeConfiguration(workspaceID: String) async {
        configs[workspaceID] = nil
        m2mCache[workspaceID] = nil
    }

    // MARK: Public surface

    public func request<T: Decodable & Sendable>(
        workspaceID: String,
        method: HTTPMethod,
        path: String,
        body: Data?,
        decode: T.Type
    ) async throws -> T {
        let data = try await requestRaw(
            workspaceID: workspaceID,
            method: method,
            path: path,
            body: body
        )
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            await logger.error(
                "app.request.decode_failed",
                metadata: [
                    "path": .string(path),
                    "reason": .string(String(describing: error))
                ],
                errorCode: "decode_failed"
            )
            throw LakeloomAppError.decodeFailed(reason: String(describing: error))
        }
    }

    public func requestRaw(
        workspaceID: String,
        method: HTTPMethod,
        path: String,
        body: Data?
    ) async throws -> Data {
        guard let config = configs[workspaceID] else {
            throw LakeloomAppError.workspaceNotConfigured(workspaceID)
        }

        // Layer 0 — get a fresh-ish M2M bearer.
        let bearer = try await bearer(for: workspaceID, config: config)

        // Layer 1 — sign the canonical form.
        let signatureHeaders: [String: String]
        do {
            signatureHeaders = try await requestSigner.sign(
                method: method.rawValue,
                pathAndQuery: path,
                body: body
            )
        } catch {
            await logger.error(
                "app.request.sign_failed",
                metadata: [
                    "path": .string(path),
                    "reason": .string(String(describing: error))
                ],
                errorCode: "sign_failed"
            )
            throw LakeloomAppError.transport(reason: "signing failed: \(error)")
        }

        // Build the request.
        guard let url = URL(string: path, relativeTo: config.appBaseURL)?.absoluteURL else {
            throw LakeloomAppError.transport(reason: "could not build URL for path \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(config.sessionToken, forHTTPHeaderField: "X-Lakeloom-Session")
        for (header, value) in signatureHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        if let body {
            request.httpBody = body
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        request.timeoutInterval = 30

        // Send.
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await httpRequest(request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw LakeloomAppError.networkUnavailable
        } catch let error as URLError where error.code == .timedOut {
            throw LakeloomAppError.timeout
        } catch {
            await logger.error(
                "app.request.transport_failed",
                metadata: [
                    "path": .string(path),
                    "reason": .string(error.localizedDescription)
                ],
                errorCode: "transport_failed"
            )
            throw LakeloomAppError.transport(reason: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LakeloomAppError.transport(reason: "non-HTTP response")
        }

        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            let problem = Self.parseProblemDetails(data)
            let kind = Self.unauthorizedKind(from: problem)
            await logger.warning(
                "app.request.unauthorized",
                metadata: [
                    "path": .string(path),
                    "kind": .string(kind.rawValue),
                    "detail": .string(problem.detail ?? "")
                ]
            )
            throw LakeloomAppError.unauthorized(
                kind: kind,
                detail: problem.detail ?? problem.title ?? "unauthorized"
            )
        default:
            let problem = Self.parseProblemDetails(data)
            let detail = problem.detail ?? problem.title ?? "HTTP \(http.statusCode)"
            await logger.error(
                "app.request.http_error",
                metadata: [
                    "path": .string(path),
                    "http_status": .int(Int64(http.statusCode)),
                    "detail": .string(detail)
                ],
                errorCode: "http_error"
            )
            throw LakeloomAppError.httpError(status: http.statusCode, detail: detail)
        }
    }

    public func currentBearer(workspaceID: String) async throws -> String {
        guard let config = configs[workspaceID] else {
            throw LakeloomAppError.workspaceNotConfigured(workspaceID)
        }
        return try await bearer(for: workspaceID, config: config)
    }

    // MARK: - Private

    private func bearer(for workspaceID: String, config: LakeloomAppClientConfig) async throws -> String {
        if let cached = m2mCache[workspaceID], !Self.isNearExpiry(cached, now: nowProvider()) {
            return cached.value
        }
        let response: OAuthTokenResponse
        do {
            response = try await m2mTokenClient.acquireToken(
                workspaceURL: config.workspaceURL,
                clientID: config.xcodeSPN.clientID,
                clientSecret: config.xcodeSPN.clientSecret,
                scopes: ["all-apis"]
            )
        } catch let error as M2MTokenError {
            let detail: String
            switch error {
            case .invalidClient(let reason),
                 .insufficientScope(let reason),
                 .unexpectedResponse(let reason),
                 .transport(let reason):
                detail = reason
            case .networkUnavailable: throw LakeloomAppError.networkUnavailable
            case .timeout: throw LakeloomAppError.timeout
            }
            throw LakeloomAppError.tokenExchangeFailed(reason: detail)
        }
        let expiresAt = nowProvider().addingTimeInterval(TimeInterval(max(response.expiresIn - 60, 60)))
        m2mCache[workspaceID] = CachedM2MToken(value: response.accessToken, expiresAt: expiresAt)
        return response.accessToken
    }

    private static func isNearExpiry(_ token: CachedM2MToken, now: Date, skew: TimeInterval = 30) -> Bool {
        token.expiresAt <= now.addingTimeInterval(skew)
    }

    // MARK: Problem-details parsing

    private struct ProblemDetails: Decodable {
        let type: String?
        let title: String?
        let detail: String?
    }

    private static func parseProblemDetails(_ data: Data) -> ProblemDetails {
        (try? JSONDecoder().decode(ProblemDetails.self, from: data))
            ?? ProblemDetails(type: nil, title: nil, detail: nil)
    }

    private static func unauthorizedKind(from problem: ProblemDetails) -> UnauthorizedReason {
        // Genie's `type` URIs look like `https://lakeloom/errors/<suffix>`.
        guard let typeURI = problem.type, let suffix = typeURI.split(separator: "/").last else {
            return .unknown
        }
        return UnauthorizedReason(rawValue: String(suffix)) ?? .unknown
    }
}
