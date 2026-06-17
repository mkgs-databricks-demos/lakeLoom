import Foundation

@testable import LakeloomApp

/// Minimal ``ProjectServicing`` stub for tests that construct an
/// ``OperationExecutor`` but exercise only the capture-session
/// variants (which never touch the projects dependency). Project
/// methods `fatalError` — if one is ever called, the test is wrong.
public actor StubProjectServicing: ProjectServicing {

    public init() {}

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
