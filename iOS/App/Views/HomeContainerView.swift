import SwiftUI

/// Steady-state container shown after onboarding completes. v1 is a
/// placeholder displaying the active context — full Home / Sessions
/// / Settings tabs land with Modules 02 (CaptureEngine) and 08 (UI).
///
/// This view exists now so the onboarding flow has somewhere to land
/// and the coordinator's `phase == .ready` transition is observable
/// end-to-end on the simulator.
struct HomeContainerView: View {
    @Bindable var coordinator: AppCoordinator

    #if DEBUG
    @State private var showingSmokeTest = false
    #endif

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("You're signed in")
                .font(.title2.bold())

            if let context = coordinator.activeContext {
                VStack(spacing: Spacing.xs) {
                    Label(context.workspace.workspaceName, systemImage: "server.rack")
                        .font(.subheadline)
                    Label(context.project.name, systemImage: "folder")
                        .font(.subheadline)
                    Text(context.user.userName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Spacing.xl)
            }

            Text("Capture, sessions, and settings tabs land with Modules 02 and 08.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)

            #if DEBUG
            if coordinator.captureAPI != nil, coordinator.activeContext != nil {
                Button {
                    showingSmokeTest = true
                } label: {
                    Label("Endpoint smoke test", systemImage: "stethoscope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, Spacing.xl)
            }
            #endif

            Spacer()

            Button(role: .destructive) {
                Task {
                    if let id = coordinator.activeContext?.workspace.id {
                        try? await coordinator.signOut(workspaceID: id)
                    }
                }
            } label: {
                Text("Sign out")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.lg)
        }
        #if DEBUG
        .sheet(isPresented: $showingSmokeTest) {
            if let api = coordinator.captureAPI,
               let context = coordinator.activeContext {
                EndpointSmokeTestView(
                    captureAPI: api,
                    workspaceID: context.workspace.id,
                    projectID: context.project.id,
                    onDismiss: { showingSmokeTest = false }
                )
            }
        }
        #endif
    }
}
