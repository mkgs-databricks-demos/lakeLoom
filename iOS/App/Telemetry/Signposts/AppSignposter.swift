import Foundation
import OSLog

/// Wraps Apple's `OSSignposter` so callers don't reach into `OSLog`
/// directly. Used for performance-trace intervals visible in
/// Instruments and (when not recorded) free at runtime.
///
/// Usage:
///
/// ```swift
/// let signposter = AppSignposter(category: .ingest)
/// let result = try await signposter.interval("drain.cycle") {
///     try await runDrainCycle()
/// }
/// ```
///
/// See Module 09 §3.4 and §9.
public struct AppSignposter: Sendable {

    public let category: LogCategory
    private let underlying: OSSignposter

    public init(category: LogCategory) {
        self.category = category
        self.underlying = OSSignposter(
            subsystem: category.subsystem,
            category: category.rawValue
        )
    }

    /// Begin an interval, run the closure, end the interval. Errors
    /// from the closure propagate after the end-event is recorded so
    /// failure paths show up in Instruments alongside successes.
    public func interval<T: Sendable>(
        _ name: StaticString,
        _ work: () async throws -> T
    ) async rethrows -> T {
        let state = underlying.beginInterval(name)
        defer { underlying.endInterval(name, state) }
        return try await work()
    }

    /// Synchronous variant for non-async hot paths (e.g. audio buffer
    /// processing). Same contract.
    public func interval<T>(
        _ name: StaticString,
        _ work: () throws -> T
    ) rethrows -> T {
        let state = underlying.beginInterval(name)
        defer { underlying.endInterval(name, state) }
        return try work()
    }
}
