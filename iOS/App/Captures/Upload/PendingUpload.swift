import Foundation

/// A single file queued for upload through the Databricks App.
///
/// One row per file — multiple files per capture session land here
/// independently (audio, photos, screenshots). The upload coordinator
/// owns the lifecycle from `enqueue` through `succeeded`/`failed`.
///
/// Persisted to disk so the queue survives app termination. The
/// on-disk file at `localFileURL` is independent of this struct's
/// lifetime — recordings stay on disk until they're either uploaded
/// successfully or the caller invokes ``UploadCoordinator/discard(uploadID:)``.
public struct PendingUpload: Sendable, Equatable, Hashable, Codable, Identifiable {

    public let id: String
    /// Workspace this upload belongs to. The coordinator uses this
    /// to look up the right per-workspace credentials in
    /// ``LakeloomAppClient``.
    public let workspaceID: String
    /// Server-side capture session this upload attaches to. The
    /// endpoint path is built as
    /// `/api/captures/<captureSessionID>/<kind.endpointSuffix>`.
    ///
    /// Required for `.audio` / `.screenshot` / `.photo`. For
    /// `.document` uploads this field is still populated — we set
    /// it to the same value as ``projectID`` so logging /
    /// persistence stay homogeneous — but the wire path uses
    /// `projectID` directly (documents live at the project level,
    /// not under a capture).
    public let captureSessionID: String
    /// Project this upload attaches to. Only meaningful for
    /// `.document` uploads (route: `/api/projects/<projectID>/documents`)
    /// per Genie's 2026-05-13 upload-traceability response. Nil for
    /// `.audio` / `.screenshot` / `.photo`, which route under a
    /// capture session.
    public let projectID: String?
    public let kind: Kind
    public let localFileURL: URL
    public let mimeType: String
    public let sizeBytes: Int64
    /// Lowercase hex SHA-256 of the file bytes — sent as
    /// `sha256_hex` in the multipart body so the server can verify
    /// transfer integrity. Computed once at enqueue time.
    public let sha256Hex: String
    /// Wall-clock time the recording was captured on the device.
    /// Forwarded as `client_ts` (unix seconds) in the multipart
    /// body per Genie's wire-format contract.
    public let clientTimestamp: Date
    /// Optional human-readable filename (e.g.
    /// `audio-20260515T120000Z.m4a`). Stored server-side as
    /// `app.uploads.original_filename` for support-bundle debugging.
    public let originalFilename: String?
    /// Stable per-device UUID captured at enqueue time and forwarded
    /// as the `device_id` sibling form field on every multipart
    /// upload (per Genie's 2026-05-23 contract correction). Captured
    /// at enqueue so the persisted queue file survives cold-launch
    /// resumes without needing to re-resolve identity. Optional —
    /// older queue entries on disk that pre-date this field decode
    /// as nil and upload without it (Genie's Zod schema treats it as
    /// optional during rollout).
    public let deviceID: String?
    /// Zero-based index of this chunk within its capture session.
    /// Single-chunk recordings (today's default, `chunkDuration == nil`)
    /// always use `0`. PR A piece 4's rotation produces N chunks, each
    /// enqueued as its own `PendingUpload` with a monotonically
    /// increasing index. Sent as the `chunk_index` multipart field; the
    /// server's `(capture_session_id, chunk_index)` partial-unique index
    /// (migration 021) dedups retries. Older on-disk queue entries that
    /// pre-date this field decode as `0` (see custom `init(from:)`).
    public let chunkIndex: Int
    /// Advisory hint that this is the last chunk of a chunked recording
    /// session. Sent as `is_final_chunk`. The server treats it as a hint
    /// only — the capture-session state PATCH remains authoritative for
    /// completion (Genie §7.4). Single-chunk recordings are their own
    /// final chunk, so this defaults to `true`; force-quit recovery
    /// enqueues with `false` since it can't know which chunk was last.
    /// Older on-disk queue entries decode as `true` — they were always
    /// whole recordings.
    public let isFinalChunk: Bool
    /// Total chunk count for the session, set on the final chunk at stop
    /// time (`chunks.count`). Sent as `total_chunks` so the server can
    /// sanity-check `chunk_index < total_chunks`. Nil when unknown — e.g.
    /// force-quit recovery, where files are enqueued off disk without a
    /// session-level count, and on non-final chunks.
    public let totalChunks: Int?
    public let createdAt: Date

    public var state: State
    public var attempts: Int
    /// Earliest time the coordinator should retry this upload after
    /// a transient failure. Used by the worker loop's wait policy.
    public var nextAttemptAt: Date?
    /// Last error string surfaced to UI. Cleared on the next successful
    /// attempt.
    public var lastError: String?
    /// Server-issued `upload_id` populated on success.
    public var remoteUploadID: String?

    public init(
        id: String,
        workspaceID: String,
        captureSessionID: String,
        projectID: String? = nil,
        kind: Kind,
        localFileURL: URL,
        mimeType: String,
        sizeBytes: Int64,
        sha256Hex: String,
        clientTimestamp: Date,
        originalFilename: String?,
        deviceID: String? = nil,
        chunkIndex: Int = 0,
        isFinalChunk: Bool = true,
        totalChunks: Int? = nil,
        createdAt: Date,
        state: State = .queued,
        attempts: Int = 0,
        nextAttemptAt: Date? = nil,
        lastError: String? = nil,
        remoteUploadID: String? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.captureSessionID = captureSessionID
        self.projectID = projectID
        self.kind = kind
        self.localFileURL = localFileURL
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.sha256Hex = sha256Hex
        self.clientTimestamp = clientTimestamp
        self.originalFilename = originalFilename
        self.deviceID = deviceID
        self.chunkIndex = chunkIndex
        self.isFinalChunk = isFinalChunk
        self.totalChunks = totalChunks
        self.createdAt = createdAt
        self.state = state
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
        self.remoteUploadID = remoteUploadID
    }

    private enum CodingKeys: String, CodingKey {
        case id, workspaceID, captureSessionID, projectID, kind, localFileURL
        case mimeType, sizeBytes, sha256Hex, clientTimestamp, originalFilename
        case deviceID, chunkIndex, isFinalChunk, totalChunks, createdAt
        case state, attempts, nextAttemptAt, lastError, remoteUploadID
    }

    /// Custom decoder so queue entries persisted before the chunk
    /// fields existed (PR A piece 4) still rehydrate after an app
    /// update. `chunkIndex` / `isFinalChunk` / `totalChunks` are absent
    /// in those JSON blobs; we fill the single-chunk defaults (`0`,
    /// `true`, `nil`) rather than throwing — losing a queued recording
    /// to a decode failure is exactly the data loss this whole branch
    /// exists to prevent. Encoding stays synthesized via `CodingKeys`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        workspaceID = try c.decode(String.self, forKey: .workspaceID)
        captureSessionID = try c.decode(String.self, forKey: .captureSessionID)
        projectID = try c.decodeIfPresent(String.self, forKey: .projectID)
        kind = try c.decode(Kind.self, forKey: .kind)
        localFileURL = try c.decode(URL.self, forKey: .localFileURL)
        mimeType = try c.decode(String.self, forKey: .mimeType)
        sizeBytes = try c.decode(Int64.self, forKey: .sizeBytes)
        sha256Hex = try c.decode(String.self, forKey: .sha256Hex)
        clientTimestamp = try c.decode(Date.self, forKey: .clientTimestamp)
        originalFilename = try c.decodeIfPresent(String.self, forKey: .originalFilename)
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
        chunkIndex = try c.decodeIfPresent(Int.self, forKey: .chunkIndex) ?? 0
        isFinalChunk = try c.decodeIfPresent(Bool.self, forKey: .isFinalChunk) ?? true
        totalChunks = try c.decodeIfPresent(Int.self, forKey: .totalChunks)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        state = try c.decode(State.self, forKey: .state)
        attempts = try c.decode(Int.self, forKey: .attempts)
        nextAttemptAt = try c.decodeIfPresent(Date.self, forKey: .nextAttemptAt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        remoteUploadID = try c.decodeIfPresent(String.self, forKey: .remoteUploadID)
    }

    /// Server endpoint this upload should target. Documents live at
    /// the project level; everything else hangs off a capture
    /// session. Per Genie's 2026-05-13 upload-traceability response:
    ///
    /// * `.audio` / `.screenshot` / `.photo` →
    ///   `POST /api/captures/<captureSessionID>/<kind.endpointSuffix>`
    /// * `.document` →
    ///   `POST /api/projects/<projectID>/documents`
    ///
    /// Returns nil when the kind would need a `projectID` but it's
    /// missing — the upload coordinator surfaces this as a
    /// permanent failure rather than firing the wrong path.
    public func endpointPath() -> String? {
        switch kind {
        case .document:
            guard let projectID, !projectID.isEmpty else { return nil }
            return "/api/projects/\(projectID)/documents"
        case .audio, .screenshot, .photo:
            return "/api/captures/\(captureSessionID)/\(kind.endpointSuffix)"
        }
    }

    /// Upload categories. Maps 1:1 to ``CaptureUpload/Kind`` on the
    /// server side and to the route suffix in the App API.
    public enum Kind: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        case audio
        case screenshot
        case photo
        case document

        /// Path segment after `/api/captures/<id>/`. Per Genie's
        /// 2026-05-13 upload-traceability response: the audio route
        /// is `/audio`; screenshots / photos / documents will land
        /// on their own routes as their respective PRs ship. For now
        /// only `.audio` is exercised end-to-end.
        public var endpointSuffix: String {
            switch self {
            case .audio:      return "audio"
            case .screenshot: return "screenshots"
            case .photo:      return "photos"
            case .document:   return "documents"
            }
        }
    }

    public enum State: Sendable, Equatable, Hashable, Codable {
        /// Sitting on disk, waiting for the worker to pick it up.
        case queued
        /// Worker is actively sending bytes.
        case uploading
        /// Server returned 2xx and surfaced a server-side
        /// `upload_id`; the file can be removed from disk.
        case succeeded
        /// Server returned a non-success status or the transport
        /// failed.  `permanent == true` means we won't auto-retry
        /// (4xx auth/validation); `false` means transient (network,
        /// 5xx) and the worker will back off + retry until
        /// max-attempts.
        case failed(reason: String, permanent: Bool)

        public var isTerminal: Bool {
            switch self {
            case .succeeded:                  return true
            case .failed(_, let permanent):   return permanent
            case .queued, .uploading:         return false
            }
        }
    }
}

/// A change announcement broadcast on
/// ``UploadCoordinator/stateUpdates()``. Consumers (UI) get fine-grained
/// updates instead of polling the queue snapshot.
public struct UploadStateChange: Sendable, Equatable {
    public let uploadID: String
    public let state: PendingUpload.State

    public init(uploadID: String, state: PendingUpload.State) {
        self.uploadID = uploadID
        self.state = state
    }
}

/// Server-typed error codes the upload routes can return in the
/// RFC 9457 Problem Details `type` URI. Documented in
/// `architecture/hey_isaac/2026-05-20_audio-uploads-working.md`.
///
/// The retry classification carries the server's intent: some
/// errors are safe to retry on (storage transients) while others
/// are permanent and would re-fire the same way (integrity or
/// content-type rejections).
public enum UploadErrorCode: String, Sendable, Equatable, Hashable {
    /// Server couldn't write the file to the UC Volume — typically
    /// a transient backend issue (network blip, sync sweep, etc.).
    /// Worth retrying.
    case uploadVolumeWriteFailed = "UPLOAD_VOLUME_WRITE_FAILED"

    /// Client-supplied `sha256_hex` field didn't match the hash of
    /// the received file bytes. Retrying with the same bytes will
    /// fail identically; iOS needs to re-hash (and likely re-record
    /// or re-stage the file) before another attempt.
    case uploadIntegrityMismatch = "UPLOAD_INTEGRITY_MISMATCH"

    /// MIME type isn't on the endpoint's allowlist (HTTP 415).
    /// Permanent — the caller passed an unsupported file type.
    case unsupportedMediaType = "UNSUPPORTED_MEDIA_TYPE"

    /// Returns true for codes the upload coordinator should NOT
    /// auto-retry. Honored by ``LiveUploadCoordinator/isPermanent``
    /// in preference to the bare HTTP-status-based fallback.
    public var isPermanent: Bool {
        switch self {
        case .uploadVolumeWriteFailed:  return false
        case .uploadIntegrityMismatch:  return true
        case .unsupportedMediaType:     return true
        }
    }
}
