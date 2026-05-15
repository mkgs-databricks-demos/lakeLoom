import Foundation

/// Resolves the Databricks App's HTTPS base URL for a workspace, with
/// per-workspace caching.
///
/// Shared across ProjectService (Module 06), IngestService (Module 03),
/// and AppSyncService (Module 11) — they all speak HTTPS to the same
/// host. The cache TTL avoids repeating the lookup on every request;
/// per-workspace keying lets multi-workspace users hit the right App.
///
/// v1 implementation derives the URL deterministically from the
/// workspace URL (the App is hosted under
/// `https://<app-name>-<workspace>.databricksapps.com` or via a
/// workspace serving endpoint — exact convention TBD with Genie Code,
/// see `architecture/hi_genie/`). When that contract lands, only the
/// `derive` closure inside `LiveAppEndpointResolver` changes.
public protocol AppEndpointResolving: Sendable {
    /// Returns the cached endpoint or fetches a fresh one.
    /// `forceRefresh` skips the TTL check.
    func resolve(workspaceID: String, workspaceURL: URL, forceRefresh: Bool) async throws -> AppEndpoint

    /// Drop the cached entry for `workspaceID` so the next call
    /// re-derives. Used when the user signs out of a workspace or
    /// when the App URL convention is changed at runtime via Settings.
    func invalidate(workspaceID: String) async

    /// Pre-populates the cache with an authoritative `appBaseURL` for
    /// `workspaceID`. AppCoordinator calls this with
    /// `credential.appBaseURL` after a successful pairing (and on
    /// cold-launch hydrate) so that the next `resolve(...)` returns
    /// the QR-delivered URL instead of falling back to derivation.
    func seed(workspaceID: String, appBaseURL: URL) async
}

extension AppEndpointResolving {
    /// Convenience overload — equivalent to
    /// `resolve(workspaceID:workspaceURL:forceRefresh: false)`.
    public func resolve(workspaceID: String, workspaceURL: URL) async throws -> AppEndpoint {
        try await resolve(workspaceID: workspaceID, workspaceURL: workspaceURL, forceRefresh: false)
    }
}

/// Errors produced by ``AppEndpointResolving``.
public enum AppEndpointResolverError: Error, Sendable, Equatable {
    case invalidWorkspaceURL(String)
    case derivationFailed(reason: String)
}

/// Production resolver. Derives the App URL from the workspace URL via
/// the configured `derive` closure (defaults to a placeholder pattern
/// pending the Genie Code contract).
public actor LiveAppEndpointResolver: AppEndpointResolving {

    public typealias DeriveURL = @Sendable (URL) throws -> URL

    private let nowProvider: @Sendable () -> Date
    private let derive: DeriveURL
    private let ttl: TimeInterval
    private var cache: [String: AppEndpoint] = [:]

    public init(
        ttl: TimeInterval = 7 * 24 * 3_600,
        nowProvider: @Sendable @escaping () -> Date = Date.init,
        derive: DeriveURL? = nil
    ) {
        self.ttl = ttl
        self.nowProvider = nowProvider
        // Default derivation: same host as the workspace, root path.
        // The real Databricks App URL convention lands once Genie Code
        // settles on it (open item flagged in architecture/hi_genie/).
        // Until then, this is a structurally-correct placeholder that
        // Module 06's tests can swap via the init parameter.
        self.derive = derive ?? { workspaceURL in
            guard let host = workspaceURL.host, !host.isEmpty else {
                throw AppEndpointResolverError.invalidWorkspaceURL(workspaceURL.absoluteString)
            }
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            guard let url = components.url else {
                throw AppEndpointResolverError.derivationFailed(reason: "could not build URL")
            }
            return url
        }
    }

    public func resolve(
        workspaceID: String,
        workspaceURL: URL,
        forceRefresh: Bool
    ) async throws -> AppEndpoint {
        if !forceRefresh, let cached = cache[workspaceID], !cached.isStale(now: nowProvider(), ttl: ttl) {
            return cached
        }
        let url: URL
        do {
            url = try derive(workspaceURL)
        } catch let error as AppEndpointResolverError {
            throw error
        } catch {
            throw AppEndpointResolverError.derivationFailed(reason: error.localizedDescription)
        }
        let endpoint = AppEndpoint(workspaceID: workspaceID, url: url, resolvedAt: nowProvider())
        cache[workspaceID] = endpoint
        return endpoint
    }

    public func invalidate(workspaceID: String) async {
        cache.removeValue(forKey: workspaceID)
    }

    public func seed(workspaceID: String, appBaseURL: URL) async {
        cache[workspaceID] = AppEndpoint(
            workspaceID: workspaceID,
            url: appBaseURL,
            resolvedAt: nowProvider()
        )
    }
}
