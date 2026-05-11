import SwiftUI

/// First step of onboarding. Sets expectations about what the app
/// records and where it goes; the user taps "I understand" to
/// acknowledge the current consent version (per
/// ``ConsentVersion/current``).
struct ConsentStepView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            Image(systemName: "waveform.and.mic")
                .font(.system(size: 80, weight: .regular))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: Spacing.md) {
                Text("Capture conversations to build with Databricks")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text(consentBody)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
            }

            Spacer()

            Button(action: onContinue) {
                Text("I understand")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, Spacing.xl)

            Text("Privacy policy")
                .font(.footnote)
                .foregroundStyle(.tint)
                .padding(.bottom, Spacing.lg)
        }
    }

    private var consentBody: String {
        """
        This app records your voice when you press the capture button. \
        Transcripts are sent to your Databricks workspace to help generate \
        requirements and architecture plans for your projects.

        Audio stays on your device until Wi-Fi is available, then uploads to your workspace.
        """
    }
}

#Preview("Light") {
    ConsentStepView(onContinue: {})
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    ConsentStepView(onContinue: {})
        .preferredColorScheme(.dark)
}
