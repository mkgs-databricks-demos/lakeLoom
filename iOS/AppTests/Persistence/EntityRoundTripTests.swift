import CoreData
import Foundation
import Testing

@testable import LakeloomApp

@Suite("Entity DTO round-trip")
struct EntityRoundTripTests {

    private func makeStack() async throws -> CoreDataStack {
        let stack = try CoreDataStack.makeInMemory()
        try await stack.initialize()
        return stack
    }

    // MARK: OutboxRecord

    @Test("OutboxRecord round-trips every field")
    func outboxRecordRoundTrip() async throws {
        let stack = try await makeStack()
        let dto = OutboxRecordDTO(
            recordUUID: "rec-rt",
            sessionID: "sess-rt",
            workspaceID: "ws-rt",
            projectID: "proj-rt",
            sequenceNumber: 7,
            eventType: "transcript_chunk",
            deviceTimestamp: Date(timeIntervalSince1970: 1_700_000_000),
            chunkStartOffsetMs: 100,
            chunkEndOffsetMs: 6_420,
            captureMode: "quick_capture",
            schemaVersion: "1.0.0",
            headersJSON: #"{"device":"iPhone16,2"}"#,
            payloadJSON: #"{"text":"hello"}"#,
            state: .inflight,
            retryCount: 2,
            lastError: "timeout",
            lastAttemptedAt: Date(timeIntervalSince1970: 1_700_000_500),
            nextEligibleAt: Date(timeIntervalSince1970: 1_700_001_000),
            createdAt: Date(timeIntervalSince1970: 1_699_999_999),
            sentAt: nil,
            deadLetteredAt: nil
        )

        try await stack.performWrite { context in
            OutboxRecord(context: context).apply(dto)
        }

        let loaded: OutboxRecordDTO? = try await stack.performWrite { context in
            let request = OutboxRecord.fetchRequest()
            request.predicate = NSPredicate(format: "recordUUID == %@", "rec-rt")
            request.fetchLimit = 1
            return try context.fetch(request).first?.toDTO()
        }
        #expect(loaded == dto)
    }

    @Test("OutboxRecord state enum round-trips")
    func outboxRecordStateEnumRoundTrip() async throws {
        let stack = try await makeStack()
        for state in OutboxRecord.State.allCases {
            let dto = OutboxRecordDTO.fixture(
                recordUUID: "rec-\(state.rawValue)",
                state: state
            )
            try await stack.performWrite { context in
                OutboxRecord(context: context).apply(dto)
            }
        }
        let states: Set<OutboxRecord.State> = try await stack.performWrite { context in
            let records = try context.fetch(OutboxRecord.fetchRequest())
            return Set(records.compactMap { OutboxRecord.State(rawValue: $0.state) })
        }
        #expect(states == Set(OutboxRecord.State.allCases))
    }

    // MARK: SessionRecord

    @Test("SessionRecord round-trips with optional NSNumber audio scalars")
    func sessionRecordOptionalScalars() async throws {
        let stack = try await makeStack()
        let dto = SessionRecordDTO(
            sessionID: "sess-rt",
            projectID: "proj-rt",
            workspaceID: "ws-rt",
            userUUID: "u-rt",
            username: "u@example.com",
            captureMode: .meeting,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_120),
            chunkCount: 3,
            audioLocalRelativePath: "sessions/sess-rt/audio.opus",
            audioFormat: "opus",
            audioSampleRate: 16_000,
            audioBitrate: 16_000,
            audioDurationMs: 120_000,
            audioSizeBytes: 384_512,
            audioSha256: "abcd",
            uploadState: .uploading,
            uploadAttemptCount: 1,
            uploadLastError: nil,
            uploadLastAttemptedAt: nil,
            uploadStartedAt: Date(timeIntervalSince1970: 1_700_000_125),
            uploadedAt: nil,
            uploadBytesSent: 100_000,
            uploadTaskIdentifier: 42,
            remoteVolumePath: nil,
            deleteAfter: nil,
            purgedAt: nil,
            deadLetteredAt: nil
        )

        try await stack.performWrite { context in
            SessionRecord(context: context).apply(dto)
        }

        let loaded: SessionRecordDTO? = try await stack.performWrite { context in
            let request = SessionRecord.fetchRequest()
            request.predicate = NSPredicate(format: "sessionID == %@", "sess-rt")
            request.fetchLimit = 1
            return try context.fetch(request).first?.toDTO()
        }
        #expect(loaded == dto)
    }

    @Test("SessionRecord with all-nil audio metadata round-trips cleanly")
    func sessionRecordNoAudio() async throws {
        let stack = try await makeStack()
        let dto = SessionRecordDTO.fixture(sessionID: "sess-no-audio")
        try await stack.performWrite { context in
            SessionRecord(context: context).apply(dto)
        }
        let loaded: SessionRecordDTO? = try await stack.performWrite { context in
            let request = SessionRecord.fetchRequest()
            request.predicate = NSPredicate(format: "sessionID == %@", "sess-no-audio")
            return try context.fetch(request).first?.toDTO()
        }
        #expect(loaded?.audioSampleRate == nil)
        #expect(loaded?.audioDurationMs == nil)
        #expect(loaded?.uploadTaskIdentifier == nil)
    }

    // MARK: OutboxStateChange

    @Test("OutboxStateChange round-trips with nil reason")
    func outboxStateChangeRoundTrip() async throws {
        let stack = try await makeStack()
        let dto = OutboxStateChangeDTO(
            id: "change-1",
            recordUUID: "rec-1",
            fromState: "pending",
            toState: "inflight",
            reason: nil,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await stack.performWrite { context in
            OutboxStateChange(context: context).apply(dto)
        }
        let loaded: OutboxStateChangeDTO? = try await stack.performWrite { context in
            try context.fetch(OutboxStateChange.fetchRequest()).first?.toDTO()
        }
        #expect(loaded == dto)
    }

    // MARK: WorkspaceMetadataCache

    @Test("WorkspaceMetadataCache round-trips")
    func workspaceMetadataCacheRoundTrip() async throws {
        let stack = try await makeStack()
        let dto = WorkspaceMetadataCacheDTO(
            workspaceID: "ws-1",
            workspaceURL: "https://acme.cloud.databricks.com",
            workspaceName: "ACME",
            cloud: "aws",
            region: "us-west-2",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await stack.performWrite { context in
            WorkspaceMetadataCache(context: context).apply(dto)
        }
        let loaded: WorkspaceMetadataCacheDTO? = try await stack.performWrite { context in
            try context.fetch(WorkspaceMetadataCache.fetchRequest()).first?.toDTO()
        }
        #expect(loaded == dto)
    }

    // MARK: ProjectMetadataCache

    @Test("ProjectMetadataCache round-trips with nil description")
    func projectMetadataCacheRoundTrip() async throws {
        let stack = try await makeStack()
        let dto = ProjectMetadataCacheDTO(
            projectID: "proj-1",
            workspaceID: "ws-1",
            name: "Customer 360 Lakehouse",
            projectDescription: nil,
            archived: false,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await stack.performWrite { context in
            ProjectMetadataCache(context: context).apply(dto)
        }
        let loaded: ProjectMetadataCacheDTO? = try await stack.performWrite { context in
            try context.fetch(ProjectMetadataCache.fetchRequest()).first?.toDTO()
        }
        #expect(loaded == dto)
    }
}
