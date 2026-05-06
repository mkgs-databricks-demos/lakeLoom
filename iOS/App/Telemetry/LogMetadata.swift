import Foundation

/// A type-safe key/value container for structured log metadata.
///
/// Constructed via dictionary literal — this is the form that flows
/// through every ``AppLogger`` call site:
///
/// ```swift
/// await logger.info("drainer cycle complete",
///                   metadata: ["batch.size": .int(48),
///                              "duration.ms": .int(143),
///                              "outcome": .string("success")])
/// ```
///
/// Order is preserved (insertion order) so log rendering is stable
/// across sessions.
///
/// See Module 09 §3.1 and §5.1.
public struct LogMetadata: Sendable, Equatable, Codable, ExpressibleByDictionaryLiteral {
    public let entries: [(key: String, value: LogValue)]

    public init(_ pairs: [(String, LogValue)] = []) {
        self.entries = pairs.map { (key: $0.0, value: $0.1) }
    }

    public init(dictionaryLiteral elements: (String, LogValue)...) {
        // Preserve literal order — Swift's dictionary literal preserves
        // the order the user wrote, even though Dictionary itself doesn't.
        self.entries = elements.map { (key: $0.0, value: $0.1) }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Render all entries as `key=value` pairs joined by spaces.
    /// Used for os.log message construction and the in-app viewer.
    public func renderInline() -> String {
        entries
            .map { "\($0.key)=\($0.value.render())" }
            .joined(separator: " ")
    }

    // MARK: Equatable

    public static func == (lhs: LogMetadata, rhs: LogMetadata) -> Bool {
        guard lhs.entries.count == rhs.entries.count else { return false }
        for (l, r) in zip(lhs.entries, rhs.entries) {
            if l.key != r.key || l.value != r.value { return false }
        }
        return true
    }

    // MARK: Codable
    //
    // Encodes as an ordered array of `{key, value}` objects so the
    // wire form preserves insertion order.

    private struct Pair: Codable {
        let key: String
        let value: LogValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let pairs = try container.decode([Pair].self)
        self.entries = pairs.map { (key: $0.key, value: $0.value) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries.map { Pair(key: $0.key, value: $0.value) })
    }
}
