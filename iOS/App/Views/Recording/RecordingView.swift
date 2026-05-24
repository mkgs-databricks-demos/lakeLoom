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

    /// Factory for the live transcript-segment stream. Returns nil
    /// when no live recognizer is wired (older test paths, permission
    /// denied, etc.) — the transcript panel then hides entirely. The
    /// view consumes the stream in a `.task` and accumulates segments
    /// into `segments` for the scrolling display. The factory should
    /// return a fresh independent stream per call.
    let transcriptStream: (() async -> AsyncStream<TranscriptSegment>?)?

    /// Optional in-session photo capture trigger. When provided, the
    /// view shows a camera button next to Stop that awaits this
    /// closure — the closure presents the camera (via
    /// ``PhotoCapture``), enqueues the resulting JPEG on the
    /// ``UploadCoordinator``, and returns once both finish. Nil
    /// hides the button entirely (older test paths or builds without
    /// a photoCapture dependency).
    let onCapturePhoto: (() async -> Void)?

    @State private var pulseScale: CGFloat = 1.0
    @State private var segments: [TranscriptSegment] = []
    @State private var isCapturingPhoto = false

    var body: some View {
        ZStack {
            BrandColors.surfacePrimary
                .ignoresSafeArea()

            VStack(spacing: Spacing.xl) {
                header
                transcriptPanel
                Spacer(minLength: Spacing.md)
                stateIndicator
                elapsedReadout
                Spacer(minLength: Spacing.md)
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
        .task { await subscribeToTranscripts() }
    }

    // MARK: - Live transcript panel

    /// Scrolling panel of phrases as the on-device speech recognizer
    /// emits them. Surfaces the "rapid prototyping" demo loop —
    /// users see their own words appearing in real time, which is
    /// the proof point that the in-session pipeline is alive.
    ///
    /// Hidden entirely when no segments have arrived yet (so we
    /// don't take up space with a blank box during the silent
    /// pre-speech moments of a session). Auto-scrolls to the newest
    /// segment on every append.
    @ViewBuilder
    private var transcriptPanel: some View {
        if !segments.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        ForEach(segments, id: \.segmentIndex) { segment in
                            Text(segment.text)
                                .font(BrandTypography.body)
                                .foregroundStyle(BrandColors.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(segment.segmentIndex)
                        }
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.md)
                }
                .frame(maxHeight: 200)
                .background(
                    BrandColors.surfaceSecondary,
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(BrandColors.borderDefault, lineWidth: 0.5)
                )
                .onChange(of: segments.count) { _, _ in
                    guard let last = segments.last else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.segmentIndex, anchor: .bottom)
                    }
                }
            }
            .transition(.opacity)
        }
    }

    /// Pull segments off the captureService's broadcast stream into
    /// `segments`. Runs for the life of this view's `.task`, which
    /// is the same as the recording cover (mounts on `.recording`,
    /// unmounts when the parent dismisses the cover). The stream
    /// naturally finishes when the recognizer's drain task closes
    /// every UI subscriber on capture stop/cancel — no manual
    /// cancellation needed.
    private func subscribeToTranscripts() async {
        guard let factory = transcriptStream else { return }
        guard let stream = await factory() else { return }
        for await segment in stream {
            segments.append(segment)
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
            if let onCapturePhoto, case .recording = state {
                photoButton(onCapturePhoto: onCapturePhoto)
            }
            primaryButton
            cancelButton
        }
    }

    /// Camera button — only visible during `.recording`, never
    /// `.finalizing` (uploads are draining; new attachments would
    /// race the server-side state transition). Spinner replaces the
    /// label while the underlying `PhotoCapture` presents the camera
    /// and writes the JPEG, since the closure is fire-and-forget on
    /// the view's side.
    private func photoButton(onCapturePhoto: @escaping () async -> Void) -> some View {
        Button {
            Task {
                isCapturingPhoto = true
                await onCapturePhoto()
                isCapturingPhoto = false
            }
        } label: {
            HStack(spacing: Spacing.sm) {
                if isCapturingPhoto {
                    ProgressView().controlSize(.small).tint(BrandColors.accentPrimary)
                } else {
                    Image(systemName: "camera.fill")
                }
                Text(isCapturingPhoto ? "Capturing…" : "Take photo")
                    .font(BrandTypography.bodyEmphasis)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.bordered)
        .tint(BrandColors.accentPrimary)
        .disabled(isCapturingPhoto)
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
