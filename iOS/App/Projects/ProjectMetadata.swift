import Foundation

/// Project metadata as the iOS app sees it.
///
/// The Databricks App is the authority — `created_at`, `updated_at`,
/// `created_by_*` fields are server-set. iOS treats this struct as
/// opaque (don't mutate locally; archive/restore goes through
/// ``ProjectServicing``).
public struct ProjectMetadata: Sendable, Equatable, Hashable, Identifiable, Codable {
    public let id: String
    public let name: String
    public let description: String?
    public let workspaceID: String
    public let createdByUserID: String
    public let createdByUsername: String
    public let createdAt: Date
    public let updatedAt: Date
    public let archived: Bool

    public init(
        id: String,
        name: String,
        description: String?,
        workspaceID: String,
        createdByUserID: String,
        createdByUsername: String,
        createdAt: Date,
        updatedAt: Date,
        archived: Bool
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.workspaceID = workspaceID
        self.createdByUserID = createdByUserID
        self.createdByUsername = createdByUsername
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archived = archived
    }

    private enum CodingKeys: String, CodingKey {
        case id = "project_id"
        case name = "project_name"
        case description
        case workspaceID = "workspace_id"
        case createdByUserID = "created_by_user_id"
        case createdByUsername = "created_by_username"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case archived
    }
}
