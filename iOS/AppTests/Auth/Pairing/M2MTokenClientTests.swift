import Foundation
import Testing

@testable import LakeloomApp

@Suite("LiveM2MTokenClient")
@MainActor
struct LiveM2MTokenClientTests {

    private static let workspaceURL = URL(string: "https://acme.cloud.databricks.com")!
    private static let clientID = "test-spn-client-id"
    private static let clientSecret = "test-spn-client-secret"
    private static let scopes = ["all-apis"]

    @Test("200 with valid token JSON decodes into OAuthTokenResponse")
    func happyPath() async throws {
        let session = StubURLProtocol.makeSession { request in
            // Verify the request shape.
            #expect(request.url?.path == "/oidc/v1/token")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
            #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)

            let body = """
            {
              "access_token": "atk-1",
              "token_type": "Bearer",
              "expires_in": 3600,
              "scope": "all-apis"
            }
            """
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }
        let client = LiveM2MTokenClient(urlSession: session)
        let response = try await client.acquireToken(
            workspaceURL: Self.workspaceURL,
            clientID: Self.clientID,
            clientSecret: Self.clientSecret,
            scopes: Self.scopes
        )
        #expect(response.accessToken == "atk-1")
        #expect(response.expiresIn == 3600)
        #expect(response.refreshToken == nil)
    }

    @Test("Authorization header is HTTP Basic of client_id:client_secret")
    func sendsBasicAuthHeader() async throws {
        let session = StubURLProtocol.makeSession { request in
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            #expect(auth.hasPrefix("Basic "))
            let encoded = String(auth.dropFirst("Basic ".count))
            let decoded = String(data: Data(base64Encoded: encoded) ?? Data(), encoding: .utf8) ?? ""
            #expect(decoded == "test-spn-client-id:test-spn-client-secret")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"access_token":"a","token_type":"Bearer","expires_in":1}"#.utf8)
            )
        }
        let client = LiveM2MTokenClient(urlSession: session)
        _ = try await client.acquireToken(
            workspaceURL: Self.workspaceURL,
            clientID: Self.clientID,
            clientSecret: Self.clientSecret,
            scopes: Self.scopes
        )
    }

    @Test("Body contains grant_type=client_credentials and scope")
    func bodyHasClientCredentialsGrant() async throws {
        let session = StubURLProtocol.makeSession { request in
            // URLProtocol stub doesn't always have httpBody on the
            // request — pull from BodyStream when needed.
            let body = request.lakeloomTestBody ?? Data()
            let bodyString = String(data: body, encoding: .utf8) ?? ""
            #expect(bodyString.contains("grant_type=client_credentials"))
            #expect(bodyString.contains("scope=all-apis"))
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"access_token":"a","token_type":"Bearer","expires_in":1}"#.utf8)
            )
        }
        let client = LiveM2MTokenClient(urlSession: session)
        _ = try await client.acquireToken(
            workspaceURL: Self.workspaceURL,
            clientID: Self.clientID,
            clientSecret: Self.clientSecret,
            scopes: ["all-apis"]
        )
    }

    @Test("401 invalid_client maps to M2MTokenError.invalidClient")
    func invalidClient() async throws {
        let session = StubURLProtocol.makeSession { request in
            let body = #"{"error":"invalid_client","error_description":"The client is not authorized"}"#
            return (
                HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        let client = LiveM2MTokenClient(urlSession: session)
        do {
            _ = try await client.acquireToken(
                workspaceURL: Self.workspaceURL,
                clientID: Self.clientID,
                clientSecret: Self.clientSecret,
                scopes: Self.scopes
            )
            Issue.record("expected M2MTokenError.invalidClient")
        } catch let error as M2MTokenError {
            switch error {
            case .invalidClient(let reason):
                #expect(reason.contains("invalid_client"))
            default:
                Issue.record("expected invalidClient, got \(error)")
            }
        }
    }

    @Test("400 invalid_scope maps to M2MTokenError.insufficientScope")
    func insufficientScope() async throws {
        let session = StubURLProtocol.makeSession { request in
            let body = #"{"error":"invalid_scope","error_description":"Scope not granted"}"#
            return (
                HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        let client = LiveM2MTokenClient(urlSession: session)
        do {
            _ = try await client.acquireToken(
                workspaceURL: Self.workspaceURL,
                clientID: Self.clientID,
                clientSecret: Self.clientSecret,
                scopes: Self.scopes
            )
            Issue.record("expected M2MTokenError.insufficientScope")
        } catch let error as M2MTokenError {
            switch error {
            case .insufficientScope: break
            default: Issue.record("expected insufficientScope, got \(error)")
            }
        }
    }

    @Test("Non-2xx with no parseable error body maps to unexpectedResponse")
    func unexpectedHttpStatus() async throws {
        let session = StubURLProtocol.makeSession { request in
            return (
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data("server exploded".utf8)
            )
        }
        let client = LiveM2MTokenClient(urlSession: session)
        do {
            _ = try await client.acquireToken(
                workspaceURL: Self.workspaceURL,
                clientID: Self.clientID,
                clientSecret: Self.clientSecret,
                scopes: Self.scopes
            )
            Issue.record("expected M2MTokenError.unexpectedResponse")
        } catch let error as M2MTokenError {
            switch error {
            case .unexpectedResponse(let reason):
                #expect(reason.contains("500"))
            default: Issue.record("expected unexpectedResponse, got \(error)")
            }
        }
    }
}
