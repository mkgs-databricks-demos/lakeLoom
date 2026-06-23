import Foundation

@testable import LakeloomApp

/// Minimal ``ProjectServicing`` stub for tests that construct an
/// ``OperationExecutor`` but exercise only the capture-session
/// variants (which never touch the projects dependency). Project
/// methods `fatalError` — if one is ever called, the test is wrong.
public actor StubProjectServicing: ProjectServicing {

    /// Records each `submitQueuedCreate` call (projectID, name,
    /// workspaceID) so the createProject executor tests can assert the
    /// op was routed correctly.
    public private(set) var submitQueuedCreateCalls: [(projectID: String, name: String, workspaceID: String)] = []
    private var submitQueuedCreateError: ProjectAPIError?

    public init() {}

    /// Prime the next (and subsequent) `submitQueuedCreate` to throw,
    /// so the executor's classification can be exercised.
    public func setSubmitQueuedCreateError(_ error: ProjectAPIError?) {
        submitQueuedCreateError = error
    }

    public func submitQueuedCreate(
        projectID: String,
        name: String,
        description: String?,
        workspaceID: String
    ) async throws {
        submitQueuedCreateCalls.append((projectID: projectID, name: name, workspaceID: workspaceID))
        if let submitQueuedCreateError { throw submitQueuedCreateError }
    }

    public func start() async {}

    public func list(workspaceID: String, forceRefresh: Bool) async throws -> [ProjectMetadata] {
        fatalError("StubProjectServicing.list called — capture-op tests must not touch projects")
    }

    public func fetch(projectID: String, workspaceID: String) async throws -> ProjectMetadata {
        fatalError("StubProjectServicing.fetch called")
    }

    public func create(name: String, description: String?, workspaceID: String) async throws -> ProjectMetadata {
        fatalError("StubProjectServicing.create called")
    }

    public func update(
        projectID: String,
        workspaceID: String,
        name: String?,
        description: String?
    ) async throws -> ProjectMetadata {
        fatalError("StubProjectServicing.update called")
    }

    public func archive(projectID: String, workspaceID: String) async throws {
        fatalError("StubProjectServicing.archive called")
    }

    public func unarchive(projectID: String, workspaceID: String) async throws {
        fatalError("StubProjectServicing.unarchive called")
    }

    public func defaultProject(workspaceID: String) async -> ProjectMetadata? { nil }

    public func setDefault(projectID: String, workspaceID: String) async throws {
        fatalError("StubProjectServicing.setDefault called")
    }

    public func firstAvailableProject(workspaceID: String) async -> ProjectMetadata? { nil }

    public func refreshIfStale(workspaceID: String) async {}

    public var changes: AsyncStream<ProjectChangeEvent> {
        get async { AsyncStream { _ in } }
    }

    public func diagnostics() async -> ProjectServiceDiagnostics {
        fatalError("StubProjectServicing.diagnostics called")
    }
}
