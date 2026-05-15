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

    public init(
        id: String,
        projectID: String,
        state: State,
        label: String?,
        startedAt: Date,
        endedAt: Date?,
        createdByUserID: String? = nil,
        deviceLabel: String? = nil,
        uploads: [CaptureUpload]? = nil
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
        self.uploadedAt = uploadedAt
    }

    public enum Kind: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        case audio
        case screenshot
        case photo
        case document
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case volumePath = "volume_path"
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case sha256Hex = "sha256_hex"
        case originalFilename = "original_filename"
        case clientTs = "client_ts"
        case uploadedAt = "uploaded_at"
    }
}
