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
    public let captureSessionID: String
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
        kind: Kind,
        localFileURL: URL,
        mimeType: String,
        sizeBytes: Int64,
        sha256Hex: String,
        clientTimestamp: Date,
        originalFilename: String?,
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
        self.kind = kind
        self.localFileURL = localFileURL
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.sha256Hex = sha256Hex
        self.clientTimestamp = clientTimestamp
        self.originalFilename = originalFilename
        self.createdAt = createdAt
        self.state = state
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
        self.remoteUploadID = remoteUploadID
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
