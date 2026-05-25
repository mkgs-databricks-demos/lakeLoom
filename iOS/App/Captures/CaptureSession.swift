import Foundation

/// A single recording session. One project can have many captures.
///
/// Mirrors `app.capture_sessions` per Genie's
/// `lakeloom-ai/server/migrations/002_capture_sessions.ts` and the
/// response shape from
/// `lakeloom-ai/server/routes/captures/capture-routes.ts`.
///
/// Lifecycle:
/// 1. `POST /api/projects/:project_id/captures` creates a capture in
///    state `.active`. Returns minimal metadata.
/// 2. iOS records audio + screenshots + photos against the capture's
///    `id` via the upload endpoints (Module 02 PRs 2+).
/// 3. `PATCH /api/captures/:capture_session_id { state: "completed" }`
///    or `cancelled` ends the session. After this, further uploads
///    fail with 409.
///
/// `getCaptureSession(...?include=uploads)` populates ``uploads`` with
/// the list of files that have been ingested for this capture.
public struct CaptureSession: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let id: String
    public let projectID: String
    public let state: State
    public let label: String?
    public let startedAt: Date
    public let endedAt: Date?
    /// Only populated by ``getCaptureSession(captureSessionID:include:)``
    /// when called with `.include(.uploads)`. Nil on every other path.
    public let createdByUserID: String?
    public let deviceLabel: String?
    public let uploads: [CaptureUpload]?
    /// Distinct upload kinds attached to this capture, as surfaced
    /// by the captures list response since Genie's PR #61 (the
    /// `array_agg(DISTINCT kind)` LATERAL join in `capture-routes.ts`).
    /// Empty when no uploads have landed yet. The sessions list
    /// uses this to badge each row with the kinds it contains
    /// without having to fetch every session's `uploads` array.
    /// Nil when the response shape doesn't carry the field (e.g.,
    /// older clients or the single-capture get-by-id path), which
    /// the decoder accepts gracefully.
    public let uploadKinds: [CaptureUpload.Kind]?

    public init(
        id: String,
        projectID: String,
        state: State,
        label: String?,
        startedAt: Date,
        endedAt: Date?,
        createdByUserID: String? = nil,
        deviceLabel: String? = nil,
        uploads: [CaptureUpload]? = nil,
        uploadKinds: [CaptureUpload.Kind]? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.state = state
        self.label = label
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.createdByUserID = createdByUserID
        self.deviceLabel = deviceLabel
        self.uploads = uploads
        self.uploadKinds = uploadKinds
    }

    public enum State: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        case active
        case completed
        case cancelled
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case projectID = "project_id"
        case state
        case label
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case createdByUserID = "created_by_user_id"
        case deviceLabel = "device_label"
        case uploads
        case uploadKinds = "upload_kinds"
    }
}

/// A single file uploaded as part of a ``CaptureSession``. Returned in
/// the optional `uploads` array of a getCaptureSession-with-include
/// response. Server-side row in `app.uploads`; only fields useful for
/// iOS UI (history, retention badges, etc.) are surfaced here.
public struct CaptureUpload: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let id: String
    public let kind: Kind
    public let volumePath: String
    public let mimeType: String
    public let sizeBytes: Int64
    public let sha256Hex: String
    public let originalFilename: String?
    public let clientTs: Date?
    /// Per Genie's 2026-05-20 contract: server populates with
    /// `"client"` when the client supplied `client_ts` in the
    /// multipart body, or `"server"` when the server used its own
    /// clock as a fallback. iOS surfaces this so the UI can hint
    /// "captured at" vs "recorded at" if the distinction matters.
    public let clientTsSource: ClientTimestampSource?
    public let uploadedAt: Date

    public init(
        id: String,
        kind: Kind,
        volumePath: String,
        mimeType: String,
        sizeBytes: Int64,
        sha256Hex: String,
        originalFilename: String?,
        clientTs: Date?,
        clientTsSource: ClientTimestampSource? = nil,
        uploadedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.volumePath = volumePath
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.sha256Hex = sha256Hex
        self.originalFilename = originalFilename
        self.clientTs = clientTs
        self.clientTsSource = clientTsSource
        self.uploadedAt = uploadedAt
    }

    public enum Kind: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        case audio
        case screenshot
        case photo
        case document
    }

    public enum ClientTimestampSource: String, Sendable, Equatable, Hashable, Codable {
        case client
        case server
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case volumePath = "volume_path"
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case sha256Hex = "sha256_hex"
        case originalFilename = "original_filename"
        case clientTs = "client_ts"
        case clientTsSource = "client_ts_source"
        case uploadedAt = "uploaded_at"
    }

    // MARK: - Lenient decoder

    /// Custom decoder that accepts `size_bytes` as either a JSON
    /// number (`134931`) or a JSON string (`"134931"`).
    ///
    /// Background: as of 2026-05-20, `GET /api/captures/:id?include=uploads`
    /// on dev serializes `size_bytes` as a string. This appears to be
    /// a Lakebase bigint-as-string serialization quirk — `BIGINT`
    /// columns in PostgreSQL drivers (including the one Genie's
    /// `lakeloom-ai` server uses) commonly serialize as strings to
    /// avoid JavaScript `Number` precision loss for values
    /// > `2^53 - 1`. iOS can't ask the server to abandon precision,
    /// so we just accept either shape. See
    /// `architecture/hi_genie/2026-05-20_smoke-test-records-and-size-bytes-decode.md`
    /// for the full discussion.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.volumePath = try c.decode(String.self, forKey: .volumePath)
        self.mimeType = try c.decode(String.self, forKey: .mimeType)
        self.sizeBytes = try Self.decodeLenientInt64(from: c, forKey: .sizeBytes)
        self.sha256Hex = try c.decode(String.self, forKey: .sha256Hex)
        self.originalFilename = try c.decodeIfPresent(String.self, forKey: .originalFilename)
        self.clientTs = try c.decodeIfPresent(Date.self, forKey: .clientTs)
        self.clientTsSource = try c.decodeIfPresent(ClientTimestampSource.self, forKey: .clientTsSource)
        self.uploadedAt = try c.decode(Date.self, forKey: .uploadedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(volumePath, forKey: .volumePath)
        try c.encode(mimeType, forKey: .mimeType)
        try c.encode(sizeBytes, forKey: .sizeBytes)
        try c.encode(sha256Hex, forKey: .sha256Hex)
        try c.encodeIfPresent(originalFilename, forKey: .originalFilename)
        try c.encodeIfPresent(clientTs, forKey: .clientTs)
        try c.encodeIfPresent(clientTsSource, forKey: .clientTsSource)
        try c.encode(uploadedAt, forKey: .uploadedAt)
    }

    /// Decode an `Int64` from a container that may hold either a JSON
    /// number or a JSON string representation. Throws the standard
    /// `DecodingError.typeMismatch` if the value is neither.
    static func decodeLenientInt64(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Int64 {
        if let direct = try? container.decode(Int64.self, forKey: key) {
            return direct
        }
        if let string = try? container.decode(String.self, forKey: key),
           let parsed = Int64(string) {
            return parsed
        }
        throw DecodingError.typeMismatch(
            Int64.self,
            DecodingError.Context(
                codingPath: container.codingPath + [key],
                debugDescription: "Expected Int64 as a number or numeric string"
            )
        )
    }
}
