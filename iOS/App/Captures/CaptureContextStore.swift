import Foundation

/// Disk-persistent snapshot of the in-flight ``CaptureContext`` (if
/// any) so ``LiveCaptureService`` can rehydrate after app
/// termination.
///
/// Storage is a single JSON file at
/// `<Application Support>/Captures/active-capture.json`. Atomic
/// writes go through a tmp+rename so a crash mid-write leaves the
/// previous good snapshot intact. Same shape + concurrency pattern
/// as ``UploadQueueStore``.
///
/// Lifecycle invariants the service maintains around this store:
/// - **Save** on every transition INTO `.recording` or `.finalizing`,
///   and whenever `pendingUploadIDs` changes during `.finalizing`.
/// - **Clear** on every transition into a terminal state
///   (`.completed`, `.cancelled`, `.failed`) so a clean exit doesn't
///   leave a stale snapshot to recover on next launch.
public actor CaptureContextStore {

    private let fileURL: URL
    private let logger: AppLogger
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileURL: URL,
        logger: AppLogger = AppLogger(category: .capture)
    ) {
        self.fileURL = fileURL
        self.logger = logger
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    /// Convenience init that resolves the snapshot file under
    /// `Application Support/Captures/active-capture.json`, creating
    /// the directory if needed. Used in production wiring.
    public static func makeDefault(
        logger: AppLogger = AppLogger(category: .capture)
    ) throws -> CaptureContextStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dirToFlag = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dirToFlag.setResourceValues(values)
        let url = dir.appendingPathComponent("active-capture.json", isDirectory: false)
        return CaptureContextStore(fileURL: url, logger: logger)
    }

    /// Read the persisted snapshot. Returns `nil` if there's no
    /// in-flight capture or if the file is missing/corrupt
    /// (corrupt files log a warning and are treated as nil so a
    /// damaged sidecar never blocks app launch).
    public func load() async -> PersistedCaptureContext? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(PersistedCaptureContext.self, from: data)
        } catch {
            await logger.warning(
                "capture.context.load_failed",
                metadata: [
                    "reason": .string(error.localizedDescription)
                ]
            )
            return nil
        }
    }

    /// Replace the on-disk snapshot. Atomic via tmp+rename so a
    /// crash mid-write leaves the previous snapshot intact.
    public func save(_ context: PersistedCaptureContext) async throws {
        let data: Data
        do {
            data = try encoder.encode(context)
        } catch {
            throw CaptureContextStoreError.persistenceFailed(reason: "encode: \(error.localizedDescription)")
        }
        let tmpURL = fileURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmpURL, options: [.atomic])
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw CaptureContextStoreError.persistenceFailed(reason: "write: \(error.localizedDescription)")
        }
    }

    /// Delete the snapshot file. Always succeeds (treats "no file"
    /// as a clear).
    public func clear() async {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// On-disk shape for an in-flight capture. Subset of
/// ``CaptureServiceState`` — only the two non-terminal cases that
/// would survive an app termination.
public struct PersistedCaptureContext: Sendable, Equatable, Hashable, Codable {

    public let captureSessionID: String
    public let projectID: String
    public let workspaceID: String
    public let startedAt: Date
    public let phase: Phase
    /// Ordered for stable on-disk byte representation; deduplication
    /// is the service's responsibility, not the store's.
    public let pendingUploadIDs: [String]

    public init(
        captureSessionID: String,
        projectID: String,
        workspaceID: String,
        startedAt: Date,
        phase: Phase,
        pendingUploadIDs: [String]
    ) {
        self.captureSessionID = captureSessionID
        self.projectID = projectID
        self.workspaceID = workspaceID
        self.startedAt = startedAt
        self.phase = phase
        self.pendingUploadIDs = pendingUploadIDs
    }

    public enum Phase: String, Sendable, Equatable, Hashable, Codable {
        /// Server-side capture session created, recorder started,
        /// no uploads enqueued yet. App death here orphans an audio
        /// file on disk and leaves the server session `.active`.
        case recording
        /// Recorder stopped, uploads enqueued. App death here is
        /// fully recoverable: the upload queue store rehydrates,
        /// the watcher re-attaches.
        case finalizing
    }
}

public enum CaptureContextStoreError: Error, Sendable, Equatable {
    case persistenceFailed(reason: String)
}
