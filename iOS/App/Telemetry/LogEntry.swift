import Foundation

/// A single recorded log line. ``LogEntryCollector`` keeps a bounded
/// ring buffer of these; ``SupportBundle`` (Module 09 §3.5, future)
/// serializes them to JSON for sharing.
///
/// See Module 09 §4.2.
public struct LogEntry: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String
    public let metadata: LogMetadata

    /// Typed error case name when ``level`` is `.error` or `.fault` and
    /// the call site supplied an `errorCode` metadata pair. Surfaced
    /// here as a dedicated field so the in-app viewer can group errors
    /// by code without parsing the metadata array.
    public let errorCode: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        level: LogLevel,
        category: LogCategory,
        message: String,
        metadata: LogMetadata,
        errorCode: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
        self.errorCode = errorCode
    }
}
