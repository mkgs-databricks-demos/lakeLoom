import Foundation

/// Production ``ProjectAPIClient`` backed by ``LakeloomAppClient``.
///
/// Per Genie's 2026-05-24 `hey_isaac/2026-05-24_ios-layer2-on-project-endpoints.md`,
/// `/api/v1/projects*` endpoints sit behind the server's `dualAuth`
/// middleware which requires iOS to send the Layer 2 headers
/// (`X-Lakeloom-Session-Token` + `X-Lakeloom-Timestamp` +
/// `X-Lakeloom-Signature`) in addition to the Layer 0 bearer token.
/// Without Layer 2, the auth sidecar resolves the request to the
/// Xcode SPN identity and the server now returns **401** outright.
///
/// Previously this client built `URLRequest`s directly with
/// `URLSession` and only attached the bearer — that's the gap. Routing
/// through ``LakeloomAppClient/requestRaw(workspaceID:method:path:body:contentType:)``
/// applies both layers automatically, identical to the path the
/// captures + uploads + transcript-events clients already use.
///
/// The protocol's `token: AccessToken` and `endpoint: AppEndpoint`
/// parameters are now **unused** in the live impl — ``LakeloomAppClient``
/// manages its own bearer cache and resolves the workspace's base URL
/// from its configured state. Kept in the signature so the
/// `ProjectService` callers + existing test fakes don't have to
/// change in this PR; a follow-on can drop them.
public struct LiveProjectAPIClient: ProjectAPIClient {

    public static let schemaVersion = "1.0.0"

    private let lakeloomApp: any LakeloomAppClient
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(lakeloomApp: any LakeloomAppClient) {
        self.lakeloomApp = lakeloomApp
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
        var path = "/api/v1/projects?workspace_id=\(percentEncoded(workspaceID))&limit=\(limit)&include_archived=false"
        if let query, !query.isEmpty {
            path += "&q=\(percentEncoded(query))"
        }
        let data = try await rawGet(workspaceID: workspaceID, path: path)
        return try decode(ProjectListResponse.self, from: data)
    }

    // MARK: Fetch

    public func fetch(
        projectID: String,
        workspaceID: String,
        token: AccessToken,
        endpoint: AppEndpoint
    ) async throws -> ProjectMetadata {
        let path = "/api/v1/projects/\(percentEncoded(projectID))?workspace_id=\(percentEncoded(workspaceID))"
        let data = try await rawGet(workspaceID: workspaceID, path: path)
        return try decode(ProjectMetadata.self, from: data)
    }

    // MARK: Create

    public func create(
        _ payload: CreateProjectPayload,
        token: AccessToken,
        endpoint: AppEndpoint
    ) async throws -> ProjectMetadata {
        let body: Data
        do {
            body = try encoder.encode(payload)
        } catch {
            throw ProjectAPIError.unexpectedResponse(reason: "encode create body: \(error)")
        }
        let data = try await rawSend(
            workspaceID: payload.workspaceID,
            method: .post,
            path: "/api/v1/projects",
            body: body
        )
        return try decode(ProjectMetadata.self, from: data)
    }

    // MARK: Update

    public func update(
        projectID: String,
        workspaceID: String,
        name: String?,
        description: String?,
        token: AccessToken,
        endpoint: AppEndpoint
    ) async throws -> ProjectMetadata {
        // Server requires at least one field. iOS validates here too
        // so a stray empty edit doesn't hit the wire.
        if name == nil && description == nil {
            throw ProjectAPIError.badRequest(nil)
        }
        let body: Data
        do {
            body = try encoder.encode(UpdateProjectBody(name: name, description: description))
        } catch {
            throw ProjectAPIError.unexpectedResponse(reason: "encode update body: \(error)")
        }
        let data = try await rawSend(
            workspaceID: workspaceID,
            method: .patch,
            path: "/api/v1/projects/\(percentEncoded(projectID))",
            body: body
        )
        return try decode(ProjectMetadata.self, from: data)
    }

    // MARK: Archive / Restore

    public func archive(
        projectID: String,
        workspaceID: String,
        token: AccessToken,
        endpoint: AppEndpoint
    ) async throws {
        try await sendArchiveAction(verb: "archive", projectID: projectID, workspaceID: workspaceID)
    }

    public func unarchive(
        projectID: String,
        workspaceID: String,
        token: AccessToken,
        endpoint: AppEndpoint
    ) async throws {
        try await sendArchiveAction(verb: "restore", projectID: projectID, workspaceID: workspaceID)
    }

    private func sendArchiveAction(
        verb: String,
        projectID: String,
        workspaceID: String
    ) async throws {
        let body: Data
        do {
            body = try encoder.encode(ArchiveProjectPayload(workspaceID: workspaceID))
        } catch {
            throw ProjectAPIError.unexpectedResponse(reason: "encode archive body: \(error)")
        }
        _ = try await rawSend(
            workspaceID: workspaceID,
            method: .patch,
            path: "/api/v1/projects/\(percentEncoded(projectID))/\(verb)",
            body: body
        )
    }

    // MARK: - Private

    private func rawGet(workspaceID: String, path: String) async throws -> Data {
        try await rawSend(
            workspaceID: workspaceID,
            method: .get,
            path: path,
            body: nil
        )
    }

    private func rawSend(
        workspaceID: String,
        method: HTTPMethod,
        path: String,
        body: Data?
    ) async throws -> Data {
        do {
            return try await lakeloomApp.requestRaw(
                workspaceID: workspaceID,
                method: method,
                path: path,
                body: body,
                contentType: body == nil ? nil : "application/json"
            )
        } catch let error as LakeloomAppError {
            throw Self.mapLakeloomError(error)
        } catch let error as ProjectAPIError {
            throw error
        } catch {
            throw ProjectAPIError.unexpectedResponse(reason: error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ProjectAPIError.decodeFailed(reason: error.localizedDescription)
        }
    }

    /// Translate the transport-level `LakeloomAppError` produced by
    /// the layered auth client into ``ProjectAPIError``. The Project
    /// service's retry + UI logic is already wired against
    /// `ProjectAPIError`, so we don't widen its surface — we just
    /// fan-in the lakeloomApp errors at this boundary.
    private static func mapLakeloomError(_ error: LakeloomAppError) -> ProjectAPIError {
        switch error {
        case .workspaceNotConfigured:
            return .unauthorized
        case .networkUnavailable:
            return .networkUnavailable
        case .timeout:
            return .timeout
        case .tokenExchangeFailed:
            return .unauthorized
        case .unauthorized:
            return .unauthorized
        case .httpError(let status, let detail, _):
            let envelope = decodeErrorEnvelope(detail)
            switch status {
            case 400:
                return .badRequest(envelope)
            case 403:
                return .forbidden(envelope)
            case 404:
                return .notFound(envelope)
            case 409:
                return envelope.map(ProjectAPIError.duplicate) ?? .badRequest(nil)
            case 413:
                return .payloadTooLarge
            case 429:
                return .rateLimited(retryAfter: nil)
            case 500, 502, 503, 504:
                return .serverUnavailable(httpStatus: status)
            default:
                return .unexpectedResponse(reason: "HTTP \(status): \(detail)")
            }
        case .transport(let reason):
            return .unexpectedResponse(reason: reason)
        case .decodeFailed(let reason):
            return .decodeFailed(reason: reason)
        }
    }

    /// `LakeloomAppError.httpError`'s detail string carries the
    /// server's RFC 9457 body verbatim (when present). Try to
    /// decode our typed envelope so the caller's error surfaces
    /// include the server's structured detail.
    private static func decodeErrorEnvelope(_ detail: String) -> ProjectErrorResponse? {
        guard let data = detail.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ProjectErrorResponse.self, from: data)
    }

    private func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}
