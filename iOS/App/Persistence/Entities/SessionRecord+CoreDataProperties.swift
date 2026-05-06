import CoreData
import Foundation

extension SessionRecord {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<SessionRecord> {
        NSFetchRequest<SessionRecord>(entityName: "SessionRecord")
    }

    // MARK: Identity

    @NSManaged public var sessionID: String
    @NSManaged public var projectID: String
    @NSManaged public var workspaceID: String
    @NSManaged public var userUUID: String
    @NSManaged public var username: String
    @NSManaged public var captureMode: String

    // MARK: Lifecycle

    @NSManaged public var startedAt: Date
    @NSManaged public var endedAt: Date?
    @NSManaged public var chunkCount: Int32

    // MARK: Audio metadata (all optional — populated when audio is captured)

    @NSManaged public var audioLocalRelativePath: String?
    @NSManaged public var audioFormat: String?
    @NSManaged public var audioSampleRate: NSNumber?
    @NSManaged public var audioBitrate: NSNumber?
    @NSManaged public var audioDurationMs: NSNumber?
    @NSManaged public var audioSizeBytes: NSNumber?
    @NSManaged public var audioSha256: String?

    // MARK: Upload state machine

    @NSManaged public var uploadState: String
    @NSManaged public var uploadAttemptCount: Int32
    @NSManaged public var uploadLastError: String?
    @NSManaged public var uploadLastAttemptedAt: Date?
    @NSManaged public var uploadStartedAt: Date?
    @NSManaged public var uploadedAt: Date?
    @NSManaged public var uploadBytesSent: Int64
    @NSManaged public var uploadTaskIdentifier: NSNumber?
    @NSManaged public var remoteVolumePath: String?

    // MARK: Retention

    @NSManaged public var deleteAfter: Date?
    @NSManaged public var purgedAt: Date?
    @NSManaged public var deadLetteredAt: Date?
}
