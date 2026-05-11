import Foundation
import Network

/// Listens on `127.0.0.1:<os-chosen-port>` for the OAuth authorization-code
/// callback that Databricks redirects to.
///
/// Databricks U2M's published `databricks-cli` client is registered with
/// loopback HTTP redirect URIs only — `ASWebAuthenticationSession` can't
/// natively capture an `http://localhost` callback (it's designed for
/// custom URL schemes), so we stand up a tiny HTTP listener inside the
/// iOS app, advertise its port in the `redirect_uri`, and capture the
/// redirect there.
///
/// One listener per OAuth flow. Caller pattern:
/// ```swift
/// let listener = LoopbackCallbackListener()
/// let port = try await listener.start()
/// // build authorize URL with redirect_uri = http://localhost:\(port)/callback
/// // present the system browser
/// let callbackURL = try await listener.captureCallback()
/// await listener.stop()
/// ```
public actor LoopbackCallbackListener {

    /// Path the OAuth redirect must hit. We always advertise
    /// `http://localhost:<port>/callback`.
    public static let callbackPath = "/callback"

    /// The port the published Databricks `databricks-cli` U2M client
    /// is registered against. The OAuth U2M docs prescribe
    /// `http://localhost:8020` specifically; ephemeral ports are
    /// rejected at `/authorize` even though RFC 8252 says they
    /// should be allowed. Matching the documented port keeps
    /// behaviour aligned with `databricks auth login` on the desktop.
    public static let port: UInt16 = 8020

    /// HTML body served back to the browser once the callback is captured.
    /// The user sees this in the system browser sheet for the brief moment
    /// before we programmatically cancel the ASWebAuthenticationSession.
    private static let successResponseBody: String = """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <title>lakeLoom — sign-in complete</title>
        <style>
        body { font-family: -apple-system, system-ui, sans-serif; padding: 32px; color: #1d1d1f; }
        h1 { font-size: 22px; margin-bottom: 8px; }
        p { color: #6e6e73; margin-top: 0; }
        </style></head><body>
        <h1>You're signed in.</h1>
        <p>You can close this tab and return to lakeLoom.</p>
        </body></html>
        """

    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, any Error>?
    private let logger: AppLogger
    private let queue: DispatchQueue

    public init(logger: AppLogger = AppLogger(category: .auth)) {
        self.logger = logger
        self.queue = DispatchQueue(label: "com.databricks.lakeloom.oauth.loopback")
    }

    // MARK: Lifecycle

    /// Bind to `127.0.0.1:8020` (the port the published `databricks-cli`
    /// U2M client is registered against). Returns the bound port so the
    /// caller can compose the `redirect_uri`.
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        // Pin to the IPv4 loopback interface so we can't accidentally
        // accept connections from the wider network. IPv6 is excluded
        // because Databricks' redirect uses the literal `localhost`,
        // which we want resolved to `127.0.0.1`.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: Self.port) ?? .any
        )
        parameters.requiredInterfaceType = .loopback

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            await logger.error(
                "oauth.loopback.listener_create_failed",
                metadata: ["reason": .string(error.localizedDescription)],
                errorCode: "loopback_listener_failed"
            )
            throw OAuthError.authorizationFailed(reason: "loopback listener create: \(error.localizedDescription)")
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handle(connection: connection) }
        }

        // Wait for the listener to be `.ready`. The state handler can
        // fire multiple times during the listener's lifetime (notably,
        // again with `.cancelled` when stop() runs), so gate on a
        // one-shot flag to avoid double-resuming the continuation. The
        // handler is invoked on our serial `queue`, so plain mutable
        // state without a lock is safe.
        let oneShot = ContinuationOneShot()
        let bound: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                guard !oneShot.fired else { return }
                switch state {
                case .ready:
                    if let port = listener.port {
                        oneShot.fired = true
                        continuation.resume(returning: port.rawValue)
                    } else {
                        oneShot.fired = true
                        continuation.resume(throwing: OAuthError.authorizationFailed(
                            reason: "loopback listener ready without port"
                        ))
                    }
                case .failed(let error):
                    oneShot.fired = true
                    continuation.resume(throwing: OAuthError.authorizationFailed(
                        reason: "loopback listener failed: \(error.localizedDescription)"
                    ))
                case .cancelled:
                    // Only relevant if cancelled BEFORE ready; cleanup
                    // path handles post-ready cancellation through stop().
                    oneShot.fired = true
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        self.listener = listener
        await logger.info(
            "oauth.loopback.listening",
            metadata: ["port": .int(Int64(bound))]
        )
        return bound
    }

    /// Suspends until either the OAuth callback URL is captured (resolves
    /// with the URL) or the surrounding Task is cancelled (throws
    /// `CancellationError`).
    public func captureCallback() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.cancelPendingContinuation() }
        }
    }

    /// Tear down the listener and release any resources. Idempotent.
    public func stop() async {
        if let listener {
            listener.cancel()
            self.listener = nil
            await logger.debug("oauth.loopback.stopped")
        }
        cancelPendingContinuation()
    }

    // MARK: - Private

    private func cancelPendingContinuation() {
        if let continuation {
            continuation.resume(throwing: CancellationError())
            self.continuation = nil
        }
    }

    private func resumeWithCallback(_ url: URL) {
        if let continuation {
            continuation.resume(returning: url)
            self.continuation = nil
        }
    }

    private func resumeWithError(_ error: any Error) {
        if let continuation {
            continuation.resume(throwing: error)
            self.continuation = nil
        }
    }

    private func handle(connection: NWConnection) {
        Task { await self.logger.debug("oauth.loopback.connection_received") }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                Task { await self.handleConnectionError(error, connection: connection) }
                return
            }
            guard let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            Task { await self.handleConnectionData(data, connection: connection) }
        }
    }

    private func handleConnectionError(_ error: NWError, connection: NWConnection) {
        connection.cancel()
        // We don't fail the listener on a single bad connection — the
        // browser may have made a stray request (favicon, etc.) that we
        // simply ignore. Only fail the capture if the listener itself
        // dies (handled in stateUpdateHandler).
    }

    private func handleConnectionData(_ data: Data, connection: NWConnection) async {
        guard let request = String(data: data, encoding: .utf8) else {
            await respondNotFound(on: connection)
            return
        }

        // Parse the request line: "GET /callback?code=…&state=… HTTP/1.1"
        guard let firstLine = request.split(separator: "\r\n", maxSplits: 1).first else {
            await respondNotFound(on: connection)
            return
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            await respondNotFound(on: connection)
            return
        }
        let path = String(parts[1])
        await logger.debug(
            "oauth.loopback.request",
            metadata: ["path_prefix": .string(String(path.prefix(64)))]
        )

        // Reject anything that isn't /callback.
        guard path.hasPrefix(Self.callbackPath) else {
            await respondNotFound(on: connection)
            return
        }

        // Compose the URL the OAuth client expects: scheme + host + path?query.
        // The browser sent us `/callback?…`; reconstruct
        // `http://localhost/callback?…` so OAuthURLBuilder.parseCallback
        // can use URLComponents to extract the query items.
        let reconstructed = URL(string: "http://localhost\(path)")
        guard let callbackURL = reconstructed else {
            await respondBadRequest(on: connection)
            return
        }

        await respondOK(on: connection)
        resumeWithCallback(callbackURL)
    }

    // MARK: HTTP responses

    private func respondOK(on connection: NWConnection) async {
        let body = Self.successResponseBody
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        send(response, on: connection)
    }

    private func respondNotFound(on connection: NWConnection) async {
        let response = """
        HTTP/1.1 404 Not Found\r
        Content-Length: 0\r
        Connection: close\r
        \r

        """
        send(response, on: connection)
    }

    private func respondBadRequest(on connection: NWConnection) async {
        let response = """
        HTTP/1.1 400 Bad Request\r
        Content-Length: 0\r
        Connection: close\r
        \r

        """
        send(response, on: connection)
    }

    private func send(_ response: String, on connection: NWConnection) {
        let data = Data(response.utf8)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// One-shot mutable flag for guarding a `CheckedContinuation` against
/// double-resume across multiple `stateUpdateHandler` invocations on
/// a serial queue. Marked `@unchecked Sendable` because the only
/// access is queue-bound.
private final class ContinuationOneShot: @unchecked Sendable {
    var fired = false
}
