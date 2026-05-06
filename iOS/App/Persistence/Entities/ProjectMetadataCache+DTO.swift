import CoreData
import Foundation

public struct ProjectMetadataCacheDTO: Sendable, Equatable, Hashable {
    public let projectID: String
    public let workspaceID: String
    public let name: String
    public let projectDescription: String?
    public let archived: Bool
    public let updatedAt: Date

    public init(
        projectID: String,
        workspaceID: String,
        name: String,
        projectDescription: String?,
        archived: Bool,
        updatedAt: Date
    ) {
        self.projectID = projectID
        self.workspaceID = workspaceID
        self.name = name
        self.projectDescription = projectDescription
        self.archived = archived
        self.updatedAt = updatedAt
    }
}

extension ProjectMetadataCache {

    public func toDTO() -> ProjectMetadataCacheDTO {
        ProjectMetadataCacheDTO(
            projectID: projectID,
            workspaceID: workspaceID,
            name: name,
            projectDescription: projectDescription,
            archived: archived,
            updatedAt: updatedAt
        )
    }

    public func apply(_ dto: ProjectMetadataCacheDTO) {
        projectID = dto.projectID
        workspaceID = dto.workspaceID
        name = dto.name
        projectDescription = dto.projectDescription
        archived = dto.archived
        updatedAt = dto.updatedAt
    }
}
