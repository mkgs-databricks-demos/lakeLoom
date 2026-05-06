import Foundation

/// Identifies the Databricks App's public HTTPS root for one workspace.
///
/// Modules that talk to the App (ProjectService, IngestService,
/// AppSyncService) compose endpoint paths from this base URL. The
/// `resolvedAt` timestamp drives TTL eviction in ``AppEndpointResolver``.
public struct AppEndpoint: Sendable, Equatable, Hashable, Codable {
    public let workspaceID: String
    public let url: URL
    public let resolvedAt: Date

    public init(workspaceID: String, url: URL, resolvedAt: Date) {
        self.workspaceID = workspaceID
        self.url = url
        self.resolvedAt = resolvedAt
    }

    /// True when the cached entry is older than `ttl`.
    public func isStale(now: Date = Date(), ttl: TimeInterval = 7 * 24 * 3_600) -> Bool {
        now.timeIntervalSince(resolvedAt) > ttl
    }
}
