import Foundation

/// Response body for `GET /api/v1/projects`.
public struct ProjectListResponse: Sendable, Equatable, Codable {
    public let projects: [ProjectMetadata]
    public let truncated: Bool

    public init(projects: [ProjectMetadata], truncated: Bool) {
        self.projects = projects
        self.truncated = truncated
    }
}
