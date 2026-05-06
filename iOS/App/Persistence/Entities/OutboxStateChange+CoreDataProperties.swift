import CoreData
import Foundation

extension OutboxStateChange {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<OutboxStateChange> {
        NSFetchRequest<OutboxStateChange>(entityName: "OutboxStateChange")
    }

    @NSManaged public var id: String
    @NSManaged public var recordUUID: String
    @NSManaged public var fromState: String
    @NSManaged public var toState: String
    @NSManaged public var reason: String?
    @NSManaged public var at: Date
}
