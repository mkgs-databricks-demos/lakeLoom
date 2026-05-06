import CoreData
import Foundation

extension WorkspaceMetadataCache {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<WorkspaceMetadataCache> {
        NSFetchRequest<WorkspaceMetadataCache>(entityName: "WorkspaceMetadataCache")
    }

    @NSManaged public var workspaceID: String
    @NSManaged public var workspaceURL: String
    @NSManaged public var workspaceName: String
    @NSManaged public var cloud: String
    @NSManaged public var region: String?
    @NSManaged public var updatedAt: Date
}
