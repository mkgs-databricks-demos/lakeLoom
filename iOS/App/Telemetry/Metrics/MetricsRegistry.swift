import DequeModule
import Foundation

/// Process-wide store of telemetry counters, gauges, and histograms.
///
/// All operations are async because the registry is an actor — concurrent
/// callers (modules incrementing counters from their own actors) serialize
/// through it. The cost per operation is one actor hop, which is negligible
/// against the work being measured.
///
/// See Module 09 §3.3 and §6.
public actor MetricsRegistry {

    /// Process-wide singleton. Modules write here unless a test injects
    /// an isolated instance.
    public static let shared = MetricsRegistry(histogramCapacity: 1024)

    private let histogramCapacity: Int
    private let nowProvider: @Sendable () -> Date
    private var counters: [CounterKey: Int64] = [:]
    private var gauges: [GaugeKey: Double] = [:]
    private var histogramBuffers: [HistogramKey: Deque<Double>] = [:]

    public init(
        histogramCapacity: Int = 1024,
        nowProvider: @Sendable @escaping () -> Date = Date.init
    ) {
        precondition(histogramCapacity > 0, "histogram capacity must be > 0")
        self.histogramCapacity = histogramCapacity
        self.nowProvider = nowProvider
    }

    // MARK: Counters

    public func increment(_ key: CounterKey, by delta: Int64 = 1) {
        counters[key, default: 0] += delta
    }

    public func get(_ key: CounterKey) -> Int64 {
        counters[key, default: 0]
    }

    // MARK: Gauges

    public func set(_ key: GaugeKey, to value: Double) {
        gauges[key] = value
    }

    public func get(_ key: GaugeKey) -> Double? {
        gauges[key]
    }

    // MARK: Histograms

    public func observe(_ key: HistogramKey, value: Double) {
        var buffer = histogramBuffers[key] ?? Deque<Double>()
        if buffer.count >= histogramCapacity {
            _ = buffer.popFirst()
        }
        buffer.append(value)
        histogramBuffers[key] = buffer
    }

    public func snapshot(_ key: HistogramKey) -> HistogramSnapshot {
        guard let buffer = histogramBuffers[key] else { return .empty }
        return HistogramSnapshot.compute(from: Array(buffer))
    }

    // MARK: Snapshots

    public func snapshotAll() -> MetricsSnapshot {
        var histograms: [HistogramKey: HistogramSnapshot] = [:]
        for (key, buffer) in histogramBuffers {
            histograms[key] = HistogramSnapshot.compute(from: Array(buffer))
        }
        return MetricsSnapshot(
            counters: counters,
            gauges: gauges,
            histograms: histograms,
            capturedAt: nowProvider()
        )
    }

    /// Clear all metrics. Used by tests; the diagnostics screen has a
    /// "reset metrics" button that calls into this for support cases.
    public func reset() {
        counters.removeAll(keepingCapacity: true)
        gauges.removeAll(keepingCapacity: true)
        histogramBuffers.removeAll(keepingCapacity: true)
    }

    // MARK: Test introspection

    /// Test-only — current sample count for a histogram buffer.
    /// Production code should use ``snapshot(_:)`` for percentiles.
    public func sampleCount(for key: HistogramKey) -> Int {
        histogramBuffers[key]?.count ?? 0
    }
}
