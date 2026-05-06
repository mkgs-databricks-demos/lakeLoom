import CoreData
import Foundation

/// Production ``CoreDataStacking`` backed by SQLite under
/// `<AppSupport>/Persistence/LakeloomStore.sqlite`.
///
/// All public methods route through the underlying actor, so concurrent
/// callers serialize through the stack. The `viewContext` is
/// `@MainActor`-bound; background contexts are created on demand and
/// returned to the caller for one unit of work each.
public actor CoreDataStack: CoreDataStacking {

    // MARK: Configuration

    public static let modelName = "LakeloomStore"
    public static let modelVersion = "V1"

    private let storeURL: URL
    private let inMemory: Bool
    private let logger: AppLogger
    private let nowProvider: @Sendable () -> Date

    // MARK: State

    private var container: NSPersistentContainer?
    private var lastInitializedAt: Date?
    private var migrationOccurredAtLaunch = false
    private var migrationDurationMs: Int64?

    // MARK: Init

    public init(
        storeURL: URL? = nil,
        inMemory: Bool = false,
        logger: AppLogger = AppLogger(category: .persistence),
        nowProvider: @Sendable @escaping () -> Date = Date.init
    ) throws {
        self.inMemory = inMemory
        self.logger = logger
        self.nowProvider = nowProvider
        if let storeURL {
            self.storeURL = storeURL
        } else if inMemory {
            self.storeURL = URL(fileURLWithPath: "/dev/null/LakeloomStore.sqlite")
        } else {
            self.storeURL = try CoreDataStack.defaultStoreURL()
        }
    }

    // MARK: Lifecycle

    public func initialize() async throws {
        if container != nil { return }

        guard let modelURL = Bundle.main.url(forResource: Self.modelName, withExtension: "momd") else {
            throw CoreDataStackError.modelNotFound(name: Self.modelName)
        }
        guard let model = NSManagedObjectModel(contentsOf: modelURL) else {
            throw CoreDataStackError.modelNotFound(name: Self.modelName)
        }

        let container = NSPersistentContainer(name: Self.modelName, managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: storeURL)
        if inMemory {
            description.type = NSInMemoryStoreType
        } else {
            description.type = NSSQLiteStoreType
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(
                true as NSNumber,
                forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey
            )
            description.setOption(
                FileProtectionType.completeUntilFirstUserAuthentication as NSObject,
                forKey: NSPersistentStoreFileProtectionKey
            )
            description.setValue("WAL" as NSString, forPragmaNamed: "journal_mode")
            description.setValue("NORMAL" as NSString, forPragmaNamed: "synchronous")
        }
        container.persistentStoreDescriptions = [description]

        let migrationStart = nowProvider()
        let willMigrate = inMemory ? false : storeRequiresMigration(at: storeURL, model: model)

        try await Self.loadStore(container: container)

        let migrationDuration = nowProvider().timeIntervalSince(migrationStart) * 1000
        migrationOccurredAtLaunch = willMigrate
        migrationDurationMs = willMigrate ? Int64(migrationDuration) : nil

        await Self.configureViewContext(container.viewContext)

        self.container = container
        self.lastInitializedAt = nowProvider()

        await logger.info(
            "stack initialized",
            metadata: [
                "model": .string(Self.modelName),
                "version": .string(Self.modelVersion),
                "in_memory": .bool(inMemory),
                "migrated": .bool(willMigrate)
            ]
        )
    }

    public func shutdown() async {
        guard let container else { return }
        for store in container.persistentStoreCoordinator.persistentStores {
            try? container.persistentStoreCoordinator.remove(store)
        }
        self.container = nil
    }

    public func reset() async throws {
        let storeURL = self.storeURL
        await shutdown()
        if !inMemory {
            do {
                try Self.removeStoreFiles(at: storeURL)
            } catch {
                throw CoreDataStackError.resetFailed(reason: error.localizedDescription)
            }
        }
        try await initialize()
        await logger.notice("stack reset to empty state", metadata: ["in_memory": .bool(inMemory)])
    }

    public func diagnostics() async throws -> CoreDataStackDiagnostics {
        guard let container else {
            throw CoreDataStackError.openFailed(reason: "stack not initialized")
        }
        let storeFile = container.persistentStoreCoordinator.persistentStores.first?.url
        let resolvedURL = storeFile ?? storeURL
        let storeBytes = inMemory ? 0 : Self.fileSize(at: resolvedURL)
        let walURL = resolvedURL.deletingLastPathComponent()
            .appendingPathComponent(resolvedURL.lastPathComponent + "-wal")
        let walBytes = inMemory ? 0 : Self.fileSize(at: walURL)
        return CoreDataStackDiagnostics(
            storeFileURL: resolvedURL,
            storeFileSizeBytes: storeBytes,
            walFileSizeBytes: walBytes,
            modelVersion: Self.modelVersion,
            lastInitializedAt: lastInitializedAt ?? nowProvider(),
            migrationOccurredAtLaunch: migrationOccurredAtLaunch,
            migrationDurationMs: migrationDurationMs
        )
    }

    // MARK: Contexts

    public var viewContext: NSManagedObjectContext {
        get async {
            guard let container else {
                fatalError("CoreDataStack.viewContext accessed before initialize()")
            }
            return container.viewContext
        }
    }

    public func newBackgroundContext() async throws -> NSManagedObjectContext {
        guard let container else {
            throw CoreDataStackError.openFailed(reason: "stack not initialized")
        }
        let context = container.newBackgroundContext()
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        return context
    }

    public func performWrite<T: Sendable>(
        _ block: @escaping @Sendable (NSManagedObjectContext) throws -> T
    ) async throws -> T {
        guard let container else {
            throw CoreDataStackError.openFailed(reason: "stack not initialized")
        }
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        return try await context.perform {
            let result = try block(context)
            if context.hasChanges {
                do {
                    try context.save()
                } catch {
                    throw CoreDataStackError.writeContextSaveFailed(
                        reason: error.localizedDescription
                    )
                }
            }
            return result
        }
    }

    // MARK: - Helpers

    @MainActor
    private static func configureViewContext(_ context: NSManagedObjectContext) {
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
    }

    private static func loadStore(container: NSPersistentContainer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            container.loadPersistentStores { _, error in
                if let error = error as NSError? {
                    if Self.isCorruption(error: error) {
                        continuation.resume(throwing: CoreDataStackError.corruptStore(
                            reason: error.localizedDescription
                        ))
                        return
                    }
                    if Self.isMigrationFailure(error: error) {
                        continuation.resume(throwing: CoreDataStackError.migrationFailed(
                            reason: error.localizedDescription
                        ))
                        return
                    }
                    continuation.resume(throwing: CoreDataStackError.openFailed(
                        reason: error.localizedDescription
                    ))
                    return
                }
                continuation.resume()
            }
        }
    }

    private func storeRequiresMigration(at url: URL, model: NSManagedObjectModel) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let metadata: [String: Any]
        do {
            metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                ofType: NSSQLiteStoreType,
                at: url
            )
        } catch {
            return false
        }
        return !model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
    }

    public static func defaultStoreURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let storeDir = appSupport.appendingPathComponent("Persistence", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storeDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        // Excluding from iCloud backup keeps user backups small — the
        // data is reconstructible from Databricks anyway.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dirURL = storeDir
        try? dirURL.setResourceValues(values)
        return storeDir.appendingPathComponent("\(Self.modelName).sqlite")
    }

    private static func removeStoreFiles(at url: URL) throws {
        let fm = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            let target = URL(fileURLWithPath: url.path + suffix)
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
        }
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber
        else { return 0 }
        return size.int64Value
    }

    private static func isCorruption(error: NSError) -> Bool {
        // SQLite codes 11 (SQLITE_CORRUPT) and 26 (SQLITE_NOTADB).
        let sqliteCode = (error.userInfo[NSSQLiteErrorDomain] as? NSNumber)?.intValue
            ?? (error.userInfo["NSSQLiteErrorDomain"] as? NSNumber)?.intValue
        return sqliteCode == 11 || sqliteCode == 26
    }

    private static func isMigrationFailure(error: NSError) -> Bool {
        // Core Data uses a small set of codes for migration-related issues.
        // See NSCoreDataError.h: 134110 (migrationMissingSourceModelError),
        // 134120 (migrationError), 134130 (migrationCancelled).
        let migrationCodes: Set<Int> = [134_110, 134_120, 134_130]
        return migrationCodes.contains(error.code)
    }
}
