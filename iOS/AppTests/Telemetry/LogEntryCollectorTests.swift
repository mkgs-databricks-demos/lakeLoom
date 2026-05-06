import Foundation
import Testing

@testable import LakeloomApp

@Suite("LogEntryCollector")
struct LogEntryCollectorTests {

    private func makeEntry(level: LogLevel, category: LogCategory, message: String) -> LogEntry {
        LogEntry(
            timestamp: Date(timeIntervalSince1970: 0),
            level: level,
            category: category,
            message: message,
            metadata: [:]
        )
    }

    @Test("append + snapshot returns entries in insertion order")
    func appendOrder() async {
        let collector = LogEntryCollector(capacity: 10)
        await collector.append(makeEntry(level: .info, category: .auth, message: "first"))
        await collector.append(makeEntry(level: .info, category: .auth, message: "second"))
        await collector.append(makeEntry(level: .info, category: .auth, message: "third"))

        let snapshot = await collector.snapshot()
        #expect(snapshot.map(\.message) == ["first", "second", "third"])
    }

    @Test("ring buffer evicts oldest entries when capacity is exceeded")
    func ringEviction() async {
        let collector = LogEntryCollector(capacity: 3)
        for i in 1...5 {
            await collector.append(makeEntry(level: .info, category: .auth, message: "msg-\(i)"))
        }
        let snapshot = await collector.snapshot()
        #expect(snapshot.count == 3)
        #expect(snapshot.map(\.message) == ["msg-3", "msg-4", "msg-5"])
    }

    @Test("snapshot(minimumLevel:) filters by severity")
    func filterByLevel() async {
        let collector = LogEntryCollector(capacity: 10)
        await collector.append(makeEntry(level: .trace, category: .auth, message: "trace"))
        await collector.append(makeEntry(level: .debug, category: .auth, message: "debug"))
        await collector.append(makeEntry(level: .info, category: .auth, message: "info"))
        await collector.append(makeEntry(level: .warning, category: .auth, message: "warning"))
        await collector.append(makeEntry(level: .error, category: .auth, message: "error"))

        let warningPlus = await collector.snapshot(minimumLevel: .warning)
        #expect(warningPlus.map(\.message) == ["warning", "error"])
    }

    @Test("snapshot(categories:) filters by category set")
    func filterByCategory() async {
        let collector = LogEntryCollector(capacity: 10)
        await collector.append(makeEntry(level: .info, category: .auth, message: "auth"))
        await collector.append(makeEntry(level: .info, category: .ingest, message: "ingest"))
        await collector.append(makeEntry(level: .info, category: .telemetry, message: "telemetry"))

        let authOnly = await collector.snapshot(categories: [.auth])
        #expect(authOnly.map(\.message) == ["auth"])

        let authAndIngest = await collector.snapshot(categories: [.auth, .ingest])
        #expect(authAndIngest.map(\.message) == ["auth", "ingest"])
    }

    @Test("clear empties the buffer")
    func clearEmpties() async {
        let collector = LogEntryCollector(capacity: 5)
        await collector.append(makeEntry(level: .info, category: .auth, message: "x"))
        await collector.clear()
        let count = await collector.count
        #expect(count == 0)
    }

    @Test("count and configuredCapacity reflect state")
    func introspection() async {
        let collector = LogEntryCollector(capacity: 7)
        let cap = await collector.configuredCapacity
        #expect(cap == 7)
        let initial = await collector.count
        #expect(initial == 0)
        await collector.append(makeEntry(level: .info, category: .auth, message: "x"))
        let afterAppend = await collector.count
        #expect(afterAppend == 1)
    }
}

@Suite("AppLogger writes to LogEntryCollector")
struct AppLoggerCollectorTests {

    @Test("info() appends an entry to the injected collector")
    func infoAppendsToCollector() async {
        let collector = LogEntryCollector(capacity: 10)
        let logger = AppLogger(category: .telemetry, collector: collector)
        await logger.info("hello", metadata: ["count": .int(5)])
        let snapshot = await collector.snapshot()
        #expect(snapshot.count == 1)
        #expect(snapshot[0].level == .info)
        #expect(snapshot[0].category == .telemetry)
        #expect(snapshot[0].message == "hello")
        #expect(snapshot[0].metadata.entries.count == 1)
    }

    @Test("error() carries errorCode through to the entry's dedicated field")
    func errorCarriesErrorCode() async {
        let collector = LogEntryCollector(capacity: 10)
        let logger = AppLogger(category: .auth, collector: collector)
        await logger.error("token refresh failed", errorCode: "refreshFailed")
        let snapshot = await collector.snapshot()
        #expect(snapshot.count == 1)
        #expect(snapshot[0].errorCode == "refreshFailed")
        #expect(snapshot[0].level == .error)
    }
}
