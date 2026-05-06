import CoreData
import Foundation

/// Sendable mirror of ``SessionRecord``. Optional `Int32`/`Int64`
/// audio-metadata attributes round-trip through Swift `Optional` —
/// the entity uses `NSNumber` for nullable scalars (Core Data's
/// requirement for optional integers).
public struct SessionRecordDTO: Sendable, Equatable, Hashable {

    public let sessionID: String
    public let projectID: String
    public let workspaceID: String
    public let userUUID: String
    public let username: String
    public let captureMode: SessionRecord.CaptureMode

    public let startedAt: Date
    public let endedAt: Date?
    public let chunkCount: Int32

    public let audioLocalRelativePath: String?
    public let audioFormat: String?
    public let audioSampleRate: Int32?
    public let audioBitrate: Int32?
    public let audioDurationMs: Int64?
    public let audioSizeBytes: Int64?
    public let audioSha256: String?

    public let uploadState: SessionRecord.UploadState
    public let uploadAttemptCount: Int32
    public let uploadLastError: String?
    public let uploadLastAttemptedAt: Date?
    public let uploadStartedAt: Date?
    public let uploadedAt: Date?
    public let uploadBytesSent: Int64
    public let uploadTaskIdentifier: Int64?
    public let remoteVolumePath: String?

    public let deleteAfter: Date?
    public let purgedAt: Date?
    public let deadLetteredAt: Date?

    public init(
        sessionID: String,
        projectID: String,
        workspaceID: String,
        userUUID: String,
        username: String,
        captureMode: SessionRecord.CaptureMode,
        startedAt: Date,
        endedAt: Date?,
        chunkCount: Int32,
        audioLocalRelativePath: String?,
        audioFormat: String?,
        audioSampleRate: Int32?,
        audioBitrate: Int32?,
        audioDurationMs: Int64?,
        audioSizeBytes: Int64?,
        audioSha256: String?,
        uploadState: SessionRecord.UploadState,
        uploadAttemptCount: Int32,
        uploadLastError: String?,
        uploadLastAttemptedAt: Date?,
        uploadStartedAt: Date?,
        uploadedAt: Date?,
        uploadBytesSent: Int64,
        uploadTaskIdentifier: Int64?,
        remoteVolumePath: String?,
        deleteAfter: Date?,
        purgedAt: Date?,
        deadLetteredAt: Date?
    ) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.workspaceID = workspaceID
        self.userUUID = userUUID
        self.username = username
        self.captureMode = captureMode
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.chunkCount = chunkCount
        self.audioLocalRelativePath = audioLocalRelativePath
        self.audioFormat = audioFormat
        self.audioSampleRate = audioSampleRate
        self.audioBitrate = audioBitrate
        self.audioDurationMs = audioDurationMs
        self.audioSizeBytes = audioSizeBytes
        self.audioSha256 = audioSha256
        self.uploadState = uploadState
        self.uploadAttemptCount = uploadAttemptCount
        self.uploadLastError = uploadLastError
        self.uploadLastAttemptedAt = uploadLastAttemptedAt
        self.uploadStartedAt = uploadStartedAt
        self.uploadedAt = uploadedAt
        self.uploadBytesSent = uploadBytesSent
        self.uploadTaskIdentifier = uploadTaskIdentifier
        self.remoteVolumePath = remoteVolumePath
        self.deleteAfter = deleteAfter
        self.purgedAt = purgedAt
        self.deadLetteredAt = deadLetteredAt
    }
}

extension SessionRecord {

    public func toDTO() -> SessionRecordDTO {
        SessionRecordDTO(
            sessionID: sessionID,
            projectID: projectID,
            workspaceID: workspaceID,
            userUUID: userUUID,
            username: username,
            captureMode: SessionRecord.CaptureMode(rawValue: captureMode) ?? .quickCapture,
            startedAt: startedAt,
            endedAt: endedAt,
            chunkCount: chunkCount,
            audioLocalRelativePath: audioLocalRelativePath,
            audioFormat: audioFormat,
            audioSampleRate: audioSampleRate?.int32Value,
            audioBitrate: audioBitrate?.int32Value,
            audioDurationMs: audioDurationMs?.int64Value,
            audioSizeBytes: audioSizeBytes?.int64Value,
            audioSha256: audioSha256,
            uploadState: SessionRecord.UploadState(rawValue: uploadState) ?? .pending,
            uploadAttemptCount: uploadAttemptCount,
            uploadLastError: uploadLastError,
            uploadLastAttemptedAt: uploadLastAttemptedAt,
            uploadStartedAt: uploadStartedAt,
            uploadedAt: uploadedAt,
            uploadBytesSent: uploadBytesSent,
            uploadTaskIdentifier: uploadTaskIdentifier?.int64Value,
            remoteVolumePath: remoteVolumePath,
            deleteAfter: deleteAfter,
            purgedAt: purgedAt,
            deadLetteredAt: deadLetteredAt
        )
    }

    public func apply(_ dto: SessionRecordDTO) {
        sessionID = dto.sessionID
        projectID = dto.projectID
        workspaceID = dto.workspaceID
        userUUID = dto.userUUID
        username = dto.username
        captureMode = dto.captureMode.rawValue
        startedAt = dto.startedAt
        endedAt = dto.endedAt
        chunkCount = dto.chunkCount
        audioLocalRelativePath = dto.audioLocalRelativePath
        audioFormat = dto.audioFormat
        audioSampleRate = dto.audioSampleRate.map { NSNumber(value: $0) }
        audioBitrate = dto.audioBitrate.map { NSNumber(value: $0) }
        audioDurationMs = dto.audioDurationMs.map { NSNumber(value: $0) }
        audioSizeBytes = dto.audioSizeBytes.map { NSNumber(value: $0) }
        audioSha256 = dto.audioSha256
        uploadState = dto.uploadState.rawValue
        uploadAttemptCount = dto.uploadAttemptCount
        uploadLastError = dto.uploadLastError
        uploadLastAttemptedAt = dto.uploadLastAttemptedAt
        uploadStartedAt = dto.uploadStartedAt
        uploadedAt = dto.uploadedAt
        uploadBytesSent = dto.uploadBytesSent
        uploadTaskIdentifier = dto.uploadTaskIdentifier.map { NSNumber(value: $0) }
        remoteVolumePath = dto.remoteVolumePath
        deleteAfter = dto.deleteAfter
        purgedAt = dto.purgedAt
        deadLetteredAt = dto.deadLetteredAt
    }
}
