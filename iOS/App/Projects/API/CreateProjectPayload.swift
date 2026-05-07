import Foundation

/// Request body for `POST /api/v1/projects`.
///
/// `clientGeneratedID` is the idempotency key — re-submitting the same
/// `(workspace_id, client_generated_id)` returns the existing project
/// rather than failing with a duplicate. iOS generates this via
/// ``UUIDv7/generate(now:)`` so retries are safe forever.
public struct CreateProjectPayload: Sendable, Equatable, Codable {
    public let clientGeneratedID: String
    public let name: String
    public let description: String?
    public let workspaceID: String

    public init(clientGeneratedID: String, name: String, description: String?, workspaceID: String) {
        self.clientGeneratedID = clientGeneratedID
        self.name = name
        self.description = description
        self.workspaceID = workspaceID
    }

    private enum CodingKeys: String, CodingKey {
        case clientGeneratedID = "client_generated_id"
        case name
        case description
        case workspaceID = "workspace_id"
    }
}

/// Body for `PATCH /api/v1/projects/{id}/archive` and `.../restore`.
public struct ArchiveProjectPayload: Sendable, Equatable, Codable {
    public let workspaceID: String

    public init(workspaceID: String) {
        self.workspaceID = workspaceID
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
    }
}
