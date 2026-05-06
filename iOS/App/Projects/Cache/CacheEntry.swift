import Foundation

/// One cached project list for one workspace, plus the timestamp it
/// was fetched at. ``ProjectCache`` owns the dictionary of these.
struct CacheEntry: Sendable {
    var projects: [ProjectMetadata]
    let fetchedAt: Date
    let ttl: TimeInterval

    func isStale(now: Date) -> Bool {
        now.timeIntervalSince(fetchedAt) > ttl
    }
}
