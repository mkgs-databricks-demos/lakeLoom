import SwiftUI

/// Top-level container view. Switches on ``AppCoordinator/phase`` to
/// render the matching screen tree. Every transition cross-fades by
/// default so the user doesn't see frame-snap on phase changes.
struct RootView: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        Group {
            switch coordinator.phase {
            case .coldStart, .recovering, .preparingReady:
                SplashView()
            case .onboarding:
                OnboardingFlowView(coordinator: coordinator)
            case .ready:
                HomeContainerView(coordinator: coordinator)
            case .backgrounded:
                Color.clear
            case .error(let error):
                ErrorScreenView(
                    error: error,
                    onRetry: { Task { await coordinator.bootstrap() } }
                )
            }
        }
        .animation(.default, value: coordinator.phase)
    }
}
