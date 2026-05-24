import SwiftUI

/// Project switcher sheet — lets the signed-in user change the
/// active project for the current workspace without going through
/// QR sign-out / re-pair.
///
/// Loads the workspace's projects via ``ProjectServicing`` on
/// appearance, renders them as a list with the currently-active one
/// highlighted, and switches via
/// ``AppCoordinator/switchActiveProject(to:)`` when the user taps a
/// row. Pull-to-refresh re-fetches.
///
/// Reuses the brand-aware list styling from `CaptureDetailView` /
/// `SessionsListView` rather than the onboarding picker's
/// system-default list — onboarding is system chrome on purpose
/// (familiar territory while pairing), but post-onboarding screens
/// should stay in the brand-styled surface family.
struct ProjectSwitcherView: View {

    let projects: any ProjectServicing
    let workspaceID: String
    let workspaceName: String
    let activeProjectID: String
    let onSelect: (String) -> Void
    let onDismiss: () -> Void

    @State private var loadState: LoadState = .loading

    enum LoadState {
        case loading
        case loaded([ProjectMetadata])
        case empty
        case error(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch loadState {
                case .loading:
                    loadingView
                case .loaded(let list):
                    listView(list)
                case .empty:
                    emptyView
                case .error(let reason):
                    errorView(reason: reason)
                }
            }
            .navigationTitle("Switch project")
            .navigationBarTitleDisplayMode(.inline)
            .background(BrandColors.surfaceSecondary)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { onDismiss() }
                        .tint(BrandColors.accentPrimary)
                }
            }
            .refreshable { await reload(forceRefresh: true) }
        }
        .task { await initialLoad() }
    }

    // MARK: - States

    private var loadingView: some View {
        ProgressView()
            .controlSize(.large)
            .tint(BrandColors.accentPrimary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrandColors.surfaceSecondary)
    }

    private var emptyView: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(BrandColors.textMuted)
            Text("No projects in \(workspaceName)")
                .font(BrandTypography.titleSmall)
                .foregroundStyle(BrandColors.textPrimary)
            Text("Use the web app to create a project, then refresh.")
                .font(BrandTypography.caption)
                .foregroundStyle(BrandColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandColors.surfaceSecondary)
    }

    private func errorView(reason: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(BrandColors.statusError)
            Text("Couldn't load projects")
                .font(BrandTypography.titleSmall)
                .foregroundStyle(BrandColors.textPrimary)
            Text(reason)
                .font(BrandTypography.caption)
                .foregroundStyle(BrandColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
            Button {
                Task { await reload(forceRefresh: true) }
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
                    .font(BrandTypography.bodyEmphasis)
                    .frame(maxWidth: 220, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandColors.accentPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandColors.surfaceSecondary)
    }

    private func listView(_ list: [ProjectMetadata]) -> some View {
        List(list) { project in
            Button {
                if project.id != activeProjectID {
                    onSelect(project.id)
                }
            } label: {
                row(for: project)
            }
            .buttonStyle(.plain)
            .listRowBackground(BrandColors.surfacePrimary)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(BrandColors.surfaceSecondary)
    }

    private func row(for project: ProjectMetadata) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(BrandTypography.bodyEmphasis)
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(1)
                if let description = project.description, !description.isEmpty {
                    Text(description)
                        .font(BrandTypography.caption)
                        .foregroundStyle(BrandColors.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if project.id == activeProjectID {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(BrandColors.accentPrimary)
                    .accessibilityLabel("Active project")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: - Loading

    private func initialLoad() async {
        if case .loaded = loadState { return }
        await reload(forceRefresh: false)
    }

    private func reload(forceRefresh: Bool) async {
        do {
            let list = try await projects.list(workspaceID: workspaceID, forceRefresh: forceRefresh)
            loadState = list.isEmpty ? .empty : .loaded(list)
        } catch {
            loadState = .error(reasonString(for: error))
        }
    }

    private func reasonString(for error: any Error) -> String {
        if let projectError = error as? ProjectError {
            switch projectError {
            case .notSignedIn:                   return "Sign in again to view your projects."
            case .workspaceMismatch:             return "This workspace's session expired. Re-pair to continue."
            case .networkUnavailable:            return "You're offline. Try again when you have a signal."
            case .timeout:                       return "The request timed out. Try again in a moment."
            case .permissionDenied(let r):       return "Not authorized: \(r)"
            case .notFound:                      return "Workspace or project not found."
            case .serverUnavailable:             return "lakeLoom is having trouble right now. Try again in a moment."
            case .authFailed(let r):             return "Your session expired: \(r)"
            case .validationFailed(let r):       return r
            case .duplicateName:                 return "A project with this name already exists."
            case .rejectedByServer(_, let r):    return r
            case .rateLimited:                   return "Too many requests. Try again in a moment."
            case .unknown(let r):                return r
            }
        }
        return error.localizedDescription
    }
}
