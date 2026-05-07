import SwiftUI

/// Terminal error screen shown when bootstrap fails or an
/// unrecoverable condition forces ``AppPhase/error``. Offers a
/// "Try again" affordance that re-runs ``AppCoordinator/bootstrap()``.
struct ErrorScreenView: View {
    let error: AppError
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(spacing: Spacing.sm) {
                Text("Something went wrong")
                    .font(.title2.bold())
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
            }

            Spacer()

            Button(action: onRetry) {
                Text("Try again")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.lg)
        }
    }

    private var message: String {
        switch error {
        case .bootstrapFailed(let reason):
            return "Couldn't start the app: \(reason)"
        case .authError(let authError):
            return "Sign-in error: \(String(describing: authError))"
        case .projectFetchFailed(let reason):
            return "Couldn't load projects: \(reason)"
        case .projectCreateFailed(let reason):
            return "Couldn't create the project: \(reason)"
        case .workspaceSwitchBlockedByActiveCapture:
            return "Stop the active capture session before switching workspaces."
        case .projectSwitchBlockedByActiveCapture:
            return "Stop the active capture session before switching projects."
        case .signOutBlockedByActiveCapture:
            return "Stop the active capture session before signing out."
        case .unknown(let reason):
            return reason
        }
    }
}

#Preview {
    ErrorScreenView(
        error: .bootstrapFailed(reason: "Core Data store could not be opened."),
        onRetry: {}
    )
}
