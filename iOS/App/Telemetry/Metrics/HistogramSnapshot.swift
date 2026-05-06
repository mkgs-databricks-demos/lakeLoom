import Foundation

/// Aggregated stats over the samples currently in a histogram buffer.
///
/// Computed on demand from the raw samples — the registry doesn't
/// maintain rolling p99s itself. This keeps the per-observation cost
/// O(1) and pays the percentile sort only when someone asks (e.g.,
/// the diagnostics screen render).
public struct HistogramSnapshot: Sendable, Equatable, Codable {
    public let count: Int
    public let sum: Double
    public let min: Double
    public let max: Double
    public let mean: Double
    public let p50: Double
    public let p95: Double
    public let p99: Double

    public static let empty = HistogramSnapshot(
        count: 0, sum: 0, min: 0, max: 0, mean: 0, p50: 0, p95: 0, p99: 0
    )

    public init(
        count: Int,
        sum: Double,
        min: Double,
        max: Double,
        mean: Double,
        p50: Double,
        p95: Double,
        p99: Double
    ) {
        self.count = count
        self.sum = sum
        self.min = min
        self.max = max
        self.mean = mean
        self.p50 = p50
        self.p95 = p95
        self.p99 = p99
    }

    /// Compute a snapshot from raw samples. Caller passes the raw
    /// (unsorted) buffer; this routine sorts a copy and computes the
    /// percentiles. Returns ``empty`` on an empty buffer.
    public static func compute(from samples: [Double]) -> HistogramSnapshot {
        guard !samples.isEmpty else { return .empty }
        let sorted = samples.sorted()
        let count = sorted.count
        let sum = sorted.reduce(0, +)
        let mean = sum / Double(count)
        return HistogramSnapshot(
            count: count,
            sum: sum,
            min: sorted.first ?? 0,
            max: sorted.last ?? 0,
            mean: mean,
            p50: percentile(0.50, sortedSamples: sorted),
            p95: percentile(0.95, sortedSamples: sorted),
            p99: percentile(0.99, sortedSamples: sorted)
        )
    }

    /// Linear-interpolation percentile. `p` is in [0, 1].
    private static func percentile(_ p: Double, sortedSamples samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        if samples.count == 1 { return samples[0] }
        let rank = p * Double(samples.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        if lower == upper { return samples[lower] }
        let weight = rank - Double(lower)
        return samples[lower] * (1 - weight) + samples[upper] * weight
    }
}

/// Snapshot of every counter, gauge, and histogram at one point in time.
public struct MetricsSnapshot: Sendable, Equatable, Codable {
    public let counters: [CounterKey: Int64]
    public let gauges: [GaugeKey: Double]
    public let histograms: [HistogramKey: HistogramSnapshot]
    public let capturedAt: Date

    public init(
        counters: [CounterKey: Int64],
        gauges: [GaugeKey: Double],
        histograms: [HistogramKey: HistogramSnapshot],
        capturedAt: Date
    ) {
        self.counters = counters
        self.gauges = gauges
        self.histograms = histograms
        self.capturedAt = capturedAt
    }

    public static let empty = MetricsSnapshot(
        counters: [:], gauges: [:], histograms: [:], capturedAt: .distantPast
    )
}
