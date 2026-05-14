import Foundation
import Testing

@testable import LakeloomApp

@Suite("LiveLakeloomAppClient")
struct LiveLakeloomAppClientTests {

    // MARK: Fixtures

    private static let workspaceID = "ws-test"
    private static let workspaceURL = URL(string: "https://acme.cloud.databricks.com")!
    private static let appBaseURL = URL(string: "https://lakeloom-ai-dev-1234.aws.databricksapps.com")!
    private static let xcodeSPN = XcodeSPNCredentials(
        clientID: "xcode-spn-client",
        clientSecret: "xcode-spn-secret"
    )
    private static let sessionToken = "session-token-abc"

    private static func makeConfig() -> LakeloomAppClientConfig {
        LakeloomAppClientConfig(
            workspaceURL: workspaceURL,
            appBaseURL: appBaseURL,
            xcodeSPN: xcodeSPN,
            sessionToken: sessionToken
        )
    }

    /// Builds a client with a deterministic clock + a transport stub
    /// that captures each outgoing request and returns the next
    /// scripted response.
    private static func makeClient(
        responses: [@Sendable (URLRequest) async throws -> (Data, URLResponse)],
        m2mOutcomes: [FakeM2MTokenClient.Outcome] = [.success(accessToken: "m2m-token-1", expiresIn: 3_600)],
        now: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) async -> (LiveLakeloomAppClient, FakeM2MTokenClient, InMemoryDeviceKeyStore, RecordingTransport) {
        let m2m = FakeM2MTokenClient()
        for outcome in m2mOutcomes { await m2m.enqueue(outcome) }
        let keys = InMemoryDeviceKeyStore()
        let signer = RequestSigner(keyStore: keys, nowProvider: { now })
        let transport = RecordingTransport(responses: responses)
        let client = LiveLakeloomAppClient(
            m2mTokenClient: m2m,
            requestSigner: signer,
            httpRequest: { request in
                try await transport.handle(request)
            },
            nowProvider: { now }
        )
        return (client, m2m, keys, transport)
    }

    // MARK: Decoded request

    @Test("request<T>: happy path attaches both auth layers and decodes JSON")
    func happyPath() async throws {
        let payload: [Sendable] = []
        _ = payload // silence warning

        let body = Data(#"{"id":"proj-1","name":"Project A"}"#.utf8)
        let (client, _, _, transport) = await Self.makeClient(responses: [
            { request in
                (
                    body,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"]
                    )!
                )
            }
        ])

        await client.configure(workspaceID: Self.workspaceID, config: Self.makeConfig())

        struct Project: Decodable, Equatable, Sendable {
            let id: String
            let name: String
        }
        let project = try await client.request(
            workspaceID: Self.workspaceID,
            method: .get,
            path: "/api/v1/projects/proj-1",
            body: nil,
            decode: Project.self
        )

        #expect(project == Project(id: "proj-1", name: "Project A"))

        let request = await transport.lastRequest!
        // Authorization: Bearer <m2m>
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer m2m-token-1")
        // X-Lakeloom-Session
        #expect(request.value(forHTTPHeaderField: "X-Lakeloom-Session") == "session-token-abc")
        // X-Lakeloom-Timestamp present and is unix-seconds string
        let ts = request.value(forHTTPHeaderField: "X-Lakeloom-Timestamp")
        #expect(ts != nil)
        #expect(Int(ts ?? "x") == 1_700_000_000)
        // X-Lakeloom-Signature present and non-empty
        #expect((request.value(forHTTPHeaderField: "X-Lakeloom-Signature") ?? "").isEmpty == false)
        // URL is appBaseURL + path
        #expect(request.url?.absoluteString == "https://lakeloom-ai-dev-1234.aws.databricksapps.com/api/v1/projects/proj-1")
        // Method = GET
        #expect(request.httpMethod == "GET")
    }

    @Test("request: workspaceNotConfigured if configure wasn't called")
    func workspaceNotConfigured() async throws {
        let (client, _, _, _) = await Self.makeClient(responses: [])
        do {
            _ = try await client.requestRaw(
                workspaceID: "ws-never-configured",
                method: .get,
                path: "/anything",
                body: nil
            )
            Issue.record("expected workspaceNotConfigured")
        } catch let error as LakeloomAppError {
            switch error {
            case .workspaceNotConfigured(let id): #expect(id == "ws-never-configured")
            default: Issue.record("expected workspaceNotConfigured, got \(error)")
            }
        }
    }

    // MARK: Caching

    @Test("M2M token cached across consecutive requests")
    func m2mTokenCached() async throws {
        let (client, m2m, _, transport) = await Self.makeClient(responses: [
            { request in (Data("{}".utf8), Self.ok(request)) },
            { request in (Data("{}".utf8), Self.ok(request)) }
        ])
        await client.configure(workspaceID: Self.workspaceID, config: Self.makeConfig())

        // Two calls, same workspace.
        _ = try await client.requestRaw(workspaceID: Self.workspaceID, method: .get, path: "/a", body: nil)
        _ = try await client.requestRaw(workspaceID: Self.workspaceID, method: .get, path: "/b", body: nil)

        // Only one M2M exchange happened.
        let calls = await m2m.calls
        #expect(calls.count == 1)
        // But two HTTPS requests.
        let recordedCount = await transport.recordedCount
        #expect(recordedCount == 2)
    }

    @Test("M2M token re-acquired when near expiry")
    func m2mTokenRefreshesOnExpiry() async throws {
        // Advance the clock between requests so the first token (60s
        // post-clamp) is well past expiry by the time we make the
        // second request.
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let m2m = FakeM2MTokenClient()
        await m2m.enqueue(.success(accessToken: "m2m-token-1", expiresIn: 30))
        await m2m.enqueue(.success(accessToken: "m2m-token-2", expiresIn: 3_600))
        let signer = RequestSigner(keyStore: InMemoryDeviceKeyStore(), nowProvider: { clock.now() })
        let transport = RecordingTransport(responses: [
            { request in (Data("{}".utf8), Self.ok(request)) },
            { request in (Data("{}".utf8), Self.ok(request)) }
        ])
        let client = LiveLakeloomAppClient(
            m2mTokenClient: m2m,
            requestSigner: signer,
            httpRequest: { request in try await transport.handle(request) },
            nowProvider: { clock.now() }
        )
        await client.configure(workspaceID: Self.workspaceID, config: Self.makeConfig())

        _ = try await client.requestRaw(workspaceID: Self.workspaceID, method: .get, path: "/a", body: nil)
        clock.advance(by: 120)  // first token expires after ~60s; we're well past now
        _ = try await client.requestRaw(workspaceID: Self.workspaceID, method: .get, path: "/b", body: nil)

        let calls = await m2m.calls
        #expect(calls.count == 2)
    }

    // MARK: 401 error mapping

    @Test("401 token_not_found maps to .unauthorized(.tokenNotFound)")
    func tokenNotFound() async throws {
        try await assertUnauthorized(
            problemType: "https://lakeloom/errors/token_not_found",
            expected: .tokenNotFound
        )
    }

    @Test("401 token_expired maps to .unauthorized(.tokenExpired)")
    func tokenExpired() async throws {
        try await assertUnauthorized(
            problemType: "https://lakeloom/errors/token_expired",
            expected: .tokenExpired
        )
    }

    @Test("401 signature_invalid maps to .unauthorized(.signatureInvalid)")
    func signatureInvalid() async throws {
        try await assertUnauthorized(
            problemType: "https://lakeloom/errors/signature_invalid",
            expected: .signatureInvalid
        )
    }

    @Test("401 unknown type maps to .unauthorized(.unknown)")
    func unknownUnauthorized() async throws {
        try await assertUnauthorized(
            problemType: "https://lakeloom/errors/never_heard_of_it",
            expected: .unknown
        )
    }

    private func assertUnauthorized(
        problemType: String,
        expected: UnauthorizedReason
    ) async throws {
        let problemBody = Data("""
        {"type":"\(problemType)","title":"Session","status":401,"detail":"bad"}
        """.utf8)
        let (client, _, _, _) = await Self.makeClient(responses: [
            { request in
                (
                    problemBody,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 401,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/problem+json"]
                    )!
                )
            }
        ])
        await client.configure(workspaceID: Self.workspaceID, config: Self.makeConfig())
        do {
            _ = try await client.requestRaw(workspaceID: Self.workspaceID, method: .get, path: "/a", body: nil)
            Issue.record("expected unauthorized")
        } catch let error as LakeloomAppError {
            switch error {
            case .unauthorized(let kind, let detail):
                #expect(kind == expected)
                #expect(detail == "bad")
            default:
                Issue.record("expected unauthorized, got \(error)")
            }
        }
    }

    // MARK: 5xx + decode failures

    @Test("5xx response maps to .httpError with detail")
    func httpError() async throws {
        let (client, _, _, _) = await Self.makeClient(responses: [
            { request in
                (
                    Data(#"{"detail":"server died"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                )
            }
        ])
        await client.configure(workspaceID: Self.workspaceID, config: Self.makeConfig())
        do {
            _ = try await client.requestRaw(workspaceID: Self.workspaceID, method: .get, path: "/a", body: nil)
            Issue.record("expected httpError")
        } catch let error as LakeloomAppError {
            switch error {
            case .httpError(let status, let detail):
                #expect(status == 500)
                #expect(detail == "server died")
            default:
                Issue.record("expected httpError, got \(error)")
            }
        }
    }

    @Test("decode failure surfaces as .decodeFailed")
    func decodeFailure() async throws {
        let (client, _, _, _) = await Self.makeClient(responses: [
            { request in
                // Successful HTTP but body is not the expected JSON shape.
                (Data(#"{"unexpected":"shape"}"#.utf8), Self.ok(request))
            }
        ])
        await client.configure(workspaceID: Self.workspaceID, config: Self.makeConfig())
        struct Expected: Decodable, Sendable { let required: String }
        do {
            _ = try await client.request(
                workspaceID: Self.workspaceID,
                method: .get,
                path: "/a",
                body: nil,
                decode: Expected.self
            )
            Issue.record("expected decodeFailed")
        } catch let error as LakeloomAppError {
            switch error {
            case .decodeFailed: break
            default: Issue.record("expected decodeFailed, got \(error)")
            }
        }
    }

    @Test("M2M token exchange failure maps to .tokenExchangeFailed")
    func m2mFailure() async throws {
        let (client, _, _, _) = await Self.makeClient(
            responses: [],
            m2mOutcomes: [.failure(.invalidClient(reason: "secret rotated"))]
        )
        await client.configure(workspaceID: Self.workspaceID, config: Self.makeConfig())
        do {
            _ = try await client.requestRaw(workspaceID: Self.workspaceID, method: .get, path: "/a", body: nil)
            Issue.record("expected tokenExchangeFailed")
        } catch let error as LakeloomAppError {
            switch error {
            case .tokenExchangeFailed(let reason):
                #expect(reason.contains("secret rotated"))
            default:
                Issue.record("expected tokenExchangeFailed, got \(error)")
            }
        }
    }

    // MARK: currentBearer

    @Test("currentBearer mints and returns the cached value")
    func currentBearerWorks() async throws {
        let (client, _, _, _) = await Self.makeClient(responses: [])
        await client.configure(workspaceID: Self.workspaceID, config: Self.makeConfig())
        let bearer1 = try await client.currentBearer(workspaceID: Self.workspaceID)
        let bearer2 = try await client.currentBearer(workspaceID: Self.workspaceID)
        #expect(bearer1 == "m2m-token-1")
        #expect(bearer2 == bearer1)
    }

    // MARK: Helpers

    private static func ok(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}

// MARK: - MutableClock

/// Minimal advance-able clock for tests. `@unchecked Sendable` is
/// safe here because the lock serializes all access.
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date) { self.current = start }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

// MARK: - RecordingTransport

/// Captures each outgoing URLRequest and returns scripted responses in
/// order. `@unchecked Sendable` because all access is awaited through
/// the actor's serial executor — request handlers are themselves
/// already `@Sendable` closures.
actor RecordingTransport {

    typealias Handler = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private var handlers: [Handler]
    private(set) var requests: [URLRequest] = []

    init(responses: [Handler]) {
        self.handlers = responses
    }

    var lastRequest: URLRequest? { requests.last }
    var recordedCount: Int { requests.count }

    func handle(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !handlers.isEmpty else {
            throw URLError(.unsupportedURL, userInfo: [NSLocalizedDescriptionKey: "RecordingTransport: no more handlers"])
        }
        let handler = handlers.removeFirst()
        return try await handler(request)
    }
}
