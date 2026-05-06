import Foundation

/// Snapshot of ``CoreDataStack`` health and storage usage. Surfaced via
/// Settings → Diagnostics (when that screen lands in Module 08) and
/// included in the support bundle.
///
/// All file-size values are in bytes. SQLite file size includes the
/// main database; ``walFileSizeBytes`` covers the `.sqlite-wal` sidecar
/// (a large WAL means lots of unflushed writes — diagnostic signal).
public struct CoreDataStackDiagnostics: Sendable, Equatable {
    public let storeFileURL: URL
    public let storeFileSizeBytes: Int64
    public let walFileSizeBytes: Int64
    public let modelVersion: String
    public let lastInitializedAt: Date
    public let migrationOccurredAtLaunch: Bool
    public let migrationDurationMs: Int64?

    public init(
        storeFileURL: URL,
        storeFileSizeBytes: Int64,
        walFileSizeBytes: Int64,
        modelVersion: String,
        lastInitializedAt: Date,
        migrationOccurredAtLaunch: Bool,
        migrationDurationMs: Int64?
    ) {
        self.storeFileURL = storeFileURL
        self.storeFileSizeBytes = storeFileSizeBytes
        self.walFileSizeBytes = walFileSizeBytes
        self.modelVersion = modelVersion
        self.lastInitializedAt = lastInitializedAt
        self.migrationOccurredAtLaunch = migrationOccurredAtLaunch
        self.migrationDurationMs = migrationDurationMs
    }
}
