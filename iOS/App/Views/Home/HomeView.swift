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
    let projectName: String
    let userName: String
    let lastResult: HomeViewResult
    let isStartingCapture: Bool

    let onRecord: () -> Void
    let onClearResult: () -> Void

    /// Brief result banner shown above the Record CTA after a
    /// capture lifecycle event. Cleared by the parent (or by the
    /// user tapping Dismiss) before the next capture starts.
    enum HomeViewResult: Equatable {
        case none
        case completed(captureID: String)
        case cancelled
        case failed(reason: String)
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

    /// The hero. 96pt circular Lava 600 button with a centered
    /// SF Symbol mic icon. Tapping fires `onRecord` which kicks off
    /// `captureService.startCapture(...)` upstream.
    ///
    /// A spinner replaces the icon while the parent is awaiting
    /// `startCapture` to complete (server `POST /api/projects/.../captures`
    /// + recorder permission + recorder start) — that round trip is
    /// fast on a warm connection but can hit a few seconds on cold
    /// start. Without the spinner, users would double-tap and that
    /// re-tap would be rejected by `CaptureServiceError.alreadyCapturing`.
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
        .buttonStyle(.plain)
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
                onDismiss: onClearResult
            )
        case .cancelled:
            ResultBanner(
                icon: "xmark.circle.fill",
                accentColor: BrandColors.textSecondary,
                title: "Capture cancelled",
                detail: nil,
                onDismiss: onClearResult
            )
        case .failed(let reason):
            ResultBanner(
                icon: "exclamationmark.triangle.fill",
                accentColor: BrandColors.statusError,
                title: "Capture failed",
                detail: reason,
                onDismiss: onClearResult
            )
        }
    }

    // MARK: - Hint footer

    private var hint: some View {
        Text("\(userName)")
            .font(BrandTypography.caption.monospaced())
            .foregroundStyle(BrandColors.textSecondary)
    }
}

/// Small reusable result banner used by HomeView for the
/// completed / cancelled / failed states.
private struct ResultBanner: View {
    let icon: String
    let accentColor: Color
    let title: String
    let detail: String?
    let onDismiss: () -> Void

    var body: some View {
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
                        .lineLimit(2)
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
        .padding(Spacing.md)
        .background(BrandColors.surfacePrimary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(BrandColors.borderDefault, lineWidth: 0.5)
        )
    }
}
