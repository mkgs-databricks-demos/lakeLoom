import CoreData
import Foundation

/// Convenience for tests + previews — vends a fresh ``CoreDataStack``
/// configured with ``NSInMemoryStoreType`` so each test owns an
/// isolated store with no disk I/O.
///
/// Tests use:
///
/// ```swift
/// let stack = try await CoreDataStack.makeInMemory()
/// try await stack.initialize()
/// ```
extension CoreDataStack {

    /// Construct an in-memory stack. Throws only if the model can't be
    /// resolved (programming error — same root cause as a fresh app
    /// install missing its `.xcdatamodeld` bundle).
    public static func makeInMemory(
        nowProvider: @Sendable @escaping () -> Date = Date.init
    ) throws -> CoreDataStack {
        try CoreDataStack(inMemory: true, nowProvider: nowProvider)
    }
}
