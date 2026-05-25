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
    ///
    /// `deviceID` is the stable per-device UUID from
    /// ``DeviceIdentityStore``; included on the JSON body when
    /// non-nil. Genie's Zod schema (per
    /// `hey_isaac/2026-05-23_device-id-contract-correction.md`)
    /// treats it as optional during rollout, so nil produces a
    /// payload that still validates.
    func createCaptureSession(
        workspaceID: String,
        projectID: String,
        label: String?,
        clientTimestamp: Date?,
        deviceID: String?
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

    /// `PATCH /api/v1/captures/:capture_session_id/label` — rename
    /// a capture session. Labels are metadata, not lifecycle, so the
    /// server accepts this in any state (active / completed /
    /// cancelled). Returns the updated capture so callers can refresh
    /// the displayed name without an extra round trip.
    func updateCaptureLabel(
        workspaceID: String,
        captureSessionID: String,
        label: String
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

    /// `GET /api/media/project/:project_id` — project-level uploads
    /// (per Genie's 2026-05-24 Phase 3 PR #61). These are uploads
    /// with `capture_session_id IS NULL` — documents the AI pipeline
    /// produced (Whisper transcript, requirements doc, architecture
    /// diagram, Genie Code session plan per the 2026-05-23
    /// uploads-surfacing answer), plus any reference materials
    /// uploaded server-side.
    ///
    /// Response shape per Genie's `media-routes.ts`:
    /// ```
    /// { "uploads": [
    ///     { id, kind, mime_type, original_filename, size_bytes,
    ///       uploaded_at }
    ///   ] }
    /// ```
    /// Returns the full list — no pagination params today; iOS reads
    /// everything in one shot and renders. Pagination can be wired
    /// when Genie adds a cursor.
    func listProjectDocuments(
        workspaceID: String,
        projectID: String
    ) async throws -> [ProjectDocument]
}

/// Project-level upload as surfaced by
/// ``CaptureAPIClient/listProjectDocuments(workspaceID:projectID:)``.
/// Leaner than ``CaptureUpload`` because the
/// `GET /api/media/project/:project_id` route is read-only — no
/// `volume_path` / `sha256_hex` / `client_ts*` fields are surfaced
/// in the list response. Fetching the content goes through
/// `GET /api/media/:upload_id` (proxy with Range support) — a
/// separate trip iOS will wire once we add tap-to-view.
public struct ProjectDocument: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let id: String
    public let kind: CaptureUpload.Kind
    public let mimeType: String
    public let originalFilename: String?
    public let sizeBytes: Int64
    public let uploadedAt: Date

    public init(
        id: String,
        kind: CaptureUpload.Kind,
        mimeType: String,
        originalFilename: String?,
        sizeBytes: Int64,
        uploadedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.mimeType = mimeType
        self.originalFilename = originalFilename
        self.sizeBytes = sizeBytes
        self.uploadedAt = uploadedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case mimeType = "mime_type"
        case originalFilename = "original_filename"
        case sizeBytes = "size_bytes"
        case uploadedAt = "uploaded_at"
    }

    /// `size_bytes` round-trips as number-or-string in Lakebase's
    /// bigint serialization — same lenient handling as
    /// ``CaptureUpload``.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.kind = try c.decode(CaptureUpload.Kind.self, forKey: .kind)
        self.mimeType = try c.decode(String.self, forKey: .mimeType)
        self.originalFilename = try c.decodeIfPresent(String.self, forKey: .originalFilename)
        if let direct = try? c.decode(Int64.self, forKey: .sizeBytes) {
            self.sizeBytes = direct
        } else if let string = try? c.decode(String.self, forKey: .sizeBytes),
                  let parsed = Int64(string) {
            self.sizeBytes = parsed
        } else {
            throw DecodingError.typeMismatch(
                Int64.self,
                DecodingError.Context(
                    codingPath: c.codingPath + [CodingKeys.sizeBytes],
                    debugDescription: "Expected Int64 as a number or numeric string"
                )
            )
        }
        self.uploadedAt = try c.decode(Date.self, forKey: .uploadedAt)
    }
}

extension ProjectDocument {
    /// Adapt a session-scoped ``CaptureUpload`` into the leaner
    /// ``ProjectDocument`` shape so the same `DocumentViewerView`
    /// (and the `MediaContentService` it consumes) can preview
    /// audio + photos attached to a capture, not just project-level
    /// documents. Both shapes carry the fields the viewer needs —
    /// `id`, `kind`, `mime_type`, `original_filename`, `size_bytes`,
    /// `uploaded_at` — and the media proxy at
    /// `GET /api/media/:upload_id` doesn't care which side the
    /// upload originally landed on (capture-scoped vs project-scoped
    /// is purely a `capture_session_id IS NULL` filter on the list
    /// endpoints).
    public init(from upload: CaptureUpload) {
        self.init(
            id: upload.id,
            kind: upload.kind,
            mimeType: upload.mimeType,
            originalFilename: upload.originalFilename,
            sizeBytes: upload.sizeBytes,
            uploadedAt: upload.uploadedAt
        )
    }
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
        clientTimestamp: Date?,
        deviceID: String?
    ) async throws -> CaptureSession {
        struct Body: Encodable {
            let label: String?
            let client_ts: String?
            let device_id: String?
        }
        let body = Body(
            label: label,
            client_ts: clientTimestamp.map { Self.iso8601String(from: $0) },
            device_id: deviceID
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

    public func updateCaptureLabel(
        workspaceID: String,
        captureSessionID: String,
        label: String
    ) async throws -> CaptureSession {
        struct Body: Encodable {
            let label: String
        }
        let bodyData: Data
        do {
            bodyData = try encoder.encode(Body(label: label))
        } catch {
            throw CaptureAPIError.unexpectedResponse(reason: "encode label body: \(error)")
        }
        return try await sendDecoding(
            workspaceID: workspaceID,
            method: .patch,
            path: "/api/v1/captures/\(captureSessionID)/label",
            body: bodyData,
            log: "capture.label.update"
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

    public func listProjectDocuments(
        workspaceID: String,
        projectID: String
    ) async throws -> [ProjectDocument] {
        let path = "/api/media/project/\(projectID)"
        struct ListResponse: Decodable {
            let uploads: [ProjectDocument]
        }
        let response: ListResponse = try await send(
            workspaceID: workspaceID,
            method: .get,
            path: path,
            body: nil,
            log: "documents.list"
        )
        return response.uploads
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
