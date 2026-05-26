import Foundation

/// Disk-persistent snapshot of the per-workspace project list cache.
///
/// Storage is a single JSON file at
/// `<Application Support>/Projects/project-list.json`. Atomic writes
/// go through a `<file>.tmp` rename so a crash mid-write leaves the
/// previous good snapshot intact.
///
/// Pairs with the in-memory ``ProjectCache`` (Module 06 §10.1):
/// `ProjectCache` is the hot path — synchronous reads, 5-minute TTL,
/// `inFlight` dedup. `ProjectListStore` is the cold-launch survival
/// layer — when the in-memory cache is empty AND we're offline, the
/// store lets the user keep working with the projects they saw most
/// recently. Every `ProjectCache` write fans out to a store write so
/// the two stay in sync.
///
/// Storage shape: `[workspaceID: [ProjectMetadata]]`. We persist
/// every project the cache has ever seen, not just the active
/// workspace — small data, cheap to keep, and survives workspace
/// switching cleanly. `clear()` wipes the file on sign-out.
public actor ProjectListStore {

    private let fileURL: URL
    private let logger: AppLogger
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileURL: URL,
        logger: AppLogger = AppLogger(category: .projects)
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
    /// `Application Support/Projects/project-list.json`, creating
    /// the parent directory if needed and flagging it as excluded
    /// from iCloud backup (Databricks side is the source of truth).
    public static func makeDefault(
        logger: AppLogger = AppLogger(category: .projects)
    ) throws -> ProjectListStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dirToFlag = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dirToFlag.setResourceValues(values)
        let url = dir.appendingPathComponent("project-list.json", isDirectory: false)
        return ProjectListStore(fileURL: url, logger: logger)
    }

    // MARK: - Load

    /// Read the persisted snapshot for `workspaceID`. Returns nil
    /// when the file doesn't exist or contains a payload that can't
    /// be parsed (warning-logged so the support bundle captures it).
    public func load(workspaceID: String) async -> [ProjectMetadata]? {
        let all = await loadAll()
        return all[workspaceID]
    }

    /// Full dictionary (all workspaces). Used by diagnostics; the
    /// hot path is the workspace-scoped `load`.
    public func loadAll() async -> [String: [ProjectMetadata]] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([String: [ProjectMetadata]].self, from: data)
        } catch {
            await logger.warning(
                "projects.store.load_failed",
                metadata: ["reason": .string(error.localizedDescription)]
            )
            return [:]
        }
    }

    // MARK: - Save

    /// Replace the persisted entry for `workspaceID` with `projects`.
    /// Other workspaces' entries are preserved. Atomic write via
    /// `.atomic` on `Data.write(to:options:)`.
    public func save(_ projects: [ProjectMetadata], workspaceID: String) async {
        var all = await loadAll()
        all[workspaceID] = projects
        await writeAll(all)
    }

    /// Drop the entry for `workspaceID` (used on sign-out).
    public func clear(workspaceID: String) async {
        var all = await loadAll()
        guard all.removeValue(forKey: workspaceID) != nil else { return }
        await writeAll(all)
    }

    /// Wipe the entire store (used on a full reset, e.g., user
    /// purges device state).
    public func clearAll() async {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func writeAll(_ all: [String: [ProjectMetadata]]) async {
        do {
            let data = try encoder.encode(all)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            await logger.warning(
                "projects.store.save_failed",
                metadata: ["reason": .string(error.localizedDescription)]
            )
        }
    }
}
