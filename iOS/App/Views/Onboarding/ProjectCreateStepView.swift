import SwiftUI

/// New-project creation modal. Two text fields (name, description),
/// inline validation feedback, "Create" + "Cancel" buttons.
struct ProjectCreateStepView: View {
    let workspace: WorkspaceCredential
    let inProgress: Bool
    let lastError: String?
    let onCreate: (String, String?) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var description: String = ""
    @FocusState private var nameFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !trimmedName.isEmpty && trimmedName.count <= 200
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .focused($nameFocused)
                        .submitLabel(.next)
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                } header: {
                    Text("New project")
                } footer: {
                    Text("Project will be created in workspace \"\(workspace.workspaceName)\".")
                }

                if let lastError {
                    Section {
                        Label(lastError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Create")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(inProgress)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
                        onCreate(trimmedName, trimmedDescription.isEmpty ? nil : trimmedDescription)
                    }
                    .disabled(!isValid || inProgress)
                }
            }
            .overlay {
                if inProgress {
                    ProgressView()
                        .controlSize(.large)
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .onAppear { nameFocused = true }
        }
    }
}
