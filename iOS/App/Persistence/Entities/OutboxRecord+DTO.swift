import CoreData
import Foundation

/// Sendable mirror of ``OutboxRecord``. Used everywhere outside the
/// owning actor (IngestService) so we don't violate Swift 6 strict
/// concurrency by sending a managed object across isolation boundaries.
public struct OutboxRecordDTO: Sendable, Equatable, Hashable {

    // Top-level columns
    public let recordUUID: String
    public let sessionID: String
    public let workspaceID: String
    public let projectID: String
    public let sequenceNumber: Int32
    public let eventType: String
    public let deviceTimestamp: Date
    public let chunkStartOffsetMs: Int64
    public let chunkEndOffsetMs: Int64
    public let captureMode: String
    public let schemaVersion: String
    public let headersJSON: String
    public let payloadJSON: String

    // Drainer state
    public let state: OutboxRecord.State
    public let retryCount: Int32
    public let lastError: String?
    public let lastAttemptedAt: Date?
    public let nextEligibleAt: Date

    // Lifecycle
    public let createdAt: Date
    public let sentAt: Date?
    public let deadLetteredAt: Date?

    public init(
        recordUUID: String,
        sessionID: String,
        workspaceID: String,
        projectID: String,
        sequenceNumber: Int32,
        eventType: String,
        deviceTimestamp: Date,
        chunkStartOffsetMs: Int64,
        chunkEndOffsetMs: Int64,
        captureMode: String,
        schemaVersion: String,
        headersJSON: String,
        payloadJSON: String,
        state: OutboxRecord.State,
        retryCount: Int32,
        lastError: String?,
        lastAttemptedAt: Date?,
        nextEligibleAt: Date,
        createdAt: Date,
        sentAt: Date?,
        deadLetteredAt: Date?
    ) {
        self.recordUUID = recordUUID
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.projectID = projectID
        self.sequenceNumber = sequenceNumber
        self.eventType = eventType
        self.deviceTimestamp = deviceTimestamp
        self.chunkStartOffsetMs = chunkStartOffsetMs
        self.chunkEndOffsetMs = chunkEndOffsetMs
        self.captureMode = captureMode
        self.schemaVersion = schemaVersion
        self.headersJSON = headersJSON
        self.payloadJSON = payloadJSON
        self.state = state
        self.retryCount = retryCount
        self.lastError = lastError
        self.lastAttemptedAt = lastAttemptedAt
        self.nextEligibleAt = nextEligibleAt
        self.createdAt = createdAt
        self.sentAt = sentAt
        self.deadLetteredAt = deadLetteredAt
    }
}

extension OutboxRecord {
    /// Flatten this managed object into a Sendable DTO. Must be called
    /// on the context's queue (e.g. inside `performWrite { ... }`).
    public func toDTO() -> OutboxRecordDTO {
        OutboxRecordDTO(
            recordUUID: recordUUID,
            sessionID: sessionID,
            workspaceID: workspaceID,
            projectID: projectID,
            sequenceNumber: sequenceNumber,
            eventType: eventType,
            deviceTimestamp: deviceTimestamp,
            chunkStartOffsetMs: chunkStartOffsetMs,
            chunkEndOffsetMs: chunkEndOffsetMs,
            captureMode: captureMode,
            schemaVersion: schemaVersion,
            headersJSON: headersJSON,
            payloadJSON: payloadJSON,
            state: OutboxRecord.State(rawValue: state) ?? .pending,
            retryCount: retryCount,
            lastError: lastError,
            lastAttemptedAt: lastAttemptedAt,
            nextEligibleAt: nextEligibleAt,
            createdAt: createdAt,
            sentAt: sentAt,
            deadLetteredAt: deadLetteredAt
        )
    }

    /// Hydrate a fresh managed object from a DTO. Caller is responsible
    /// for inserting into the correct context — typical pattern is to
    /// call `OutboxRecord(context: ctx).apply(dto)`.
    public func apply(_ dto: OutboxRecordDTO) {
        recordUUID = dto.recordUUID
        sessionID = dto.sessionID
        workspaceID = dto.workspaceID
        projectID = dto.projectID
        sequenceNumber = dto.sequenceNumber
        eventType = dto.eventType
        deviceTimestamp = dto.deviceTimestamp
        chunkStartOffsetMs = dto.chunkStartOffsetMs
        chunkEndOffsetMs = dto.chunkEndOffsetMs
        captureMode = dto.captureMode
        schemaVersion = dto.schemaVersion
        headersJSON = dto.headersJSON
        payloadJSON = dto.payloadJSON
        state = dto.state.rawValue
        retryCount = dto.retryCount
        lastError = dto.lastError
        lastAttemptedAt = dto.lastAttemptedAt
        nextEligibleAt = dto.nextEligibleAt
        createdAt = dto.createdAt
        sentAt = dto.sentAt
        deadLetteredAt = dto.deadLetteredAt
    }
}
