import DequeModule
import Foundation

/// Bounded in-memory ring buffer of recent ``LogEntry`` records.
///
/// ``AppLogger`` writes to both Apple's unified logging (``OSLog``)
/// and to this collector. The in-app log viewer (Module 09 §7) reads
/// from here; the support bundle (Module 09 §3.5) snapshots it.
///
/// Default capacity is 1000 entries — once full, the oldest entry
/// is evicted FIFO. Capacity is configurable per init for tests.
public actor LogEntryCollector {

    /// Process-wide singleton. ``AppLogger`` defaults to writing here.
    public static let shared = LogEntryCollector(capacity: 1000)

    private var entries: Deque<LogEntry> = []
    private let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "LogEntryCollector capacity must be > 0")
        self.capacity = capacity
    }

    public func append(_ entry: LogEntry) {
        if entries.count >= capacity {
            _ = entries.popFirst()
        }
        entries.append(entry)
    }

    /// Snapshot of all currently-buffered entries, oldest first.
    public func snapshot() -> [LogEntry] {
        Array(entries)
    }

    /// Snapshot filtered by minimum level (inclusive) and category set.
    /// Used by the in-app log viewer's filter UI.
    public func snapshot(minimumLevel: LogLevel? = nil, categories: Set<LogCategory>? = nil) -> [LogEntry] {
        entries.filter { entry in
            if let minimumLevel, entry.level < minimumLevel { return false }
            if let categories, !categories.contains(entry.category) { return false }
            return true
        }
    }

    public func clear() {
        entries.removeAll(keepingCapacity: true)
    }

    public var count: Int {
        entries.count
    }

    public var configuredCapacity: Int {
        capacity
    }
}
