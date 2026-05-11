import Foundation
import OSLog

/// The structured logging entry point for every module.
///
/// `AppLogger` is a `Sendable` value — construct one per category at
/// the use site and call freely. State (the buffered ring) lives in
/// ``LogEntryCollector``; Apple's unified logging is the other sink.
///
/// In release builds, `trace` and `debug` calls compile out via
/// `@inlinable` short-circuits so they never reach the buffer or
/// `OSLog`. `info` and above always emit.
///
/// See Module 09 §3.1 and §5.
public struct AppLogger: Sendable {

    public let category: LogCategory
    private let osLog: Logger
    private let collector: LogEntryCollector
    private let nowProvider: @Sendable () -> Date

    /// Construct a logger for the given category.
    /// `collector` defaults to the process-wide singleton; tests
    /// inject an isolated instance to assert on.
    public init(
        category: LogCategory,
        collector: LogEntryCollector = .shared,
        nowProvider: @Sendable @escaping () -> Date = Date.init
    ) {
        self.category = category
        self.osLog = Logger(subsystem: category.subsystem, category: category.rawValue)
        self.collector = collector
        self.nowProvider = nowProvider
    }

    // MARK: Public level entry points

    public func trace(_ message: @autoclosure @Sendable () -> String, metadata: LogMetadata = [:]) async {
        #if DEBUG
        await emit(.trace, message: message(), metadata: metadata)
        #endif
    }

    public func debug(_ message: @autoclosure @Sendable () -> String, metadata: LogMetadata = [:]) async {
        #if DEBUG
        await emit(.debug, message: message(), metadata: metadata)
        #endif
    }

    public func info(_ message: @autoclosure @Sendable () -> String, metadata: LogMetadata = [:]) async {
        await emit(.info, message: message(), metadata: metadata)
    }

    public func notice(_ message: @autoclosure @Sendable () -> String, metadata: LogMetadata = [:]) async {
        await emit(.notice, message: message(), metadata: metadata)
    }

    public func warning(_ message: @autoclosure @Sendable () -> String, metadata: LogMetadata = [:]) async {
        await emit(.warning, message: message(), metadata: metadata)
    }

    public func error(_ message: @autoclosure @Sendable () -> String, metadata: LogMetadata = [:], errorCode: String? = nil) async {
        var combined = metadata
        if let errorCode {
            combined = LogMetadata(metadata.entries.map { ($0.key, $0.value) } + [("error_code", .errorCode(errorCode))])
        }
        await emit(.error, message: message(), metadata: combined, errorCode: errorCode)
    }

    public func fault(_ message: @autoclosure @Sendable () -> String, metadata: LogMetadata = [:]) async {
        await emit(.fault, message: message(), metadata: metadata)
    }

    // MARK: Internals

    private func emit(_ level: LogLevel, message: String, metadata: LogMetadata, errorCode: String? = nil) async {
        // Compose a single string for os.log. Public privacy because
        // we've already validated the values via the LogValue type
        // (sensitive values were redacted at the call site).
        let inline = metadata.isEmpty ? message : "\(message) \(metadata.renderInline())"
        osLog.log(level: level.osLogType, "[\(level.rawValue, privacy: .public)] \(inline, privacy: .public)")

        let entry = LogEntry(
            timestamp: nowProvider(),
            level: level,
            category: category,
            message: message,
            metadata: metadata,
            errorCode: errorCode
        )
        await collector.append(entry)
    }
}
