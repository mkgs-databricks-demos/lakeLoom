import Foundation

/// Errors produced by ``CoreDataStack`` operations. Most callers don't need
/// to pattern-match these — the AppCoordinator's bootstrap path catches the
/// stack-level errors and routes the user to a "Reset local data" recovery
/// affordance.
public enum CoreDataStackError: Error, Sendable, Equatable {
    /// `LakeloomStore.xcdatamodeld` was missing from the app bundle.
    case modelNotFound(name: String)

    /// Couldn't resolve a writable URL for the SQLite store under
    /// `<AppSupport>/Persistence/`.
    case storeFileURLUnresolvable

    /// Migration from an older model version failed. ``reason`` carries
    /// the underlying NSError's localizedDescription for diagnostics.
    case migrationFailed(reason: String)

    /// `loadPersistentStores` failed for a non-migration reason.
    case openFailed(reason: String)

    /// SQLite reported corruption (`SQLITE_CORRUPT` / `SQLITE_NOTADB`,
    /// codes 11 and 26 respectively). The recovery path is "Reset local
    /// data" — the data is reconstructible from Databricks.
    case corruptStore(reason: String)

    /// Reset (delete-then-reinitialize) failed. Almost always a file-system
    /// issue (permissions, disk full).
    case resetFailed(reason: String)

    /// A background context save failed.
    case writeContextSaveFailed(reason: String)

    /// Programmer error: an entity referenced by name that isn't in the model.
    case unknownEntity(name: String)
}
