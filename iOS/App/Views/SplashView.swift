import SwiftUI

/// Splash placeholder shown during cold start, recovery passes, and the brief
/// preparingReady phase between sign-in and the home screen. Keeps the
/// transition between phases steady — no jarring black-frame jumps.
struct SplashView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: Spacing.lg) {
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 72, weight: .regular))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text("lakeLoom")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("Weave requirements into rapid Databricks MVPs.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("lakeLoom. Weave requirements into rapid Databricks MVPs.")
    }
}

#Preview("Light") {
    SplashView()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    SplashView()
        .preferredColorScheme(.dark)
}

#Preview("Accessibility — XXL") {
    SplashView()
        .environment(\.dynamicTypeSize, .accessibility3)
}
