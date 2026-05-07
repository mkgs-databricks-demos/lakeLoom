import SwiftUI

/// Project selection step. Shows the workspace's projects (or a
/// loading shimmer / error banner / empty state). User taps a row to
/// select; "+ New Project" jumps to ``ProjectCreateStepView``.
struct ProjectPickerStepView: View {
    let workspace: WorkspaceCredential
    let projects: [ProjectMetadata]
    let loading: Bool
    let lastError: String?
    let onSelect: (String) -> Void
    let onCreateNew: () -> Void
    let onReload: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, Spacing.lg)
                .padding(.horizontal, Spacing.xl)

            if loading && projects.isEmpty {
                ProgressView("Loading projects…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let lastError, projects.isEmpty {
                errorState(message: lastError)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if projects.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                projectList
            }

            Button(action: onCreateNew) {
                Label("New Project", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.lg)
        }
    }

    // MARK: Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Select a project")
                .font(.title2.bold())
            Text(workspace.workspaceName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var projectList: some View {
        List(projects) { project in
            Button(action: { onSelect(project.id) }) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(project.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let description = project.description, !description.isEmpty {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, Spacing.xs)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .refreshable { onReload() }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No projects yet")
                .font(.headline)
            Text("Create a new project to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Spacing.xl)
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Couldn't load projects")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry", action: onReload)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, Spacing.xl)
    }
}
