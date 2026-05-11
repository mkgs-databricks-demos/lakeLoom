import Foundation

/// The user + workspace + project triple that's active right now.
/// Becomes non-nil after onboarding completes; nil during onboarding
/// and after sign-out.
public struct ActiveContext: Sendable, Equatable {
    public let user: UserIdentity
    public let workspace: WorkspaceCredential
    public let project: ProjectMetadata
    public let establishedAt: Date

    public init(
        user: UserIdentity,
        workspace: WorkspaceCredential,
        project: ProjectMetadata,
        establishedAt: Date
    ) {
        self.user = user
        self.workspace = workspace
        self.project = project
        self.establishedAt = establishedAt
    }
}
