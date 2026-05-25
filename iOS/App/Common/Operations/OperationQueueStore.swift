import Foundation

/// Disk-persistent snapshot of the ``OperationQueue``'s pending ops.
///
/// Storage: a single JSON file at
/// `<Application Support>/Operations/operation-queue.json`. Atomic
/// writes via `Data.write(.atomic)`. Survives force-quit so an op
/// enqueued while offline still drains on the next launch when
/// reachability returns.
///
/// Same shape + pattern as ``UploadQueueStore`` — and intentionally
/// so: when we eventually surface a "diagnostic outbox" UI showing
/// both pending uploads and pending control-plane ops, the two
/// stores compose cleanly.
public actor OperationQueueStore {

    private let fileURL: URL
    private let logger: AppLogger
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileURL: URL,
        logger: AppLogger = AppLogger(category: .ingest)
    ) {
        self.fileURL = fileURL
        self.logger = logger
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    /// Convenience init that resolves the file under
    /// `Application Support/Operations/operation-queue.json`,
    /// creating the parent directory if needed and flagging it as
    /// excluded from iCloud backup.
    public static func makeDefault(
        logger: AppLogger = AppLogger(category: .ingest)
    ) throws -> OperationQueueStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("Operations", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dirToFlag = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dirToFlag.setResourceValues(values)
        let url = dir.appendingPathComponent("operation-queue.json", isDirectory: false)
        return OperationQueueStore(fileURL: url, logger: logger)
    }

    /// Read the persisted queue. Returns an empty array when the
    /// file doesn't exist or the payload can't be decoded
    /// (warning-logged so the support bundle catches corruption).
    public func load() async -> [PendingOperation] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([PendingOperation].self, from: data)
        } catch {
            await logger.warning(
                "operation.queue.load_failed",
                metadata: ["reason": .string(error.localizedDescription)]
            )
            return []
        }
    }

    /// Write the full queue snapshot atomically. Failures are
    /// surfaced via the caller so the coordinator can decide
    /// whether to retry / surface to the user.
    public func save(_ operations: [PendingOperation]) async throws {
        let data = try encoder.encode(operations)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Wipe the file (used on sign-out / app reset).
    public func clear() async {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
