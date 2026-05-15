import Foundation

/// Transport-layer protocol for the lakeLoom Databricks App's
/// capture-session endpoints. All four routes use `iosAuth` on the
/// server, so requests must carry the full two-layer auth payload
/// (`Authorization: Bearer <m2m>` + `X-Lakeloom-Session-Token` +
/// `X-Lakeloom-Timestamp` + `X-Lakeloom-Signature`). The
/// implementation accomplishes that by routing through
/// ``LakeloomAppClient`` rather than building its own URLRequests.
///
/// See `architecture/LakeLoomMarkdowns/module-02-capture-engine.md`
/// once it's written; the wire-format contract is owned by Genie in
/// `lakeloom-ai/server/routes/captures/capture-routes.ts`.
public protocol CaptureAPIClient: Sendable {

    /// `POST /api/projects/:project_id/captures` — opens a new
    /// active capture session in `projectID`. Returns the freshly
    /// minted `CaptureSession` (id, state=.active, started_at).
    func createCaptureSession(
        workspaceID: String,
        projectID: String,
        label: String?,
        clientTimestamp: Date?
    ) async throws -> CaptureSession

    /// `PATCH /api/captures/:capture_session_id` — transitions an
    /// active capture to a terminal state. Only the creating user
    /// can call this; the server returns 409/validation if called
    /// on a non-active capture.
    func updateCaptureSession(
        workspaceID: String,
        captureSessionID: String,
        state: CaptureSession.EndState,
        endedAt: Date?
    ) async throws -> CaptureSession

    /// `GET /api/captures/:capture_session_id` — full metadata plus
    /// optionally the uploads ingested so far.
    func getCaptureSession(
        workspaceID: String,
        captureSessionID: String,
        includeUploads: Bool
    ) async throws -> CaptureSession

    /// `GET /api/projects/:project_id/captures` — capture history
    /// for a project. Optional filters: state, max count, ISO
    /// `before` timestamp for pagination.
    func listProjectCaptureSessions(
        workspaceID: String,
        projectID: String,
        state: CaptureSession.State?,
        limit: Int,
        before: Date?
    ) async throws -> [CaptureSession]
}

extension CaptureSession {
    /// Terminal states a capture can transition INTO. The
    /// `.active` state can't be a transition target (the server
    /// only creates captures in `.active`, never re-enters it).
    public enum EndState: String, Sendable, Equatable, Hashable, Codable {
        case completed
        case cancelled
    }
}

// MARK: - Live implementation

public actor LiveCaptureAPIClient: CaptureAPIClient {

    private let lakeloomApp: any LakeloomAppClient
    private let encoder: JSONEncoder
    private let logger: AppLogger

    public init(
        lakeloomApp: any LakeloomAppClient,
        logger: AppLogger = AppLogger(category: .auth)
    ) {
        self.lakeloomApp = lakeloomApp
        self.logger = logger
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: Create

    public func createCaptureSession(
        workspaceID: String,
        projectID: String,
        label: String?,
        clientTimestamp: Date?
    ) async throws -> CaptureSession {
        struct Body: Encodable {
            let label: String?
            let client_ts: String?
        }
        let body = Body(
            label: label,
            client_ts: clientTimestamp.map { Self.iso8601String(from: $0) }
        )
        let bodyData: Data
        do {
            bodyData = try encoder.encode(body)
        } catch {
            throw CaptureAPIError.unexpectedResponse(reason: "encode create body: \(error)")
        }
        return try await sendDecoding(
            workspaceID: workspaceID,
            method: .post,
            path: "/api/projects/\(projectID)/captures",
            body: bodyData,
            log: "capture.create"
        )
    }

    // MARK: Update (state transition)

    public func updateCaptureSession(
        workspaceID: String,
        captureSessionID: String,
        state: CaptureSession.EndState,
        endedAt: Date?
    ) async throws -> CaptureSession {
        struct Body: Encodable {
            let state: String
            let ended_at: String?
        }
        let body = Body(
            state: state.rawValue,
            ended_at: endedAt.map { Self.iso8601String(from: $0) }
        )
        let bodyData: Data
        do {
            bodyData = try encoder.encode(body)
        } catch {
            throw CaptureAPIError.unexpectedResponse(reason: "encode patch body: \(error)")
        }
        return try await sendDecoding(
            workspaceID: workspaceID,
            method: .patch,
            path: "/api/captures/\(captureSessionID)",
            body: bodyData,
            log: "capture.update"
        )
    }

    // MARK: Get

    public func getCaptureSession(
        workspaceID: String,
        captureSessionID: String,
        includeUploads: Bool
    ) async throws -> CaptureSession {
        var path = "/api/captures/\(captureSessionID)"
        if includeUploads {
            path += "?include=uploads"
        }
        return try await sendDecoding(
            workspaceID: workspaceID,
            method: .get,
            path: path,
            body: nil,
            log: "capture.get"
        )
    }

    // MARK: List

    public func listProjectCaptureSessions(
        workspaceID: String,
        projectID: String,
        state: CaptureSession.State?,
        limit: Int,
        before: Date?
    ) async throws -> [CaptureSession] {
        var components = URLComponents()
        var items: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 200))))
        ]
        if let state {
            items.append(URLQueryItem(name: "state", value: state.rawValue))
        }
        if let before {
            items.append(URLQueryItem(name: "before", value: Self.iso8601String(from: before)))
        }
        components.queryItems = items
        let query = components.percentEncodedQuery ?? ""
        let path = "/api/projects/\(projectID)/captures" + (query.isEmpty ? "" : "?\(query)")

        struct ListResponse: Decodable {
            let captures: [CaptureSession]
        }
        let response: ListResponse = try await send(
            workspaceID: workspaceID,
            method: .get,
            path: path,
            body: nil,
            log: "capture.list"
        )
        return response.captures
    }

    // MARK: - Helpers

    private func sendDecoding(
        workspaceID: String,
        method: HTTPMethod,
        path: String,
        body: Data?,
        log: String
    ) async throws -> CaptureSession {
        try await send(workspaceID: workspaceID, method: method, path: path, body: body, log: log)
    }

    private func send<T: Decodable & Sendable>(
        workspaceID: String,
        method: HTTPMethod,
        path: String,
        body: Data?,
        log: String
    ) async throws -> T {
        await logger.debug(
            "\(log).attempt",
            metadata: [
                "method": .string(method.rawValue),
                "path": .string(path)
            ]
        )
        do {
            let value: T = try await lakeloomApp.request(
                workspaceID: workspaceID,
                method: method,
                path: path,
                body: body,
                decode: T.self
            )
            await logger.info("\(log).ok")
            return value
        } catch let error as LakeloomAppError {
            let mapped = CaptureAPIError.from(error)
            await logger.error(
                "\(log).failed",
                metadata: [
                    "path": .string(path),
                    "reason": .string(String(describing: mapped))
                ],
                errorCode: String(describing: mapped).split(separator: "(").first.map(String.init) ?? "unknown"
            )
            throw mapped
        } catch let error as CaptureAPIError {
            throw error
        } catch {
            throw CaptureAPIError.unexpectedResponse(reason: error.localizedDescription)
        }
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
