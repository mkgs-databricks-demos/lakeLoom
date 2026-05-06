import Foundation

/// A snapshot of AuthService counters and timestamps useful in
/// Settings → Diagnostics. Per Module 01 §13.
public struct AuthDiagnostics: Sendable, Equatable {
    public let signInsAttempted: Int
    public let signInsSucceeded: Int
    public let signInsCancelled: Int
    public let signInsFailed: Int
    public let refreshesAttempted: Int
    public let refreshesSucceeded: Int
    public let refreshesFailed: Int
    public let lastSuccessfulRefreshAt: Date?
    public let lastRefreshFailureAt: Date?
    public let perWorkspaceRefreshFailures: [String: Int]

    public static let zero = AuthDiagnostics(
        signInsAttempted: 0,
        signInsSucceeded: 0,
        signInsCancelled: 0,
        signInsFailed: 0,
        refreshesAttempted: 0,
        refreshesSucceeded: 0,
        refreshesFailed: 0,
        lastSuccessfulRefreshAt: nil,
        lastRefreshFailureAt: nil,
        perWorkspaceRefreshFailures: [:]
    )

    public init(
        signInsAttempted: Int,
        signInsSucceeded: Int,
        signInsCancelled: Int,
        signInsFailed: Int,
        refreshesAttempted: Int,
        refreshesSucceeded: Int,
        refreshesFailed: Int,
        lastSuccessfulRefreshAt: Date?,
        lastRefreshFailureAt: Date?,
        perWorkspaceRefreshFailures: [String: Int]
    ) {
        self.signInsAttempted = signInsAttempted
        self.signInsSucceeded = signInsSucceeded
        self.signInsCancelled = signInsCancelled
        self.signInsFailed = signInsFailed
        self.refreshesAttempted = refreshesAttempted
        self.refreshesSucceeded = refreshesSucceeded
        self.refreshesFailed = refreshesFailed
        self.lastSuccessfulRefreshAt = lastSuccessfulRefreshAt
        self.lastRefreshFailureAt = lastRefreshFailureAt
        self.perWorkspaceRefreshFailures = perWorkspaceRefreshFailures
    }
}
