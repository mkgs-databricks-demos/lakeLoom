import SwiftUI

/// Workspace URL entry step. Coordinator validates via OIDC discovery
/// before advancing to OAuth.
struct WorkspaceURLStepView: View {
    let prefill: String?
    let onSubmit: (String) -> Void

    @State private var input: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            Image(systemName: "server.rack")
                .font(.system(size: 60, weight: .regular))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: Spacing.md) {
                Text("Enter your Databricks workspace")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text("e.g. acme-prod.cloud.databricks.com")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            TextField("workspace.cloud.databricks.com", text: $input)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                .focused($fieldFocused)
                .padding(.horizontal, Spacing.xl)
                .onSubmit { submitIfValid() }

            Spacer()

            Button(action: submitIfValid) {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, Spacing.xl)
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.bottom, Spacing.lg)
        }
        .onAppear {
            if let prefill, !prefill.isEmpty {
                input = prefill
            }
            fieldFocused = true
        }
    }

    private func submitIfValid() {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }
}

#Preview {
    WorkspaceURLStepView(prefill: nil, onSubmit: { _ in })
}

#Preview("Pre-filled") {
    WorkspaceURLStepView(prefill: "acme-prod.cloud.databricks.com", onSubmit: { _ in })
}
