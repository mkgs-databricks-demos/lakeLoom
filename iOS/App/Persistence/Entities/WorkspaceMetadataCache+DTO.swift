import CoreData
import Foundation

public struct WorkspaceMetadataCacheDTO: Sendable, Equatable, Hashable {
    public let workspaceID: String
    public let workspaceURL: String
    public let workspaceName: String
    public let cloud: String
    public let region: String?
    public let updatedAt: Date

    public init(
        workspaceID: String,
        workspaceURL: String,
        workspaceName: String,
        cloud: String,
        region: String?,
        updatedAt: Date
    ) {
        self.workspaceID = workspaceID
        self.workspaceURL = workspaceURL
        self.workspaceName = workspaceName
        self.cloud = cloud
        self.region = region
        self.updatedAt = updatedAt
    }
}

extension WorkspaceMetadataCache {

    public func toDTO() -> WorkspaceMetadataCacheDTO {
        WorkspaceMetadataCacheDTO(
            workspaceID: workspaceID,
            workspaceURL: workspaceURL,
            workspaceName: workspaceName,
            cloud: cloud,
            region: region,
            updatedAt: updatedAt
        )
    }

    public func apply(_ dto: WorkspaceMetadataCacheDTO) {
        workspaceID = dto.workspaceID
        workspaceURL = dto.workspaceURL
        workspaceName = dto.workspaceName
        cloud = dto.cloud
        region = dto.region
        updatedAt = dto.updatedAt
    }
}
