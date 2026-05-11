import AuthenticationServices
import SwiftUI

/// OAuth login presentation step. Drives `ASWebAuthenticationSession`
/// via the coordinator so the system browser can handle SSO / passkey
/// flows. The button is disabled while a login is in flight.
struct OAuthLoginStepView: View {
    let workspaceURL: URL
    let inProgress: Bool
    let lastError: String?

    /// We need the coordinator here (not just a closure) because
    /// `startOAuthSignIn` requires an
    /// `ASWebAuthenticationPresentationContextProviding` which we
    /// vend from this view's window scene.
    let coordinator: AppCoordinator

    @State private var presentationProvider: WindowScenePresentationProvider?

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 60, weight: .regular))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: Spacing.sm) {
                Text("Sign in to Databricks")
                    .font(.title2.bold())
                Text(workspaceURL.host ?? workspaceURL.absoluteString)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, Spacing.xl)

            if let lastError {
                Label(lastError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, Spacing.xl)
            }

            Spacer()

            Button(action: { startSignIn() }) {
                if inProgress {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Sign in")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, Spacing.xl)
            .disabled(inProgress)
            .padding(.bottom, Spacing.lg)
        }
        .onAppear {
            if presentationProvider == nil {
                presentationProvider = WindowScenePresentationProvider()
            }
        }
    }

    private func startSignIn() {
        guard let provider = presentationProvider else { return }
        Task { await coordinator.startOAuthSignIn(presenting: provider) }
    }
}

/// Vends an `ASPresentationAnchor` from the foreground active window
/// scene. Required by `ASWebAuthenticationSession` and constructed
/// per-view to avoid stale references.
@MainActor
final class WindowScenePresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first {
            return ASPresentationAnchor(windowScene: scene)
        }
        // Unreachable in normal app lifecycle — by the time this view
        // is on screen there is always a foreground scene.
        fatalError("OAuthLoginStepView has no UIWindowScene to present from")
    }
}
