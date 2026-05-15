import SwiftUI

/// "Logged in as ..." confirmation step. Shows the SCIM-derived
/// display name + workspace name + URL so the user can confirm they
/// signed in to the right place before advancing to the project
/// picker.
struct IdentityConfirmationStepView: View {
    let credential: WorkspaceCredential
    let onContinue: () -> Void
    let onUseDifferent: () -> Void

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 60, weight: .regular))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            VStack(spacing: Spacing.sm) {
                Text("Welcome, \(credential.user.displayName)")
                    .font(.title2.bold())
                Text(credential.user.userName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: Spacing.xs) {
                Label(credential.workspaceName, systemImage: "server.rack")
                    .font(.subheadline)
                Text(credential.workspaceURL.host ?? credential.workspaceURL.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.xl)

            Spacer()

            VStack(spacing: Spacing.md) {
                Button(action: onContinue) {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: onUseDifferent) {
                    Text("Use a different account")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.lg)
        }
    }
}

#Preview {
    let credential = WorkspaceCredential(
        id: "ws-1",
        workspaceURL: URL(string: "https://acme-prod.cloud.databricks.com")!,
        workspaceName: "ACME Production",
        cloud: .aws,
        region: "us-west-2",
        user: UserIdentity(
            userID: "u-1",
            userName: "matthew.giglia@databricks.com",
            displayName: "Matthew Giglia",
            email: "matthew.giglia@databricks.com",
            active: true
        ),
        isDefault: true,
        signedInAt: Date(),
        identityRefreshedAt: Date(),
        appBaseURL: URL(string: "https://lakeloom-ai-dev-7474657291520070.aws.databricksapps.com")!,
        authMethod: .qrPaired(
            pairedSessionID: "preview-session",
            sessionExpiresAt: Date().addingTimeInterval(7 * 24 * 3_600)
        )
    )
    return IdentityConfirmationStepView(
        credential: credential,
        onContinue: {},
        onUseDifferent: {}
    )
}
