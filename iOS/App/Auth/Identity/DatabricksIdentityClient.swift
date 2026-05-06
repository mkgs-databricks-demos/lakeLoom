import Foundation

/// Looks up the signed-in user's identity for a given workspace using the
/// Databricks SCIM 2.0 `/Me` endpoint.
///
/// AuthService calls this once at sign-in and on demand via
/// ``AuthServicing/refreshIdentity()``. It does NOT retry on 401 — that's
/// AuthService's job (force-refresh + retry once).
public protocol DatabricksIdentityClient: Sendable {
    /// `GET {workspaceURL}/api/2.0/preview/scim/v2/Me`
    func fetchMe(workspaceURL: URL, bearerToken: String) async throws -> SCIMMeResponse
}

/// Production implementation backed by `URLSession`.
public struct LiveDatabricksIdentityClient: DatabricksIdentityClient {

    private let urlSession: URLSession
    private let decoder: JSONDecoder

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        self.decoder = JSONDecoder()
    }

    public func fetchMe(workspaceURL: URL, bearerToken: String) async throws -> SCIMMeResponse {
        let url = workspaceURL.appendingPathComponent("api/2.0/preview/scim/v2/Me")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw IdentityClientError.networkUnavailable
        } catch let error as URLError where error.code == .timedOut {
            throw IdentityClientError.timeout
        } catch {
            throw IdentityClientError.transport(reason: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw IdentityClientError.unexpectedResponse(reason: "non-HTTP response")
        }

        switch http.statusCode {
        case 200:
            do {
                return try decoder.decode(SCIMMeResponse.self, from: data)
            } catch {
                throw IdentityClientError.decodeFailed(reason: String(describing: error))
            }
        case 401:
            throw IdentityClientError.unauthorized
        case 403:
            throw IdentityClientError.forbidden
        case 500...599:
            throw IdentityClientError.serverUnavailable(status: http.statusCode)
        default:
            throw IdentityClientError.unexpectedResponse(reason: "HTTP \(http.statusCode)")
        }
    }
}

/// Errors produced by ``DatabricksIdentityClient``. AuthService maps these
/// onto its own ``AuthError`` cases per Module 01 §9.
public enum IdentityClientError: Error, Sendable, Equatable {
    case unauthorized
    case forbidden
    case networkUnavailable
    case timeout
    case serverUnavailable(status: Int)
    case decodeFailed(reason: String)
    case transport(reason: String)
    case unexpectedResponse(reason: String)
}
