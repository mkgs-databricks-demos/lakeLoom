import Foundation
import Testing

@testable import LakeloomApp

@Suite("MetricsRegistry counters")
struct MetricsRegistryCounterTests {

    @Test("increment defaults to +1; explicit delta accumulates")
    func incrementsAccumulate() async {
        let registry = MetricsRegistry()
        let key = CounterKey(category: .auth, name: "auth.signin.success")
        await registry.increment(key)
        await registry.increment(key)
        await registry.increment(key, by: 3)
        let total = await registry.get(key)
        #expect(total == 5)
    }

    @Test("get on a counter that's never been incremented returns 0")
    func getDefaultsToZero() async {
        let registry = MetricsRegistry()
        let key = CounterKey(category: .auth, name: "auth.never_set")
        let total = await registry.get(key)
        #expect(total == 0)
    }

    @Test("counters are atomic under concurrent increments")
    func concurrentIncrements() async {
        let registry = MetricsRegistry()
        let key = CounterKey(category: .telemetry, name: "concurrency.test")
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<1_000 {
                group.addTask { await registry.increment(key) }
            }
            await group.waitForAll()
        }
        let total = await registry.get(key)
        #expect(total == 1_000)
    }
}

@Suite("MetricsRegistry gauges")
struct MetricsRegistryGaugeTests {

    @Test("set + get round trip")
    func roundTrip() async {
        let registry = MetricsRegistry()
        let key = GaugeKey(category: .ingest, name: "outbox.depth")
        await registry.set(key, to: 47)
        let value = await registry.get(key)
        #expect(value == 47)
    }

    @Test("get on an unset gauge returns nil")
    func getReturnsNilWhenUnset() async {
        let registry = MetricsRegistry()
        let key = GaugeKey(category: .ingest, name: "never.set")
        let value = await registry.get(key)
        #expect(value == nil)
    }

    @Test("set overwrites the previous value")
    func setOverwrites() async {
        let registry = MetricsRegistry()
        let key = GaugeKey(category: .ingest, name: "outbox.depth")
        await registry.set(key, to: 10)
        await registry.set(key, to: 25)
        let value = await registry.get(key)
        #expect(value == 25)
    }
}

@Suite("MetricsRegistry histograms")
struct MetricsRegistryHistogramTests {

    @Test("histogram with no samples returns the empty snapshot")
    func emptyHistogramSnapshot() async {
        let registry = MetricsRegistry()
        let key = HistogramKey(category: .ingest, name: "send.latency_ms")
        let snapshot = await registry.snapshot(key)
        #expect(snapshot == .empty)
    }

    @Test("histogram aggregates count, sum, mean, and percentiles correctly")
    func aggregatesCorrectly() async {
        let registry = MetricsRegistry()
        let key = HistogramKey(category: .ingest, name: "send.latency_ms")
        let samples: [Double] = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]
        for s in samples {
            await registry.observe(key, value: s)
        }
        let snapshot = await registry.snapshot(key)
        #expect(snapshot.count == 10)
        #expect(snapshot.sum == 550)
        #expect(snapshot.mean == 55)
        #expect(snapshot.min == 10)
        #expect(snapshot.max == 100)
        // p50 of [10,20,...,100] with linear interpolation at rank 4.5 → (50+60)/2 = 55
        #expect(snapshot.p50 == 55)
        // p95 at rank 8.55 → 90 + 0.55*(100-90) = 95.5
        #expect(abs(snapshot.p95 - 95.5) < 1e-9)
    }

    @Test("histogram ring evicts oldest samples beyond capacity")
    func histogramRingEviction() async {
        let registry = MetricsRegistry(histogramCapacity: 3)
        let key = HistogramKey(category: .ingest, name: "ring.test")
        for s in [1.0, 2.0, 3.0, 4.0, 5.0] {
            await registry.observe(key, value: s)
        }
        let count = await registry.sampleCount(for: key)
        #expect(count == 3)
        let snapshot = await registry.snapshot(key)
        // After eviction the buffer is [3, 4, 5].
        #expect(snapshot.min == 3)
        #expect(snapshot.max == 5)
        #expect(snapshot.sum == 12)
    }
}

@Suite("MetricsRegistry snapshotAll")
struct MetricsRegistrySnapshotAllTests {

    @Test("snapshotAll captures counters, gauges, and histograms together")
    func capturesEverything() async {
        let registry = MetricsRegistry()
        let counter = CounterKey(category: .auth, name: "auth.signin.success")
        let gauge = GaugeKey(category: .ingest, name: "outbox.depth")
        let histogram = HistogramKey(category: .auth, name: "auth.refresh.duration_ms")

        await registry.increment(counter, by: 7)
        await registry.set(gauge, to: 12)
        await registry.observe(histogram, value: 100)
        await registry.observe(histogram, value: 200)

        let snapshot = await registry.snapshotAll()
        #expect(snapshot.counters[counter] == 7)
        #expect(snapshot.gauges[gauge] == 12)
        let h = snapshot.histograms[histogram]
        #expect(h?.count == 2)
        #expect(h?.sum == 300)
    }

    @Test("reset clears every metric")
    func resetClears() async {
        let registry = MetricsRegistry()
        await registry.increment(CounterKey(category: .auth, name: "x"))
        await registry.set(GaugeKey(category: .auth, name: "y"), to: 1)
        await registry.observe(HistogramKey(category: .auth, name: "z"), value: 1)
        await registry.reset()
        let snapshot = await registry.snapshotAll()
        #expect(snapshot.counters.isEmpty)
        #expect(snapshot.gauges.isEmpty)
        #expect(snapshot.histograms.isEmpty)
    }
}

@Suite("HistogramSnapshot.compute")
struct HistogramSnapshotComputeTests {

    @Test("empty samples → .empty snapshot")
    func emptySamples() {
        let snapshot = HistogramSnapshot.compute(from: [])
        #expect(snapshot == .empty)
    }

    @Test("single sample sets all stats to that value")
    func singleSample() {
        let snapshot = HistogramSnapshot.compute(from: [42])
        #expect(snapshot.count == 1)
        #expect(snapshot.min == 42)
        #expect(snapshot.max == 42)
        #expect(snapshot.mean == 42)
        #expect(snapshot.p50 == 42)
        #expect(snapshot.p95 == 42)
        #expect(snapshot.p99 == 42)
    }

    @Test("unsorted input produces same snapshot as sorted input")
    func sortInsensitive() {
        let unsorted = HistogramSnapshot.compute(from: [50, 10, 30, 20, 40])
        let sorted = HistogramSnapshot.compute(from: [10, 20, 30, 40, 50])
        #expect(unsorted == sorted)
    }
}
