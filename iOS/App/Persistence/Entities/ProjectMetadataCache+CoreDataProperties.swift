import CoreData
import Foundation

extension ProjectMetadataCache {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<ProjectMetadataCache> {
        NSFetchRequest<ProjectMetadataCache>(entityName: "ProjectMetadataCache")
    }

    @NSManaged public var projectID: String
    @NSManaged public var workspaceID: String
    @NSManaged public var name: String
    /// Renamed from the Module 07 spec's `description` to avoid shadowing
    /// `NSObject.description`. The DTO and SQL-side queries use this name.
    @NSManaged public var projectDescription: String?
    @NSManaged public var archived: Bool
    @NSManaged public var updatedAt: Date
}
