import Foundation

/// Snapshot of internal ``ProjectService`` counters surfaced via the
/// diagnostics screen.
public struct ProjectServiceDiagnostics: Sendable, Equatable {
    public let cacheEntries: Int
    public let cacheHitRateLastHour: Double?
    public let lastListFetchAt: Date?
    public let lastCreateAt: Date?
    public let totalListCallsLifetime: Int64
    public let totalCreateCallsLifetime: Int64
    public let lastAppErrorReason: String?

    public static let zero = ProjectServiceDiagnostics(
        cacheEntries: 0,
        cacheHitRateLastHour: nil,
        lastListFetchAt: nil,
        lastCreateAt: nil,
        totalListCallsLifetime: 0,
        totalCreateCallsLifetime: 0,
        lastAppErrorReason: nil
    )

    public init(
        cacheEntries: Int,
        cacheHitRateLastHour: Double?,
        lastListFetchAt: Date?,
        lastCreateAt: Date?,
        totalListCallsLifetime: Int64,
        totalCreateCallsLifetime: Int64,
        lastAppErrorReason: String?
    ) {
        self.cacheEntries = cacheEntries
        self.cacheHitRateLastHour = cacheHitRateLastHour
        self.lastListFetchAt = lastListFetchAt
        self.lastCreateAt = lastCreateAt
        self.totalListCallsLifetime = totalListCallsLifetime
        self.totalCreateCallsLifetime = totalCreateCallsLifetime
        self.lastAppErrorReason = lastAppErrorReason
    }
}
