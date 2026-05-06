import CoreData
import Foundation

extension OutboxRecord {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<OutboxRecord> {
        NSFetchRequest<OutboxRecord>(entityName: "OutboxRecord")
    }

    // MARK: Top-level columns mirrored from the bronze table

    @NSManaged public var recordUUID: String
    @NSManaged public var sessionID: String
    @NSManaged public var workspaceID: String
    @NSManaged public var projectID: String
    @NSManaged public var sequenceNumber: Int32
    @NSManaged public var eventType: String
    @NSManaged public var deviceTimestamp: Date
    @NSManaged public var chunkStartOffsetMs: Int64
    @NSManaged public var chunkEndOffsetMs: Int64
    @NSManaged public var captureMode: String
    @NSManaged public var schemaVersion: String
    @NSManaged public var headersJSON: String
    @NSManaged public var payloadJSON: String

    // MARK: Drainer state machine

    @NSManaged public var state: String
    @NSManaged public var retryCount: Int32
    @NSManaged public var lastError: String?
    @NSManaged public var lastAttemptedAt: Date?
    @NSManaged public var nextEligibleAt: Date

    // MARK: Lifecycle timestamps

    @NSManaged public var createdAt: Date
    @NSManaged public var sentAt: Date?
    @NSManaged public var deadLetteredAt: Date?
}
