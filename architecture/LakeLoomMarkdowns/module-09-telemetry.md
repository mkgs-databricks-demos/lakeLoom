# Module 09 — Telemetry, Logging, and Diagnostics

**Product:** Lakeloom
**Status:** Design — pre-implementation
**Last updated:** 2026-05-02
**Depends on:** None directly (foundation observability layer); used by all modules
**Depended on by:** All service modules and views for instrumentation

---

## 1. Purpose

The telemetry module is the unified observability layer for the iOS app. It owns:

- Structured logging for development and on-device diagnostic dumps
- Metric counters and histograms for the diagnostics UI
- Crash reporting hookup (framework integration, not the framework itself)
- A "support bundle" feature that exports a redacted diagnostic snapshot
- The privacy-by-design redaction rules — no PII or transcript content ever leaves the device through this channel
- A debug log buffer that can be inspected in Settings

This module does **not** send telemetry to a third-party analytics service in v1. All observability is local to the device and accessible only through Settings. If/when remote telemetry is added in v1.x or v2, it goes through the same redaction pipeline this module owns.

---

## 2. Design Principles

1. **Privacy by default.** Nothing leaves the device through this layer in v1. Even on-device logs redact transcript text, project names, and tokens.
2. **Structured over freeform.** Every log statement uses key-value pairs, not interpolated strings. Filtering and analysis depend on this.
3. **Use Apple's tools where they fit.** `Logger` (os.log unified logging) for system-integrated logging; `OSSignposter` for performance traces. Don't reinvent.
4. **Counters are cheap; histograms are bounded.** Counter increments are atomic and free. Histograms keep the last N samples, not unlimited time series.
5. **The support bundle is one tap.** A user encountering a problem can generate and share a self-contained diagnostic file without our developers walking them through a 10-step process.
6. **Crash reporting is opt-in only.** v1 uses Apple's built-in crash reporter; no third-party SDK. If a third party is added later, opt-in toggles in Settings.
7. **Logs have retention.** A bounded ring buffer for recent entries plus pruning of older entries. The app never grows unbounded log files.
8. **Redaction is the default.** Any string passed in might contain sensitive data; the module's API encourages typed values that are safe to log.
9. **Performance impact is negligible.** A single log call must cost <100 microseconds end-to-end. Anything slower is opt-in via debug flags.
10. **Debug builds and release builds have different verbosity.** Trace and debug logs compile out of release; info, notice, error, and fault remain.

---

## 3. Public Surface

### 3.1 Logger Type

A wrapper around Apple's `Logger` (os.log).

```swift
struct AppLogger: Sendable {
    let subsystem: String
    let category: String

    /// Lightweight; uses Apple's unified logging.
    func trace(_ message: @autoclosure () -> String,
               metadata: LogMetadata = [:]) async
    func debug(_ message: @autoclosure () -> String,
               metadata: LogMetadata = [:]) async
    func info(_ message: @autoclosure () -> String,
              metadata: LogMetadata = [:]) async
    func notice(_ message: @autoclosure () -> String,
                metadata: LogMetadata = [:]) async
    func warning(_ message: @autoclosure () -> String,
                 metadata: LogMetadata = [:]) async
    func error(_ message: @autoclosure () -> String,
               metadata: LogMetadata = [:],
               error: Error? = nil) async
    func fault(_ message: @autoclosure () -> String,
               metadata: LogMetadata = [:]) async
}

/// A type-safe metadata dictionary that only accepts redaction-safe values.
/// Trying to put raw user input in here without going through a redactor is a compile error.
struct LogMetadata: Sendable, ExpressibleByDictionaryLiteral {
    let entries: [(String, LogValue)]

    init(dictionaryLiteral elements: (String, LogValue)...) {
        self.entries = elements
    }
}

enum LogValue: Sendable {
    case string(String)             // for known-safe strings: enum names, status codes
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case duration(Duration)
    case redacted(label: String)    // mark-only: "<<redacted: workspace_url>>"
    case uuidPrefix(String)         // first 8 chars of a UUID, safe to log
    case errorCode(String)          // typed error case name, no payload
}
```

### 3.2 Logger Categories

A small set of well-defined categories. Every log call selects one.

```swift
enum LogCategory: String, CaseIterable, Sendable {
    case auth        = "auth"           // AuthService
    case capture     = "capture"        // CaptureEngine
    case ingest      = "ingest"         // IngestService
    case storage     = "storage"        // StorageService
    case projects    = "projects"       // ProjectService
    case persistence = "persistence"    // CoreDataStack
    case coordinator = "coordinator"    // AppCoordinator
    case ui          = "ui"             // View layer
    case network     = "network"        // HTTP / gRPC transport
    case telemetry   = "telemetry"      // self-referential

    var subsystem: String { "com.<your-org>.lakeloom" }
}

extension AppLogger {
    init(category: LogCategory) {
        self.init(subsystem: category.subsystem, category: category.rawValue)
    }
}
```

This enables filtering in Console.app and the in-app log viewer by category.

### 3.3 Metrics Type

```swift
actor MetricsRegistry {
    static let shared = MetricsRegistry()

    // Counters: monotonically increasing
    func increment(_ counter: CounterKey, by delta: Int64 = 1) async
    func get(_ counter: CounterKey) async -> Int64

    // Gauges: settable to a current value
    func set(_ gauge: GaugeKey, to value: Double) async
    func get(_ gauge: GaugeKey) async -> Double?

    // Histograms: bounded sample buffer (last N values, default 1024)
    func observe(_ histogram: HistogramKey, value: Double) async
    func snapshot(_ histogram: HistogramKey) async -> HistogramSnapshot

    // Snapshot all metrics for the diagnostics view.
    func snapshotAll() async -> MetricsSnapshot
}

struct CounterKey: Sendable, Hashable {
    let category: LogCategory
    let name: String                 // e.g., "records.sent.total"
}

struct GaugeKey: Sendable, Hashable {
    let category: LogCategory
    let name: String                 // e.g., "outbox.depth"
}

struct HistogramKey: Sendable, Hashable {
    let category: LogCategory
    let name: String                 // e.g., "send.latency.ms"
}

struct HistogramSnapshot: Sendable {
    let count: Int
    let sum: Double
    let min: Double
    let max: Double
    let mean: Double
    let p50: Double
    let p95: Double
    let p99: Double
}

struct MetricsSnapshot: Sendable {
    let counters: [CounterKey: Int64]
    let gauges: [GaugeKey: Double]
    let histograms: [HistogramKey: HistogramSnapshot]
    let capturedAt: Date
}
```

### 3.4 Signposting

For performance traces (drainer cycle duration, OAuth login, audio file write), use Apple's `OSSignposter`:

```swift
struct AppSignposter {
    let underlying: OSSignposter

    init(category: LogCategory) {
        self.underlying = OSSignposter(subsystem: category.subsystem,
                                       category: category.rawValue)
    }

    func interval<T>(_ name: StaticString,
                     _ work: () async throws -> T) async rethrows -> T
}
```

Signposts are visible in Instruments; they're free in production builds when not being recorded.

### 3.5 Support Bundle

A user-facing diagnostic export.

```swift
struct SupportBundle: Sendable {
    let createdAt: Date
    let appVersion: String
    let appBuild: String
    let osVersion: String
    let deviceModel: String
    let metrics: MetricsSnapshot
    let recentLogs: [LogEntry]
    let coreDataDiagnostics: CoreDataStackDiagnostics
    let authDiagnostics: AuthDiagnostics
    let ingestDiagnostics: IngestDiagnostics
    let storageDiagnostics: StorageDiagnostics
    let captureDiagnostics: CaptureDiagnostics
    let projectsDiagnostics: ProjectServiceDiagnostics
}

extension SupportBundle {
    /// Render as a JSON file for sharing.
    func encodeJSON() -> Data
    /// Render as a human-readable text file.
    func encodeText() -> String
}
```

The diagnostics view in Settings has a "Generate support bundle" button. It produces a JSON file the user shares via the standard share sheet. The bundle is fully self-contained; no network calls.

---

## 4. Internal Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Service modules                      │
│   (call AppLogger and MetricsRegistry directly)         │
└─────────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────┐
│              AppLogger (Sendable struct)                │
│         ┌────────────────────────────┐                  │
│         │  Apple Logger / os.log     │                  │
│         └────────────────────────────┘                  │
│         ┌────────────────────────────┐                  │
│         │  In-memory ring buffer     │                  │
│         │  (LogEntryCollector)       │                  │
│         └────────────────────────────┘                  │
└─────────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────┐
│             MetricsRegistry (actor)                     │
│         ┌────────────────────────────┐                  │
│         │  Counters / Gauges /       │                  │
│         │  Histograms                │                  │
│         └────────────────────────────┘                  │
└─────────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────┐
│                Support Bundle Generator                 │
│              (gathers everything on demand)             │
└─────────────────────────────────────────────────────────┘
```

### 4.1 Concurrency

- `AppLogger` is a `Sendable` struct with no mutable state. Callable from anywhere.
- The os.log layer is thread-safe by design; we delegate.
- The in-memory ring buffer is an actor (`LogEntryCollector`) with bounded capacity (default 1000 entries). Older entries are evicted FIFO.
- `MetricsRegistry` is an actor. All read/write operations are async.

### 4.2 The Log Entry Collector

```swift
actor LogEntryCollector {
    static let shared = LogEntryCollector(capacity: 1000)

    private var entries: Deque<LogEntry> = []
    private let capacity: Int

    func append(_ entry: LogEntry) {
        if entries.count >= capacity { _ = entries.popFirst() }
        entries.append(entry)
    }

    func snapshot() -> [LogEntry] {
        Array(entries)
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
    }
}

struct LogEntry: Sendable, Equatable {
    let timestamp: Date
    let level: LogLevel
    let category: LogCategory
    let message: String
    let metadata: [(String, LogValue)]
    let errorCode: String?            // when level == .error and an Error was passed
}

enum LogLevel: String, Sendable {
    case trace, debug, info, notice, warning, error, fault
}
```

The collector receives every log call (after Apple's os.log delivery). The in-app log viewer reads `snapshot()`; the support bundle includes a snapshot.

---

## 5. Logging Conventions

### 5.1 Required Pattern

Every log call uses structured metadata, never string interpolation for variable parts.

**Good:**
```swift
await logger.info("Drainer cycle completed",
                  metadata: ["batch.size": .int(48),
                             "duration.ms": .int(143),
                             "outcome": .string("success")])
```

**Bad:**
```swift
await logger.info("Drainer cycle completed: 48 records in 143ms — success")
```

The structured form is filterable, queryable, and stable across log version changes. The unstructured form is fragile and impossible to grep usefully.

### 5.2 Level Guidance

| Level | When to use | Example |
|---|---|---|
| `trace` | Hot-path internal flow; off in release | "Audio buffer ingested, frames=320" |
| `debug` | Developer diagnostics; off in release | "Refresh task created for workspace=abc12345" |
| `info` | Notable but expected events | "Session started, mode=quick_capture" |
| `notice` | Important state transitions | "Active workspace changed" |
| `warning` | Unexpected but recoverable | "Audio route changed mid-session" |
| `error` | Operation failed; user impact possible | "Outbox write failed; will retry" |
| `fault` | Programming error or invariant broken | "Active context nil during capture start" |

### 5.3 What Never Goes in Logs

The following are **prohibited** as log values, even in metadata, even at trace level:

- Access tokens, refresh tokens, API keys, OAuth client secrets
- Transcript text (chunk text or partial transcript)
- Audio file contents
- Project names, project descriptions
- Workspace URLs (these contain customer organization identifiers)
- Usernames, email addresses, display names
- Any free-text user input

If a log site needs to reference one of these, it logs a derived safe value:

| Sensitive | Safe alternative |
|---|---|
| Token | `<<redacted: token>>` (`LogValue.redacted(label:)`) |
| Workspace URL | `LogValue.redacted(label: "workspace_url")` |
| Workspace ID | OK to log — it's an opaque identifier |
| Username | `<<redacted: username>>` |
| User UUID | `LogValue.uuidPrefix(...)` (first 8 chars only) |
| Project name | `<<redacted: project_name>>` |
| Project ID | OK — opaque |
| Transcript text | Length only: `text.length` as `.int` |
| Error from server | `errorCode` (typed enum case name) and HTTP status; not the body |

### 5.4 Per-Module Conventions

Each module's design doc specifies what to log. Summary:

- **AuthService:** every sign-in, sign-out, refresh attempt with outcome and workspace_id (no tokens, no URLs)
- **CaptureEngine:** session start/end with mode and duration; warnings for route changes; chunk count only (no text)
- **IngestService:** drain cycle outcome with batch size and duration; per-record failures with `errorCode`; never payload contents
- **StorageService:** every state transition with sessionID and from/to states; never file contents
- **ProjectService:** SQL call by template name, parameter count, duration, row count; never parameter values
- **CoreDataStack:** initialization, migration, reset events with durations and entity counts
- **AppCoordinator:** every phase transition with old/new phase and reason
- **UI:** view model lifecycle events at debug level; warnings on unexpected state

---

## 6. Metrics Catalog

A canonical list of metrics across the app. Adding a new metric requires a name in this catalog (or a coordinator update).

### 6.1 Counters (lifetime totals)

| Name | Category | Description |
|---|---|---|
| `auth.signin.success` | auth | Successful interactive sign-ins |
| `auth.signin.canceled` | auth | User-canceled sign-ins |
| `auth.signin.failed` | auth | Failed sign-in attempts (any reason) |
| `auth.refresh.attempted` | auth | Token refresh attempts |
| `auth.refresh.success` | auth | Successful refreshes |
| `auth.refresh.failed` | auth | Failed refreshes (typically forces re-login) |
| `capture.sessions.started` | capture | Sessions started |
| `capture.sessions.completed` | capture | Sessions ended cleanly |
| `capture.sessions.interrupted` | capture | Sessions ended by interruption |
| `capture.chunks.emitted` | capture | Chunks finalized by ChunkAssembler |
| `ingest.records.enqueued` | ingest | Records added to outbox |
| `ingest.records.sent` | ingest | Records confirmed sent to ZeroBus |
| `ingest.records.failed` | ingest | Records moved to failed (transient) |
| `ingest.records.dead_lettered` | ingest | Records permanently failed |
| `ingest.drain.cycles` | ingest | Drainer cycles run |
| `storage.uploads.started` | storage | Audio uploads started |
| `storage.uploads.completed` | storage | Audio uploads completed successfully |
| `storage.uploads.failed` | storage | Upload failures (transient) |
| `storage.uploads.dead_lettered` | storage | Upload dead-letters |
| `storage.bytes.uploaded` | storage | Total audio bytes uploaded (lifetime) |
| `storage.purges.local` | storage | Local audio file deletions |
| `projects.list.calls` | projects | List API calls made |
| `projects.list.cache_hits` | projects | List requests served from cache |
| `projects.create.calls` | projects | Project creations attempted |
| `projects.create.success` | projects | Project creations succeeded |
| `persistence.migrations.run` | persistence | Migrations executed (lifetime; usually 0) |

### 6.2 Gauges (current values)

| Name | Category | Description |
|---|---|---|
| `ingest.outbox.depth` | ingest | Current count of `pending`+`inflight` records |
| `ingest.deadletter.depth` | ingest | Current count of `dead_lettered` records |
| `storage.local.bytes` | storage | Current local audio bytes on disk |
| `storage.pending.count` | storage | Current count of sessions awaiting upload |
| `persistence.store.bytes` | persistence | SQLite file size |
| `persistence.wal.bytes` | persistence | WAL file size |

### 6.3 Histograms (last 1024 samples)

| Name | Category | Description |
|---|---|---|
| `ingest.send.latency_ms` | ingest | Per-batch ZeroBus send latency |
| `storage.upload.duration_ms` | storage | Per-session audio upload duration |
| `auth.refresh.duration_ms` | auth | Token refresh latency |
| `projects.list.duration_ms` | projects | Project list SQL latency |
| `capture.session.duration_ms` | capture | Session lifetime duration |

---

## 7. The In-App Log Viewer

A debug-only screen accessible from Settings → Diagnostics → "View logs". Renders the in-memory ring buffer with:

- Filter by category (multi-select)
- Filter by level (single select: "this and above")
- Search box (matches message text)
- Tap a row to expand metadata
- Long-press to copy the entry as JSON
- "Clear logs" button (clears the ring buffer)
- "Share logs" button (encodes all entries as JSON, opens share sheet)

### 7.1 Release vs. Debug

- **Debug builds:** log viewer always available, all levels including trace/debug visible
- **Release builds:** log viewer accessible only after entering a "diagnostics mode" code in Settings → About (e.g., tap "Version" 7 times). Levels trace/debug are compiled out so the buffer never receives them.

### 7.2 Privacy Disclosure

The first time a user opens the log viewer in a release build:

> "Logs help diagnose issues. They don't include transcript text, file contents, or your account credentials, but they do contain identifiers like project IDs and timestamps. Share logs only with people you trust."

---

## 8. Crash Reporting

### 8.1 Apple's Built-In Reporter

iOS automatically generates `.ips` crash logs in Xcode → Devices and via TestFlight. v1 uses these exclusively.

A user reporting a crash through the support bundle path can also include the latest crash log: the app reads `FileManager` for crash logs from `Library/Logs/CrashReporter/` (sandboxed, app's own crashes only) and includes the most recent one in the support bundle.

### 8.2 Optional Third-Party (Out of Scope for v1)

If/when we add Sentry, Crashlytics, or Bugsnag in v1.x:

- Opt-in toggle in Settings → Privacy
- All breadcrumbs go through the same redactor as logs
- Users can clear all collected data with one tap
- Disabled by default in EU regions until consent is granted

For v1 we ship without any third-party crash reporter.

### 8.3 Programmatic Fault

For debug builds, `assert(...)` and `precondition(...)` halt execution. For release builds, both compile out (`assert`) or fault-and-continue (`precondition`). The `fault` log level is the right alternative for invariant violations that we want to record without crashing the app.

---

## 9. Performance Telemetry

### 9.1 Signposts

Signposts wrap expensive operations:

```swift
let signposter = AppSignposter(category: .ingest)
let result = await signposter.interval("drainCycle") {
    await runDrainCycle()
}
```

When Instruments is recording, these appear as labeled intervals. In production they're free.

### 9.2 Histograms vs. Signposts

Histograms (Section 6.3) and signposts both measure latency. They're complementary:

- **Signposts**: detailed analysis with Instruments during development
- **Histograms**: aggregated stats available in the support bundle (no Instruments needed)

Long-tail latencies in the field show up in histograms; root cause requires reproducing with Instruments.

### 9.3 Battery Telemetry

For v1 we don't directly measure battery impact. iOS's "Battery" Settings shows per-app usage; that's sufficient. For v1.x, signposts on capture/upload paths combined with `ProcessInfo.thermalState` polling can give a rough sense of impact under load.

---

## 10. Test Strategy

### 10.1 Logger Tests

- LogEntryCollector ring buffer eviction at capacity
- Metadata redaction enforcement (compile-time tests via type system)
- Level filtering: a release-build logger ignores trace/debug

### 10.2 Metrics Tests

- Counter atomicity under concurrent increments (10K parallel calls → exact total)
- Histogram percentile calculation with known fixtures
- Gauge set/get round trip
- Snapshot determinism

### 10.3 Support Bundle Tests

- Bundle includes all expected sections
- JSON encoding is well-formed
- Text encoding is human-readable
- Bundle size budget: <500 KB even after 1000 log entries

### 10.4 Privacy Tests

- Static analysis pass (compile-time): no `String(describing: token)` patterns in any logger call
- Runtime fixture test: synthesize logs with known sensitive values, assert they appear redacted in the bundle

---

## 11. Out of Scope for v1

- **Remote telemetry / analytics service.** No third-party analytics SDK.
- **Real-time observability dashboards.** Diagnostics are local snapshots.
- **A/B testing framework.** No experiment system.
- **User behavior analytics.** No screen-view tracking, button-tap tracking, funnel analysis.
- **Performance profiles uploaded to a service.** Instruments is the tool.
- **Distributed tracing across iOS + Databricks.** Each side has its own observability; the silver pipeline can correlate via record_uuid if needed.

---

## 12. Open Items

| # | Item | Resolution Path |
|---|---|---|
| 1 | Whether to redact workspace IDs (opaque, but uniquely identify a customer) in shared logs | v1: log workspace_id as-is (it's an opaque numeric identifier); revisit if customers object |
| 2 | The "diagnostics mode" unlock UX (7 taps on Version) — too clever, too hidden? | UX call. Default to it; iterate. |
| 3 | Histogram retention: 1024 samples or last 24h? | v1: 1024 samples; revisit if too coarse |
| 4 | Whether to log capture-engine warnings to ZeroBus (telemetry table) | Out of scope for v1; revisit when designing telemetry pipeline silver-side |
| 5 | Crash log inclusion in support bundle — privacy review needed | v1: include. Crash logs contain stack traces but not user data. Disclose in bundle preamble. |
| 6 | Logger.fault — should it call `assertionFailure` in debug? | v1: yes, in debug only. Helps catch bugs during development. |
| 7 | Support bundle encryption for sharing | v1: no encryption (it's already redacted). Add at customer request. |

---

## 13. File Layout (proposed)

```
App/Telemetry/
├── AppLogger.swift                        // public surface
├── LogCategory.swift
├── LogLevel.swift
├── LogMetadata.swift                      // type-safe metadata
├── LogValue.swift
├── LogEntry.swift
├── LogEntryCollector.swift                // actor, ring buffer
├── Metrics/
│   ├── MetricsRegistry.swift              // actor
│   ├── CounterKey.swift
│   ├── GaugeKey.swift
│   ├── HistogramKey.swift
│   ├── HistogramSnapshot.swift
│   └── MetricsCatalog.swift               // declared metric names
├── Signposts/
│   └── AppSignposter.swift
├── SupportBundle/
│   ├── SupportBundle.swift
│   ├── SupportBundleEncoder.swift
│   └── DiagnosticsCollector.swift         // gathers per-module diagnostics
├── Redaction/
│   ├── RedactionPolicy.swift
│   └── RedactionLinter.swift              // compile-time checks
└── Viewer/
    ├── LogViewerView.swift                // SwiftUI screen
    └── LogViewerFilter.swift
```

Tests mirror this layout under `AppTests/Telemetry/`.
