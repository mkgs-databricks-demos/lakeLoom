import Foundation

@testable import LakeloomApp

/// Scriptable in-memory ``ProjectAPIClient`` for unit tests. Each method
/// returns the next outcome that callers seeded; assert-on-arguments
/// pattern via the per-method call logs.
public actor ScriptedProjectAPIClient: ProjectAPIClient {

    public enum ListOutcome: Sendable {
        case success(ProjectListResponse)
        case failure(ProjectAPIError)
    }

    public enum FetchOutcome: Sendable {
        case success(ProjectMetadata)
        case failure(ProjectAPIError)
    }

    public enum CreateOutcome: Sendable {
        case success(ProjectMetadata)
        case failure(ProjectAPIError)
    }

    public enum ArchiveOutcome: Sendable {
        case success
        case failure(ProjectAPIError)
    }

    // MARK: Logged calls

    public struct ListCall: Sendable {
        public let workspaceID: String
        public let query: String?
        public let limit: Int
        public let tokenValue: String
    }

    public struct FetchCall: Sendable {
        public let projectID: String
        public let workspaceID: String
        public let tokenValue: String
    }

    public struct CreateCall: Sendable {
        public let payload: CreateProjectPayload
        public let tokenValue: String
    }

    public struct ArchiveCall: Sendable {
        public let projectID: String
        public let workspaceID: String
        public let tokenValue: String
    }

    public private(set) var listCalls: [ListCall] = []
    public private(set) var fetchCalls: [FetchCall] = []
    public private(set) var createCalls: [CreateCall] = []
    public private(set) var archiveCalls: [ArchiveCall] = []
    public private(set) var unarchiveCalls: [ArchiveCall] = []

    public var listOutcomes: [ListOutcome] = []
    public var fetchOutcomes: [FetchOutcome] = []
    public var createOutcomes: [CreateOutcome] = []
    public var archiveOutcomes: [ArchiveOutcome] = []
    public var unarchiveOutcomes: [ArchiveOutcome] = []

    public init() {}

    public func enqueueList(_ outcome: ListOutcome) { listOutcomes.append(outcome) }
    public func enqueueFetch(_ outcome: FetchOutcome) { fetchOutcomes.append(outcome) }
    public func enqueueCreate(_ outcome: CreateOutcome) { createOutcomes.append(outcome) }
    public func enqueueArchive(_ outcome: ArchiveOutcome) { archiveOutcomes.append(outcome) }
    public func enqueueUnarchive(_ outcome: ArchiveOutcome) { unarchiveOutcomes.append(outcome) }

    // MARK: ProjectAPIClient

    public func list(
        workspaceID: String,
        query: String?,
        limit: Int,
        token: AccessToken,
        endpoint: AppEndpoint
    ) async throws -> ProjectListResponse {
        listCalls.append(ListCall(
            workspaceID: workspaceID,
            query: query,
            limit: limit,
            tokenValue: token.value
        ))
        guard !listOutcomes.isEmpty else {
            throw ProjectAPIError.unexpectedResponse(reason: "ScriptedProjectAPIClient: no list outcome")
        }
        switch listOutcomes.removeFirst() {
        case .success(let response): return response
        case .failure(let error): throw error
        }
    }

    public func fetch(
        projectID: String,
        workspaceID: String,
        token: AccessToken,
        endpoint: AppEndpoint
    ) async throws -> ProjectMetadata {
        fetchCalls.append(FetchCall(
            projectID: projectID,
            workspaceID: workspaceID,
            tokenValue: token.value
        ))
        guard !fetchOutcomes.isEmpty else {
            throw ProjectAPIError.unexpectedResponse(reason: "ScriptedProjectAPIClient: no fetch outcome")
        }
        switch fetchOutcomes.removeFirst() {
        case .success(let project): return project
        case .failure(let error): throw error
        }
    }

    public func create(
        _ payload: CreateProjectPayload,
        token: AccessToken,
        endpoint: AppEndpoint
    ) async throws -> ProjectMetadata {
        createCalls.append(CreateCall(payload: payload, tokenValue: token.value))
        guard !createOutcomes.isEmpty else {
            throw ProjectAPIError.unexpectedResponse(reason: "ScriptedProjectAPIClient: no create outcome")
        }
        switch createOutcomes.removeFirst() {
        case .success(let project): return project
        case .failure(let error): throw error
        }
    }

    public func archive(
        projectID: String,
        workspaceID: String,
        token: AccessToken,
        endpoint: AppEndpoint
    ) async throws {
        archiveCalls.append(ArchiveCall(
            projectID: projectID,
            workspaceID: workspaceID,
            tokenValue: token.value
        ))
        guard !archiveOutcomes.isEmpty else {
            throw ProjectAPIError.unexpectedResponse(reason: "ScriptedProjectAPIClient: no archive outcome")
        }
        switch archiveOutcomes.removeFirst() {
        case .success: return
        case .failure(let error): throw error
        }
    }

    public func unarchive(
        projectID: String,
        workspaceID: String,
        token: AccessToken,
        endpoint: AppEndpoint
    ) async throws {
        unarchiveCalls.append(ArchiveCall(
            projectID: projectID,
            workspaceID: workspaceID,
            tokenValue: token.value
        ))
        guard !unarchiveOutcomes.isEmpty else {
            throw ProjectAPIError.unexpectedResponse(reason: "ScriptedProjectAPIClient: no unarchive outcome")
        }
        switch unarchiveOutcomes.removeFirst() {
        case .success: return
        case .failure(let error): throw error
        }
    }
}

/// Test fixture for ProjectMetadata.
extension ProjectMetadata {
    public static func fixture(
        id: String = "proj-1",
        name: String = "Customer 360",
        description: String? = nil,
        workspaceID: String = "ws-1",
        archived: Bool = false,
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> ProjectMetadata {
        ProjectMetadata(
            id: id,
            name: name,
            description: description,
            workspaceID: workspaceID,
            createdByUserID: "u-1",
            createdByUsername: "u@example.com",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: updatedAt,
            archived: archived
        )
    }
}
