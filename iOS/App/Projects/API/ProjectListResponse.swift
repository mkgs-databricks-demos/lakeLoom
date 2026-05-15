import Foundation

/// Response body for `GET /api/v1/projects`.
///
/// Mirrors the server-side shape from
/// `lakeloom-ai/server/routes/projects/project-routes.ts`:
///
/// ```json
/// {
///   "projects": [...],
///   "next_cursor": "<opaque cursor token>" | null,
///   "has_more": true | false
/// }
/// ```
///
/// Pagination is cursor-based: pass `next_cursor` (when non-nil) as
/// `?cursor=...` on the next list call to fetch the next page. The
/// cursor encodes `(updated_at, id)` server-side for stable ordering
/// across pages even when timestamps collide.
public struct ProjectListResponse: Sendable, Equatable, Codable {
    public let projects: [ProjectMetadata]
    public let nextCursor: String?
    public let hasMore: Bool

    public init(projects: [ProjectMetadata], nextCursor: String? = nil, hasMore: Bool = false) {
        self.projects = projects
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }

    private enum CodingKeys: String, CodingKey {
        case projects
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }
}
