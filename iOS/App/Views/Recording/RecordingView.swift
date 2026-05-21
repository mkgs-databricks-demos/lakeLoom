import SwiftUI

/// In-session view shown while a capture is `.recording` or
/// `.finalizing`. Designed for full-screen presentation during a
/// meeting — Navy 800 surface, no chrome distractions, only the
/// affordances a user needs while the recording is live.
///
/// State binding is owned by the parent (``HomeContainerView``)
/// which subscribes to ``CaptureService/stateUpdates()``. This view
/// is presentational: it receives the current state and the three
/// action closures and renders them.
struct RecordingView: View {

    /// The current capture state. Defaults to `.recording` for
    /// SwiftUI previews; the parent passes the live value at render
    /// time. Only `.recording` and `.finalizing` are expected here
    /// — other cases trigger the parent to dismiss the cover.
    let state: CaptureServiceState

    /// Invoked when the user taps "Stop". Calls
    /// ``CaptureService/stopCapture()`` upstream.
    let onStop: () -> Void

    /// Invoked when the user taps "Cancel". Calls
    /// ``CaptureService/cancelCapture()`` upstream.
    let onCancel: () -> Void

    /// Project name to surface in the header. Pulled from the
    /// `CaptureContext` by the parent so this view doesn't need to
    /// pattern-match against the state's associated context twice.
    let projectName: String

    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            BrandColors.surfacePrimary
                .ignoresSafeArea()

            VStack(spacing: Spacing.xxl) {
                header
                Spacer()
                stateIndicator
                elapsedReadout
                Spacer()
                actionButtons
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.xxl)
        }
        .onAppear {
            // Drive the recording-dot pulse via a repeating
            // .easeInOut. Wrapped in the brand-motion reduce-motion
            // probe so users who've turned that on don't see the
            // scale animation — they still see the red dot, just
            // static.
            guard !BrandMotion.prefersReducedMotion else { return }
            withAnimation(
                .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
            ) {
                pulseScale = 1.18
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Spacing.xs) {
            Text(headerTitle)
                .font(BrandTypography.caption)
                .foregroundStyle(BrandColors.textSecondary)
                .textCase(.uppercase)
                .tracking(1)
            Text(projectName)
                .font(BrandTypography.titleMedium)
                .foregroundStyle(BrandColors.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
    }

    private var headerTitle: String {
        switch state {
        case .recording:   return "Recording"
        case .finalizing:  return "Finalizing"
        default:           return "Capture"
        }
    }

    // MARK: - State indicator

    /// Pulsing Lava 600 dot for `.recording`; spinner for
    /// `.finalizing`. The two states are visually distinct so the
    /// user sees "I'm still in control / Stop will end this" vs
    /// "iOS is now uploading on your behalf."
    @ViewBuilder
    private var stateIndicator: some View {
        switch state {
        case .recording:
            Circle()
                .fill(BrandColors.accentPrimary)
                .frame(width: 96, height: 96)
                .scaleEffect(pulseScale)
                .accessibilityLabel("Recording in progress")
        case .finalizing(_, let pending):
            VStack(spacing: Spacing.sm) {
                ProgressView()
                    .controlSize(.large)
                    .tint(BrandColors.accentPrimary)
                Text("Uploading \(pending.count) file\(pending.count == 1 ? "" : "s")…")
                    .font(BrandTypography.bodyEmphasis)
                    .foregroundStyle(BrandColors.textSecondary)
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Elapsed time

    @ViewBuilder
    private var elapsedReadout: some View {
        switch state {
        case .recording(let context):
            TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                Text(ElapsedTimer.format(timeline.date.timeIntervalSince(context.startedAt)))
                    .font(.system(size: 48, weight: .semibold, design: .monospaced))
                    .foregroundStyle(BrandColors.textPrimary)
                    .monospacedDigit()
            }
        case .finalizing(let context, _):
            Text(ElapsedTimer.format(Date().timeIntervalSince(context.startedAt)))
                .font(.system(size: 32, weight: .regular, design: .monospaced))
                .foregroundStyle(BrandColors.textSecondary)
                .monospacedDigit()
        default:
            EmptyView()
        }
    }

    // MARK: - Action buttons

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: Spacing.md) {
            primaryButton
            cancelButton
        }
    }

    private var primaryButton: some View {
        Button(action: onStop) {
            Label(primaryButtonTitle, systemImage: primaryButtonSystemImage)
                .font(BrandTypography.bodyEmphasis)
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.borderedProminent)
        .tint(BrandColors.accentPrimary)
        .accessibilityHint("Ends the capture and uploads the recording.")
        // Stop is disabled while finalizing — the recording is
        // already over; the only meaningful action there is Cancel
        // (which discards the in-flight uploads).
        .disabled(isFinalizing)
    }

    private var primaryButtonTitle: String {
        switch state {
        case .recording:   return "Stop"
        case .finalizing:  return "Finalizing…"
        default:           return "Stop"
        }
    }

    private var primaryButtonSystemImage: String {
        isFinalizing ? "hourglass" : "stop.circle.fill"
    }

    private var cancelButton: some View {
        Button(role: .destructive, action: onCancel) {
            Text(cancelButtonTitle)
                .font(BrandTypography.bodyEmphasis)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.bordered)
        .tint(BrandColors.statusError)
    }

    private var cancelButtonTitle: String {
        switch state {
        case .recording:   return "Cancel"
        case .finalizing:  return "Cancel + discard uploads"
        default:           return "Cancel"
        }
    }

    private var isFinalizing: Bool {
        if case .finalizing = state { return true }
        return false
    }
}
