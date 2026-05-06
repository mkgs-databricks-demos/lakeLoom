import Foundation

/// Events emitted by ``ProjectServicing/changes``. Subscribers
/// (AppCoordinator, Sessions list view-models) consume this stream
/// to keep their views fresh.
public enum ProjectChangeEvent: Sendable, Equatable {
    case listRefreshed(workspaceID: String, projects: [ProjectMetadata])
    case projectCreated(ProjectMetadata)
    case projectArchived(projectID: String, workspaceID: String)
    case projectUnarchived(ProjectMetadata)
    case defaultChanged(workspaceID: String, projectID: String?)
}
