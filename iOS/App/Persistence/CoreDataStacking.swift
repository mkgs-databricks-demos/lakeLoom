import CoreData
import Foundation

/// The unified Core Data stack used by IngestService (outbox), StorageService
/// (session records), and any future module that needs durable local state.
///
/// One implementation backs the production app (``CoreDataStack`` — SQLite
/// under `<AppSupport>/Persistence/LakeloomStore.sqlite`); another backs
/// unit tests (``InMemoryCoreDataStack`` — `NSInMemoryStoreType`, no disk).
///
/// Keep raw `NSManagedObject` instances inside the persistence layer.
/// Cross-actor handoff uses the `+DTO.swift` mirror types so the public
/// surface is `Sendable`-clean.
public protocol CoreDataStacking: Sendable {

    /// Bring the stack up. Idempotent. Resolves the store URL, runs any
    /// pending lightweight migration, opens the store, and configures the
    /// view context. Throws a typed ``CoreDataStackError`` on failure.
    func initialize() async throws

    /// Tear down the stack. Used for sign-out-all and the user-facing
    /// "Reset local data" flow.
    func shutdown() async

    /// Reset the local store: deletes the SQLite file (and sidecars) and
    /// re-initializes a fresh empty stack. Destructive — anything not yet
    /// drained from the outbox is lost. The recovery path the user
    /// confirms before this runs is the AppCoordinator's responsibility.
    func reset() async throws

    /// Snapshot of the stack's current diagnostic state.
    func diagnostics() async throws -> CoreDataStackDiagnostics

    /// Vend a fresh background context for one unit of write work. Each
    /// task should create its own; do not share across tasks. Production
    /// implementations return a `.privateQueueConcurrencyType` context.
    /// Most callers should prefer ``performWrite(_:)`` — this is the
    /// escape hatch for advanced fetch / batched insert patterns.
    func newBackgroundContext() async throws -> NSManagedObjectContext

    /// Convenience: perform a write on a background context, save if there
    /// are changes, and return the result. The block runs on the context's
    /// queue via `performAndWait`-style isolation, so callers can use the
    /// raw `NSManagedObject` API safely inside it.
    func performWrite<T: Sendable>(
        _ block: @escaping @Sendable (NSManagedObjectContext) throws -> T
    ) async throws -> T

    /// Read-only context for UI and lightweight reads. Bound to the main
    /// queue. Auto-merges saves from background contexts. Do not write
    /// through this context.
    var viewContext: NSManagedObjectContext { get async }
}
