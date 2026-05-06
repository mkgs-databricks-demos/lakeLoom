import Foundation

/// Identifies a monotonically-increasing counter in ``MetricsRegistry``.
/// Categories follow ``LogCategory`` so the diagnostics screen can
/// group counters per-module without a separate mapping table.
public struct CounterKey: Sendable, Hashable, Codable {
    public let category: LogCategory
    public let name: String

    public init(category: LogCategory, name: String) {
        self.category = category
        self.name = name
    }
}

/// Identifies a settable gauge — an instantaneous numeric value
/// (queue depth, file size, etc.).
public struct GaugeKey: Sendable, Hashable, Codable {
    public let category: LogCategory
    public let name: String

    public init(category: LogCategory, name: String) {
        self.category = category
        self.name = name
    }
}

/// Identifies a histogram — a bounded buffer of recent samples.
public struct HistogramKey: Sendable, Hashable, Codable {
    public let category: LogCategory
    public let name: String

    public init(category: LogCategory, name: String) {
        self.category = category
        self.name = name
    }
}
