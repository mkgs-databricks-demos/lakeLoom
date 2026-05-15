import Foundation

/// Disk-persistent snapshot of the upload coordinator's queue.
///
/// Storage is a single JSON file at
/// `<Application Support>/Captures/upload-queue.json`. Atomic
/// writes go through a `<file>.tmp` rename so a crash mid-write
/// leaves the previous good snapshot intact.
///
/// The store is intentionally simple — it serializes the full
/// snapshot on every save. Queue size is bounded by user behavior
/// (a single capture session yields at most a handful of files),
/// so the cost is negligible compared to the cost of a half-written
/// queue file after a force-quit.
public actor UploadQueueStore {

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

    /// Convenience init that resolves the queue file under
    /// `Application Support/Captures/upload-queue.json`, creating
    /// the directory if needed. Used in production wiring.
    public static func makeDefault(
        logger: AppLogger = AppLogger(category: .ingest)
    ) throws -> UploadQueueStore {
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
        let url = dir.appendingPathComponent("upload-queue.json", isDirectory: false)
        return UploadQueueStore(fileURL: url, logger: logger)
    }

    /// Read the persisted snapshot. Returns `[]` if the file
    /// doesn't exist or contains an unreadable payload (logged at
    /// `warning` so the support bundle captures it).
    public func load() async -> [PendingUpload] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            return snapshot.uploads
        } catch {
            await logger.warning(
                "upload.queue.load_failed",
                metadata: [
                    "reason": .string(error.localizedDescription)
                ]
            )
            return []
        }
    }

    /// Replace the on-disk snapshot. Atomic via tmp+rename so a crash
    /// mid-write leaves the previous snapshot intact.
    public func save(_ uploads: [PendingUpload]) async throws {
        let snapshot = Snapshot(uploads: uploads)
        let data: Data
        do {
            data = try encoder.encode(snapshot)
        } catch {
            throw UploadCoordinatorError.persistenceFailed(reason: "encode: \(error.localizedDescription)")
        }
        let tmpURL = fileURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmpURL, options: [.atomic])
            // `replaceItemAt` is the atomic-rename primitive on
            // Foundation; it handles same-volume rename + permission
            // preservation correctly across iOS / macOS quirks.
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
        } catch {
            // If the rename fell over, leave whatever was at
            // `fileURL` in place (probably the prior good snapshot)
            // and clean up the tmp.
            try? FileManager.default.removeItem(at: tmpURL)
            throw UploadCoordinatorError.persistenceFailed(reason: "write: \(error.localizedDescription)")
        }
    }

    /// Delete the on-disk snapshot. Used by tests; not exposed on
    /// the coordinator's public surface.
    public func clear() async {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private struct Snapshot: Codable {
        let uploads: [PendingUpload]
    }
}
