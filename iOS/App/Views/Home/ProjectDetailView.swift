import SwiftUI

/// Project detail / edit sheet. Reached from a small info button on
/// each row in ``ProjectSwitcherView``. Two modes via the toolbar:
///
/// * **View mode (default).** Renders the project name (in
///   `BrandTypography.titleSmall`) and description (or an em-dash if
///   the field is empty). Read-only.
/// * **Edit mode.** Toggled by tapping `Edit` in the top-right.
///   Swaps the name + description rows into TextField / TextField
///   (axis: .vertical). `Save` PATCHes the server via
///   ``ProjectServicing/update(projectID:workspaceID:name:description:)``
///   then drops back to view mode with the returned metadata.
///   `Cancel` discards edits without a network call.
///
/// Why a dedicated view (not just an inline edit on the switcher
/// row): the description is multi-line and the user often wants a
/// moment to compose it. Pushing into a focused screen also matches
/// the iOS pattern users expect (Mail's address-book detail / Notes'
/// folder editor).
struct ProjectDetailView: View {

    let projects: any ProjectServicing
    let workspaceID: String
    /// Initial project. Replaced with the server-returned
    /// `ProjectMetadata` after a successful save so the view stays
    /// in sync without re-fetching.
    @State var project: ProjectMetadata
    let onDismiss: () -> Void

    @State private var mode: Mode = .viewing
    @State private var nameDraft: String = ""
    @State private var descriptionDraft: String = ""
    @State private var isSaving = false
    @State private var saveError: String?

    enum Mode {
        case viewing
        case editing
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    nameRow
                    descriptionRow
                } header: {
                    Text("Project")
                        .font(BrandTypography.caption)
                        .foregroundStyle(BrandColors.textSecondary)
                }
                if let saveError {
                    Section {
                        Text(saveError)
                            .font(BrandTypography.caption)
                            .foregroundStyle(BrandColors.statusError)
                    }
                }
                metadataSection
            }
            .scrollContentBackground(.hidden)
            .background(BrandColors.surfaceSecondary)
            .navigationTitle(mode == .editing ? "Edit project" : project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(mode == .editing ? "Cancel" : "Done") {
                switch mode {
                case .viewing:
                    onDismiss()
                case .editing:
                    saveError = nil
                    mode = .viewing
                }
            }
            .tint(BrandColors.accentPrimary)
            .disabled(isSaving)
        }
        ToolbarItem(placement: .topBarTrailing) {
            switch mode {
            case .viewing:
                Button("Edit") {
                    nameDraft = project.name
                    descriptionDraft = project.description ?? ""
                    saveError = nil
                    mode = .editing
                }
                .tint(BrandColors.accentPrimary)
            case .editing:
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save").font(BrandTypography.bodyEmphasis)
                    }
                }
                .tint(BrandColors.accentPrimary)
                .disabled(isSaving || !hasChanges)
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private var nameRow: some View {
        switch mode {
        case .viewing:
            VStack(alignment: .leading, spacing: 2) {
                Text("Name")
                    .font(BrandTypography.caption)
                    .foregroundStyle(BrandColors.textSecondary)
                Text(project.name)
                    .font(BrandTypography.bodyEmphasis)
                    .foregroundStyle(BrandColors.textPrimary)
            }
        case .editing:
            TextField("Name", text: $nameDraft)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.next)
        }
    }

    @ViewBuilder
    private var descriptionRow: some View {
        switch mode {
        case .viewing:
            VStack(alignment: .leading, spacing: 2) {
                Text("Description")
                    .font(BrandTypography.caption)
                    .foregroundStyle(BrandColors.textSecondary)
                if let description = project.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !description.isEmpty {
                    Text(description)
                        .font(BrandTypography.body)
                        .foregroundStyle(BrandColors.textPrimary)
                } else {
                    Text("—")
                        .font(BrandTypography.body)
                        .foregroundStyle(BrandColors.textMuted)
                }
            }
        case .editing:
            TextField("Description (optional)", text: $descriptionDraft, axis: .vertical)
                .lineLimit(2 ... 6)
                .textInputAutocapitalization(.sentences)
        }
    }

    private var metadataSection: some View {
        Section {
            metadataRow(label: "Created", value: dateFormatter.string(from: project.createdAt))
            metadataRow(label: "Last updated", value: dateFormatter.string(from: project.updatedAt))
            metadataRow(label: "Created by", value: project.createdByUsername)
            metadataRow(label: "Project ID", value: project.id, monospaced: true)
        } header: {
            Text("Details")
                .font(BrandTypography.caption)
                .foregroundStyle(BrandColors.textSecondary)
        }
    }

    private func metadataRow(label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(BrandTypography.caption)
                .foregroundStyle(BrandColors.textSecondary)
            Spacer()
            Text(value)
                .font(monospaced ? BrandTypography.caption.monospaced() : BrandTypography.caption)
                .foregroundStyle(BrandColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Derived

    private var trimmedName: String {
        nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDescription: String {
        descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        let nameChanged = !trimmedName.isEmpty && trimmedName != project.name
        let descChanged = trimmedDescription != (project.description ?? "")
        return nameChanged || descChanged
    }

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }

    // MARK: - Save

    private func save() async {
        guard !trimmedName.isEmpty else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        // Only send fields the user actually changed — server
        // accepts a partial PATCH, so unchanged fields stay nil.
        let nameToSend: String? = (trimmedName != project.name) ? trimmedName : nil
        let descriptionCurrent = project.description ?? ""
        let descriptionToSend: String? = (trimmedDescription != descriptionCurrent) ? trimmedDescription : nil

        do {
            let updated = try await projects.update(
                projectID: project.id,
                workspaceID: workspaceID,
                name: nameToSend,
                description: descriptionToSend
            )
            project = updated
            mode = .viewing
        } catch let error as ProjectError {
            saveError = ProjectDetailView.message(for: error)
        } catch {
            saveError = error.localizedDescription
        }
    }

    private static func message(for error: ProjectError) -> String {
        switch error {
        case .notSignedIn:                   return "Sign in again to edit this project."
        case .workspaceMismatch:             return "This workspace's session expired. Re-pair to continue."
        case .networkUnavailable:            return "You're offline. Try again when you have a signal."
        case .timeout:                       return "The request timed out. Try again in a moment."
        case .permissionDenied(let r):       return "Not authorized: \(r)"
        case .notFound:                      return "This project no longer exists."
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
