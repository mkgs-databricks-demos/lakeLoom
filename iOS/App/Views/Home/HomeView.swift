import SwiftUI

/// Idle home view — the surface the user lands on after onboarding
/// and the surface they return to when a capture completes /
/// cancels / fails. Hero affordance is the Record button.
///
/// Presentational. The parent (``HomeContainerView``) owns the
/// state machine and dependency wiring; this view receives the
/// context + a small set of action closures.
struct HomeView: View {

    let workspaceName: String
    /// Host portion of the paired Databricks App URL (e.g.,
    /// `fevm-hls-fde.cloud.databricks.com`). Rendered next to the
    /// username in the footer so the user always sees which
    /// workspace they're talking to without opening the menu.
    let workspaceHost: String
    let projectName: String
    let userName: String
    let lastResult: HomeViewResult
    let isStartingCapture: Bool

    let onRecord: () -> Void
    let onClearResult: () -> Void
    /// Closure for the "primary action" button shown inside the
    /// result banner (e.g., "Open Settings" for permission-denied,
    /// "Try again" for network-unavailable). Nil when the banner
    /// has no actionable affordance.
    let onResultAction: () -> Void

    /// Brief result banner shown above the Record CTA after a
    /// capture lifecycle event. Cleared by the parent (or by the
    /// user tapping Dismiss) before the next capture starts.
    enum HomeViewResult: Equatable {
        case none
        case completed(captureID: String)
        case cancelled
        case failed(reason: String)
        /// Microphone permission denied. Specialized so the banner
        /// can render an "Open Settings" deep-link affordance
        /// rather than a generic error — the user can't recover
        /// without going to Settings.
        case microphonePermissionDenied
        /// Device has no working network. Specialized so the banner
        /// can render a "Try again" affordance with offline-aware
        /// copy.
        case networkUnavailable
    }

    var body: some View {
        ZStack {
            BrandColors.surfaceSecondary
                .ignoresSafeArea()

            VStack(spacing: Spacing.xl) {
                contextHeader
                Spacer()
                resultBanner
                recordButton
                Spacer()
                hint
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.lg)
        }
    }

    // MARK: - Header

    private var contextHeader: some View {
        VStack(spacing: Spacing.xs) {
            Text("WORKSPACE")
                .font(BrandTypography.caption)
                .foregroundStyle(BrandColors.textSecondary)
                .tracking(1.2)
            Text(workspaceName)
                .font(BrandTypography.bodyEmphasis)
                .foregroundStyle(BrandColors.textPrimary)
                .multilineTextAlignment(.center)

            Text("PROJECT")
                .font(BrandTypography.caption)
                .foregroundStyle(BrandColors.textSecondary)
                .tracking(1.2)
                .padding(.top, Spacing.sm)
            Text(projectName)
                .font(BrandTypography.titleMedium)
                .foregroundStyle(BrandColors.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
    }

    // MARK: - Record CTA

    /// The hero. 144pt circular Lava 600 button with a centered
    /// SF Symbol mic icon. Tapping fires `onRecord` which kicks off
    /// `captureService.startCapture(...)` upstream.
    ///
    /// A spinner replaces the icon while the parent is awaiting
    /// `startCapture` to complete (server `POST /api/projects/.../captures`
    /// + recorder permission + recorder start) — that round trip is
    /// fast on a warm connection but can hit a few seconds on cold
    /// start. Without the spinner, users would double-tap and that
    /// re-tap would be rejected by `CaptureServiceError.alreadyCapturing`.
    ///
    /// Press feedback: scale down to 92% on tap-down using
    /// `BrandMotion.brandPress` (100 ms easeOut, respects reduce
    /// motion). Catches the eye on the way down + adds physical-feeling
    /// tactility without competing with the pulsing Lava during recording.
    private var recordButton: some View {
        Button(action: onRecord) {
            ZStack {
                Circle()
                    .fill(BrandColors.accentPrimary)
                    .frame(width: 144, height: 144)
                    .shadow(color: BrandColors.accentPrimary.opacity(0.4), radius: 24, x: 0, y: 8)

                if isStartingCapture {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(RecordButtonPressStyle())
        .accessibilityLabel("Record")
        .accessibilityHint("Starts a capture session in this project.")
        .disabled(isStartingCapture)
    }

    // MARK: - Result banner

    @ViewBuilder
    private var resultBanner: some View {
        switch lastResult {
        case .none:
            EmptyView()
        case .completed(let captureID):
            ResultBanner(
                icon: "checkmark.circle.fill",
                accentColor: BrandColors.statusSuccess,
                title: "Capture saved",
                detail: "ID \(captureID.prefix(8))…",
                actionTitle: nil,
                onAction: nil,
                onDismiss: onClearResult
            )
        case .cancelled:
            ResultBanner(
                icon: "xmark.circle.fill",
                accentColor: BrandColors.textSecondary,
                title: "Capture cancelled",
                detail: nil,
                actionTitle: nil,
                onAction: nil,
                onDismiss: onClearResult
            )
        case .failed(let reason):
            ResultBanner(
                icon: "exclamationmark.triangle.fill",
                accentColor: BrandColors.statusError,
                title: "Capture failed",
                detail: reason,
                actionTitle: nil,
                onAction: nil,
                onDismiss: onClearResult
            )
        case .microphonePermissionDenied:
            ResultBanner(
                icon: "mic.slash.fill",
                accentColor: BrandColors.statusError,
                title: "Microphone access denied",
                detail: "lakeLoom needs microphone access to record. Open Settings to allow it.",
                actionTitle: "Open Settings",
                onAction: onResultAction,
                onDismiss: onClearResult
            )
        case .networkUnavailable:
            ResultBanner(
                icon: "wifi.slash",
                accentColor: BrandColors.statusWarning,
                title: "You're offline",
                detail: "Couldn't reach the lakeLoom Databricks App. Try again when you have a signal.",
                actionTitle: "Try again",
                onAction: onResultAction,
                onDismiss: onClearResult
            )
        }
    }

    // MARK: - Hint footer

    private var hint: some View {
        VStack(spacing: 2) {
            if !workspaceHost.isEmpty {
                Text(workspaceHost)
                    .font(BrandTypography.caption.monospaced())
                    .foregroundStyle(BrandColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(userName)
                .font(BrandTypography.caption.monospaced())
                .foregroundStyle(BrandColors.textSecondary)
        }
    }
}

/// `ButtonStyle` for the Record CTA. Scales the label to 92% on
/// press using the brand motion's 100ms easeOut curve, and
/// degrades to no animation when Reduce Motion is on. We can't
/// rely on the system `.borderedProminent` style for this because
/// the Record button is a custom Circle, not a chip.
private struct RecordButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(
                Animation.brandRespectingReduceMotion(
                    .brandPress,
                    duration: BrandMotion.buttonPress
                ),
                value: configuration.isPressed
            )
    }
}

/// Small reusable result banner used by HomeView for the
/// completed / cancelled / failed / permission-denied /
/// network-unavailable states. When `actionTitle` is set, the
/// banner renders a primary CTA in addition to the dismiss
/// affordance.
private struct ResultBanner: View {
    let icon: String
    let accentColor: Color
    let title: String
    let detail: String?
    let actionTitle: String?
    let onAction: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .top, spacing: Spacing.md) {
                Image(systemName: icon)
                    .font(BrandTypography.titleSmall)
                    .foregroundStyle(accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(BrandTypography.bodyEmphasis)
                        .foregroundStyle(BrandColors.textPrimary)
                    if let detail {
                        Text(detail)
                            .font(BrandTypography.caption)
                            .foregroundStyle(BrandColors.textSecondary)
                            .lineLimit(3)
                    }
                }
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(BrandTypography.captionMedium)
                        .foregroundStyle(BrandColors.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }

            if let actionTitle, let onAction {
                Button(action: onAction) {
                    Text(actionTitle)
                        .font(BrandTypography.bodyEmphasis)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)
            }
        }
        .padding(Spacing.md)
        .background(BrandColors.surfacePrimary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(BrandColors.borderDefault, lineWidth: 0.5)
        )
    }
}
