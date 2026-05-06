import Foundation

/// Production ``ProjectAPIClient`` backed by `URLSession`. Stateless —
/// each call constructs a fresh `URLRequest`. Authentication is per-call
/// via the injected ``AccessToken``; on 401 the call throws
/// ``ProjectAPIError/unauthorized`` and ``ProjectService`` performs the
/// inline force-refresh + single retry per Module 06 §11.1.
public struct LiveProjectAPIClient: ProjectAPIClient {

    public static let schemaVersion = "1.0.0"

    private let urlSession: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: List

    public func list(
        workspaceID: String,
        query: String?,
        limit: Int,
        token: AccessToken,
        endpoint: AppEndpoint
    ) async throws -> ProjectListResponse {
        var components = URLComponents(
            url: endpoint.url.appendingPathComponent("api/v1/projects"),
            resolvingAgainstBaseURL: false
        )
        var items: [URLQueryItem] = [
            URLQueryItem(name: "workspace_id", value: workspaceID),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "include_archived", value: "false")
        ]
        if let query, !query.isEmpty {
            items.append(URLQueryItem(name: "q", value: query))
        }
        components?.queryItems = items
        guard let url = components?.url else {
            throw ProjectAPIError.unexpectedResponse(reason: "could not build list URL")
        }
        let request = makeRequest(method: "GET", url: url, body: nil, token: token)
        let (data, http) = try await perform(request)
        switch http.statusCode {
        case 200:
            return try decode(ProjectListResponse.self, from: data)
        default:
            throw mapNon2xx(http: http, data: data)
        }
    }

    // MARK: Fetch

    public func fetch(
        projectID: String,
        workspaceID: String,
        token: AccessToken,
        endpoint: AppEndpoint
    ) async throws -> ProjectMetadata {
        var components = URLComponents(
            url: endpoint.url.appendingPathComponent("api/v1/projects/\(projectID)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "workspace_id", value: workspaceID)]
        guard let url = components?.url else {
            throw ProjectAPIError.unexpectedResponse(reason: "could not build fetch URL")
        }
        let request = makeRequest(method: "GET", url: url, body: nil, token: token)
        let (data, http) = try await perform(request)
        switch http.statusCode {
        case 200:
            return try decode(ProjectMetadata.self, from: data)
        default:
            throw mapNon2xx(http: http, data: data)
        }
    }

    // MARK: Create

    public func create(
        _ payload: CreateProjectPayload,
        token: AccessToken,
        endpoint: AppEndpoint
    ) async throws -> ProjectMetadata {
        let url = endpoint.url.appendingPathComponent("api/v1/projects")
        let body = try encoder.encode(payload)
        let request = makeRequest(method: "POST", url: url, body: body, token: token)
        let (data, http) = try await perform(request)
        switch http.statusCode {
        case 200, 201:
            return try decode(ProjectMetadata.self, from: data)
        default:
            throw mapNon2xx(http: http, data: data)
        }
    }

    // MARK: Archive / Restore

    public func archive(
        projectID: String,
        workspaceID: String,
        token: AccessToken,
        endpoint: AppEndpoint
    ) async throws {
        try await sendArchiveAction(
            verb: "archive",
            projectID: projectID,
            workspaceID: workspaceID,
            token: token,
            endpoint: endpoint
        )
    }

    public func unarchive(
        projectID: String,
        workspaceID: String,
        token: AccessToken,
        endpoint: AppEndpoint
    ) async throws {
        try await sendArchiveAction(
            verb: "restore",
            projectID: projectID,
            workspaceID: workspaceID,
            token: token,
            endpoint: endpoint
        )
    }

    private func sendArchiveAction(
        verb: String,
        projectID: String,
        workspaceID: String,
        token: AccessToken,
        endpoint: AppEndpoint
    ) async throws {
        let url = endpoint.url.appendingPathComponent("api/v1/projects/\(projectID)/\(verb)")
        let body = try encoder.encode(ArchiveProjectPayload(workspaceID: workspaceID))
        let request = makeRequest(method: "PATCH", url: url, body: body, token: token)
        let (data, http) = try await perform(request)
        switch http.statusCode {
        case 200, 204:
            return
        default:
            throw mapNon2xx(http: http, data: data)
        }
    }

    // MARK: - Private

    private func makeRequest(method: String, url: URL, body: Data?, token: AccessToken) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue(token.workspaceID, forHTTPHeaderField: "X-Databricks-Workspace-Id")
        request.setValue(Self.schemaVersion, forHTTPHeaderField: "X-Lakeloom-Schema-Version")
        request.timeoutInterval = 15
        request.httpBody = body
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProjectAPIError.unexpectedResponse(reason: "non-HTTP response")
            }
            return (data, http)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw ProjectAPIError.networkUnavailable
        } catch let error as URLError where error.code == .timedOut {
            throw ProjectAPIError.timeout
        } catch let error as URLError where error.code == .cancelled {
            throw ProjectAPIError.canceled
        } catch let error as ProjectAPIError {
            throw error
        } catch {
            throw ProjectAPIError.unexpectedResponse(reason: error.localizedDescription)
        }
    }

    private func mapNon2xx(http: HTTPURLResponse, data: Data) -> ProjectAPIError {
        let envelope = try? decoder.decode(ProjectErrorResponse.self, from: data)
        switch http.statusCode {
        case 400: return .badRequest(envelope)
        case 401: return .unauthorized
        case 403: return .forbidden(envelope)
        case 404: return .notFound(envelope)
        case 409: return envelope.map { .duplicate($0) } ?? .badRequest(nil)
        case 413: return .payloadTooLarge
        case 429:
            let retryAfter = ProjectErrorMapper.parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After"))
            return .rateLimited(retryAfter: retryAfter)
        case 500, 502, 503, 504:
            return .serverUnavailable(httpStatus: http.statusCode)
        default:
            return .unexpectedResponse(reason: "HTTP \(http.statusCode)")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ProjectAPIError.decodeFailed(reason: error.localizedDescription)
        }
    }
}
