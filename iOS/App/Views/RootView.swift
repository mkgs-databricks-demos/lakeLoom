import SwiftUI

/// Top-level container view. In v1 it will switch on AppCoordinator.phase
/// to render Splash / Onboarding / Home / Error. For the scaffold it just
/// shows the splash placeholder so the project builds and runs end-to-end.
struct RootView: View {
    var body: some View {
        SplashView()
    }
}

#Preview {
    RootView()
}
