import Foundation

/// Canonical names for every metric in the app. Adding a metric is a
/// deliberate change — it shows up in the diagnostics screen, the
/// support bundle, and any future telemetry pipeline.
///
/// Per Module 09 §6. Only the names actually referenced from a module
/// land here; this file is grown additively as modules instrument
/// themselves.
public enum MetricsCatalog {

    public enum Auth {
        public static let signInSuccess = CounterKey(category: .auth, name: "auth.signin.success")
        public static let signInCancelled = CounterKey(category: .auth, name: "auth.signin.canceled")
        public static let signInFailed = CounterKey(category: .auth, name: "auth.signin.failed")
        public static let refreshAttempted = CounterKey(category: .auth, name: "auth.refresh.attempted")
        public static let refreshSuccess = CounterKey(category: .auth, name: "auth.refresh.success")
        public static let refreshFailed = CounterKey(category: .auth, name: "auth.refresh.failed")
        public static let refreshDurationMs = HistogramKey(category: .auth, name: "auth.refresh.duration_ms")
    }

    public enum Telemetry {
        public static let logEntriesAppended = CounterKey(
            category: .telemetry,
            name: "telemetry.log_entries.appended"
        )
        public static let logBufferDepth = GaugeKey(
            category: .telemetry,
            name: "telemetry.log_buffer.depth"
        )
    }
}
