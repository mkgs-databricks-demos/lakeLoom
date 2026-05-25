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
    /// Closure invoked with the new project's name + description
    /// when the user submits the inline create form. The caller
    /// (`HomeContainerView`) routes this through
    /// `AppCoordinator.createAndSwitchToProject(name:description:)`,
    /// which both creates the project on the server and switches
    /// the active context to it.
    let onCreate: (_ name: String, _ description: String?) async throws -> Void
    let onDismiss: () -> Void

    /// Project the user tapped the info button on; bound to the
    /// detail-sheet presentation. Held on the switcher so the
    /// detail-view's local state survives pull-to-refresh on the
    /// underlying list.
    @State private var detailProject: ProjectMetadata?

    @State private var loadState: LoadState = .loading

    enum LoadState {
        case loading
        case loaded([ProjectMetadata])
        case empty
        case error(String)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
                createFooter
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
        .sheet(item: $detailProject) { project in
            ProjectDetailView(
                projects: projects,
                workspaceID: workspaceID,
                project: project,
                onDismiss: {
                    detailProject = nil
                    // Refresh the underlying list so any name /
                    // description edit the user just made
                    // propagates back to the switcher row.
                    Task { await reload(forceRefresh: true) }
                }
            )
        }
    }

    // MARK: - Create footer

    /// Persistent footer below the project list. Pushes
    /// ``ProjectCreateFormView`` onto the navigation stack so the
    /// user can name the new project + add a description without
    /// leaving the sheet. On successful create, the form view
    /// finishes and pops back; `onCreate` is what actually fires the
    /// coordinator's `createAndSwitchToProject(...)` round trip.
    private var createFooter: some View {
        VStack(spacing: 0) {
            Divider()
                .background(BrandColors.borderDefault)
            NavigationLink {
                ProjectCreateFormView(
                    workspaceName: workspaceName,
                    onSubmit: onCreate,
                    onSuccess: onDismiss
                )
            } label: {
                Label("New project", systemImage: "plus.circle.fill")
                    .font(BrandTypography.bodyEmphasis)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandColors.accentPrimary)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
        }
        .background(BrandColors.surfacePrimary)
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
            Button {
                detailProject = project
            } label: {
                Image(systemName: "info.circle")
                    .font(BrandTypography.body)
                    .foregroundStyle(BrandColors.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Project details")
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

    /// Display reason for an error surfaced during list/create.
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

/// Inline create form pushed onto ``ProjectSwitcherView``'s nav
/// stack. Two-field form (name + optional description) plus a
/// "Create" CTA. On success: dismisses the entire sheet via
/// `onSuccess` so the user lands back on the home screen with the
/// new project already active. On failure: renders the typed
/// `ProjectError` reason inline; the form stays open so the user
/// can edit and retry.
private struct ProjectCreateFormView: View {
    let workspaceName: String
    let onSubmit: (_ name: String, _ description: String?) async throws -> Void
    let onSuccess: () -> Void

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var isSubmitting = false
    @State private var lastError: String?

    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .focused($nameFieldFocused)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                TextField("Description (optional)", text: $description, axis: .vertical)
                    .lineLimit(2 ... 4)
                    .textInputAutocapitalization(.sentences)
            } header: {
                Text("New project in \(workspaceName)")
                    .font(BrandTypography.caption)
                    .foregroundStyle(BrandColors.textSecondary)
            }

            if let lastError {
                Section {
                    Text(lastError)
                        .font(BrandTypography.caption)
                        .foregroundStyle(BrandColors.statusError)
                }
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        if isSubmitting {
                            ProgressView().controlSize(.small)
                        }
                        Text(isSubmitting ? "Creating…" : "Create project")
                            .font(BrandTypography.bodyEmphasis)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColors.accentPrimary)
                .disabled(isSubmitting || trimmedName.isEmpty)
            }
        }
        .scrollContentBackground(.hidden)
        .background(BrandColors.surfaceSecondary)
        .navigationTitle("New project")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { nameFieldFocused = true }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDescription: String? {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func submit() async {
        guard !trimmedName.isEmpty else { return }
        isSubmitting = true
        lastError = nil
        defer { isSubmitting = false }
        do {
            try await onSubmit(trimmedName, trimmedDescription)
            // Successful create + switch — bubble up to the sheet so
            // it dismisses and the home view re-renders against the
            // new active project.
            onSuccess()
        } catch let error as ProjectError {
            lastError = ProjectCreateFormView.message(for: error)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func message(for error: ProjectError) -> String {
        switch error {
        case .notSignedIn:                   return "Sign in again to create a project."
        case .workspaceMismatch:             return "This workspace's session expired. Re-pair to continue."
        case .networkUnavailable:            return "You're offline. Try again when you have a signal."
        case .timeout:                       return "The request timed out. Try again in a moment."
        case .permissionDenied(let r):       return "Not authorized: \(r)"
        case .notFound:                      return "Workspace not found."
        case .serverUnavailable:             return "lakeLoom is having trouble right now. Try again in a moment."
        case .authFailed(let r):             return "Your session expired: \(r)"
        case .validationFailed(let r):       return r
        case .duplicateName:                 return "A project with this name already exists."
        case .rejectedByServer(_, let r):    return r
        case .rateLimited:                   return "Too many requests. Try again in a moment."
        case .unknown(let r):                return r
        }
    }
}
