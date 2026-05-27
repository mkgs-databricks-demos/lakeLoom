import SwiftUI
import UIKit

/// Steady-state container shown after onboarding completes. Owns
/// the orchestration between ``HomeView`` (idle) and
/// ``RecordingView`` (in-session) based on the live
/// ``CaptureService`` state.
///
/// The view subscribes to `captureService.stateUpdates()` via
/// `.task` and reflects the stream into local `@State` so the
/// observed transitions drive both the fullScreenCover present /
/// dismiss AND the home-screen result banner.
struct HomeContainerView: View {

    @Bindable var coordinator: AppCoordinator

    /// Mirror of the live `CaptureService.state`. Set during
    /// `.task` and on each yielded state update.
    @State private var captureState: CaptureServiceState = .idle

    /// True from when the user taps Record until the parent service
    /// transitions to `.recording` (or back to `.failed` / `.idle`).
    /// Drives the spinner inside the Record button so users don't
    /// double-tap during the create-session + permission + start
    /// round-trip.
    @State private var isStartingCapture = false

    /// Result banner shown on the home view after a capture finishes
    /// or aborts. Captured from the most-recent terminal transition
    /// and cleared when the user dismisses it or starts a new
    /// capture.
    @State private var lastResult: HomeView.HomeViewResult = .none

    #if DEBUG
    @State private var showingSmokeTest = false
    #endif

    @State private var showingPendingUploads = false
    @State private var showingProjectSwitcher = false
    @State private var showingDocuments = false
    @State private var showingAccount = false
    @State private var showingRepairScanner = false
    /// Banner shown after a re-pair attempt resolves. Distinct from
    /// `lastResult` (which is capture-flow scoped) so the two don't
    /// fight for the same surface.
    @State private var repairBanner: RepairBanner = .none
    @State private var differentWorkspacePrompt: DifferentWorkspacePrompt?

    enum RepairBanner: Equatable {
        case none
        case success(workspaceName: String, until: Date)
        case failure(reason: String)
    }

    struct DifferentWorkspacePrompt: Identifiable, Equatable {
        let id = UUID()
        let qrText: String
        let scannedName: String
    }

    /// Live count of `UploadCoordinator.currentUploads()`. Drives a
    /// badge on the toolbar so the user can tell at a glance when
    /// there's anything in flight or stuck. Re-snapshots on every
    /// upload-state transition.
    @State private var pendingUploadCount = 0

    var body: some View {
        NavigationStack {
            HomeView(
                workspaceName: workspaceName,
                workspaceHost: workspaceHost,
                projectName: projectName,
                userName: userName,
                lastResult: lastResult,
                isStartingCapture: isStartingCapture,
                isOnline: coordinator.reachability?.isOnline ?? true,
                onRecord: startCapture,
                onClearResult: { lastResult = .none },
                onResultAction: performResultAction
            )
            .toolbar { toolbar }
            .safeAreaInset(edge: .top) {
                repairBannerView
            }
        }
        .fullScreenCover(isPresented: bindingForRecordingPresentation) {
            if let context = currentCaptureContext {
                RecordingView(
                    state: captureState,
                    onStop: stopCapture,
                    onCancel: cancelCapture,
                    projectName: projectName.isEmpty ? "Capture" : projectName,
                    transcriptStream: { [captureService = coordinator.captureService] in
                        guard let service = captureService else { return nil }
                        return await service.transcriptSegmentUpdates()
                    },
                    interruptionStream: { [captureService = coordinator.captureService] in
                        guard let service = captureService else { return nil }
                        return await service.interruptionUpdates()
                    },
                    onCapturePhoto: { [captureService = coordinator.captureService] in
                        guard let service = captureService else { return }
                        do {
                            try await service.capturePhoto()
                        } catch let error as CaptureServiceError {
                            // Camera failures don't tear down the
                            // capture — surface the same banner
                            // machinery used for terminal results
                            // so the user sees what went wrong and
                            // can retry.
                            await MainActor.run {
                                self.lastResult = Self.result(for: error)
                            }
                        } catch {
                            await MainActor.run {
                                self.lastResult = .failed(reason: error.localizedDescription)
                            }
                        }
                    }
                )
                .ignoresSafeArea()
                // Drop the system back-swipe so the user can't
                // accidentally dismiss the recording cover. The only
                // exits are Stop / Cancel, which go through
                // CaptureService.
                .interactiveDismissDisabled()
                .id(context.captureSessionID)
            }
        }
        .task {
            // Mirror the live state stream into @State. Replay is
            // delivered as the first yield (the service replays the
            // current state to every new subscriber), so this
            // primes captureState without any extra plumbing.
            guard let service = coordinator.captureService else { return }
            captureState = await service.state
            let stream = await service.stateUpdates()
            for await next in stream {
                handle(transition: next)
            }
        }
        .task { await observePendingUploadCount() }
        .sheet(isPresented: $showingAccount) {
            if let context = coordinator.activeContext {
                AccountSettingsView(
                    context: context,
                    deviceIdentity: coordinator.deviceIdentity,
                    onSignOut: {
                        showingAccount = false
                        Task {
                            try? await coordinator.signOut(workspaceID: context.workspace.id)
                        }
                    },
                    onRepair: {
                        // Dismiss the Account sheet first; iOS doesn't
                        // play nicely with stacking a second sheet on
                        // top of the form. The scanner sheet opens
                        // after the dismiss animation settles.
                        showingAccount = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            showingRepairScanner = true
                        }
                    },
                    onDismiss: { showingAccount = false }
                )
            }
        }
        .sheet(isPresented: $showingRepairScanner) {
            RepairScannerSheet(
                onScan: { qrText in
                    showingRepairScanner = false
                    Task { await handleRepair(qrText: qrText, allowWorkspaceSwitch: false) }
                },
                onCancel: { showingRepairScanner = false }
            )
        }
        .alert(
            "Different workspace?",
            isPresented: Binding(
                get: { differentWorkspacePrompt != nil },
                set: { if !$0 { differentWorkspacePrompt = nil } }
            ),
            presenting: differentWorkspacePrompt
        ) { prompt in
            Button("Replace pairing") {
                let scanned = prompt.qrText
                differentWorkspacePrompt = nil
                Task { await handleRepair(qrText: scanned, allowWorkspaceSwitch: true) }
            }
            Button("Cancel", role: .cancel) {
                differentWorkspacePrompt = nil
            }
        } message: { prompt in
            Text("This QR is for \(prompt.scannedName). Continuing will sign this device into that workspace instead.")
        }
        .sheet(isPresented: $showingDocuments) {
            if let api = coordinator.captureAPI,
               let context = coordinator.activeContext {
                ProjectDocumentsView(
                    captureAPI: api,
                    mediaContent: coordinator.mediaContent,
                    workspaceID: context.workspace.id,
                    projectID: context.project.id,
                    projectName: context.project.name,
                    onDismiss: { showingDocuments = false }
                )
            }
        }
        .sheet(isPresented: $showingProjectSwitcher) {
            if let context = coordinator.activeContext {
                ProjectSwitcherView(
                    projects: coordinator.projects,
                    workspaceID: context.workspace.id,
                    workspaceName: context.workspace.workspaceName,
                    activeProjectID: context.project.id,
                    onSelect: { projectID in
                        Task {
                            await coordinator.switchActiveProject(to: projectID)
                            showingProjectSwitcher = false
                        }
                    },
                    onCreate: { name, description in
                        // Throws ProjectError on failure; the form view
                        // surfaces it inline. On success the form
                        // dismisses the whole sheet via its onSuccess
                        // callback (which maps to onDismiss here).
                        _ = try await coordinator.createAndSwitchToProject(
                            name: name,
                            description: description
                        )
                    },
                    onDismiss: { showingProjectSwitcher = false }
                )
            }
        }
        .sheet(isPresented: $showingPendingUploads) {
            if let uploads = coordinator.uploadCoordinator {
                PendingUploadsView(
                    uploadCoordinator: uploads,
                    captureAPI: coordinator.captureAPI,
                    workspaceID: coordinator.activeContext?.workspace.id,
                    onDismiss: { showingPendingUploads = false }
                )
            }
        }
        #if DEBUG
        .sheet(isPresented: $showingSmokeTest) {
            if let api = coordinator.captureAPI,
               let context = coordinator.activeContext {
                EndpointSmokeTestView(
                    captureAPI: api,
                    uploadCoordinator: coordinator.uploadCoordinator,
                    photoCapture: coordinator.photoCapture,
                    transcriptEvents: coordinator.transcriptEvents,
                    deviceIdentity: coordinator.deviceIdentity,
                    workspaceID: context.workspace.id,
                    projectID: context.project.id,
                    pairedSessionID: context.workspace.authMethod.pairedSessionID,
                    onDismiss: { showingSmokeTest = false }
                )
            }
        }
        #endif
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if let api = coordinator.captureAPI,
               let context = coordinator.activeContext {
                NavigationLink {
                    SessionsListView(
                        captureAPI: api,
                        uploadCoordinator: coordinator.uploadCoordinator,
                        mediaContent: coordinator.mediaContent,
                        workspaceID: context.workspace.id,
                        projectID: context.project.id,
                        projectName: context.project.name
                    )
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .accessibilityLabel("Captures")
                }
            }
        }
        if pendingUploadCount > 0 {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingPendingUploads = true
                } label: {
                    Image(systemName: "tray.and.arrow.up.fill")
                        .overlay(alignment: .topTrailing) {
                            Text("\(pendingUploadCount)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(BrandColors.accentPrimary, in: Capsule())
                                .offset(x: 10, y: -8)
                        }
                }
                .accessibilityLabel("Pending uploads — \(pendingUploadCount)")
            }
        }
        if let expiresAt = coordinator.activeContext?.workspace.authMethod.sessionExpiresAt {
            ToolbarItem(placement: .topBarTrailing) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let status = PairingStatus(expiresAt: expiresAt, now: context.date)
                    if status.level == .warning || status.level == .urgent {
                        Button {
                            showingRepairScanner = true
                        } label: {
                            PairingStatusChip(
                                level: status.level,
                                label: status.shortDescription
                            )
                        }
                        .accessibilityHint("Tap to scan a fresh QR code and refresh this device's pairing.")
                    }
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if coordinator.activeContext != nil {
                    Button {
                        showingAccount = true
                    } label: {
                        Label("Account", systemImage: "person.crop.circle")
                    }
                    Button {
                        showingProjectSwitcher = true
                    } label: {
                        Label("Switch project", systemImage: "folder.badge.gear")
                    }
                }
                if coordinator.captureAPI != nil, coordinator.activeContext != nil {
                    Button {
                        showingDocuments = true
                    } label: {
                        Label("Documents", systemImage: "doc.text")
                    }
                }
                if coordinator.uploadCoordinator != nil {
                    Button {
                        showingPendingUploads = true
                    } label: {
                        Label("Pending uploads", systemImage: "tray.and.arrow.up")
                    }
                }
                #if DEBUG
                if coordinator.captureAPI != nil, coordinator.activeContext != nil {
                    Button {
                        showingSmokeTest = true
                    } label: {
                        Label("Endpoint smoke test", systemImage: "stethoscope")
                    }
                }
                #endif
                Button(role: .destructive) {
                    Task {
                        if let id = coordinator.activeContext?.workspace.id {
                            try? await coordinator.signOut(workspaceID: id)
                        }
                    }
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("More")
            }
        }
    }

    /// Mirror `UploadCoordinator.currentUploads().count` into local
    /// state so the toolbar badge updates live. Re-snapshots on
    /// every `stateUpdates()` yield — covers enqueues, transitions,
    /// and the now-automatic discard on `.succeeded` (which arrives
    /// as a final stream event before the entry vanishes).
    private func observePendingUploadCount() async {
        guard let uploads = coordinator.uploadCoordinator else { return }
        pendingUploadCount = await uploads.currentUploads().count
        let stream = await uploads.stateUpdates()
        for await _ in stream {
            pendingUploadCount = await uploads.currentUploads().count
        }
    }

    // MARK: - Derived context

    private var workspaceName: String {
        coordinator.activeContext?.workspace.workspaceName ?? "—"
    }

    /// Host portion of the paired Databricks App URL (e.g.,
    /// `fevm-hls-fde.cloud.databricks.com`). Empty string when no
    /// workspace is active so `HomeView` can hide the host row
    /// during the brief pre-context render.
    private var workspaceHost: String {
        coordinator.activeContext?.workspace.workspaceURL.host ?? ""
    }

    private var projectName: String {
        coordinator.activeContext?.project.name ?? "—"
    }

    private var userName: String {
        coordinator.activeContext?.user.userName ?? ""
    }

    /// True while the capture state is in an "in-session" state —
    /// `.recording` or `.finalizing`. The fullScreenCover is bound
    /// to this; transitions to `.completed` / `.cancelled` /
    /// `.failed` / `.idle` automatically dismiss the cover.
    private var bindingForRecordingPresentation: Binding<Bool> {
        Binding(
            get: { isInSession },
            set: { _ in
                // The cover is dismissed by state transitions, not
                // by user action. Swallow programmatic sets so a
                // swipe-dismiss from iOS can't desync our state.
            }
        )
    }

    private var isInSession: Bool {
        switch captureState {
        case .recording, .finalizing: return true
        default: return false
        }
    }

    private var currentCaptureContext: CaptureContext? {
        switch captureState {
        case .recording(let context):       return context
        case .finalizing(let context, _):   return context
        default:                            return nil
        }
    }

    // MARK: - Actions

    private func startCapture() {
        guard let service = coordinator.captureService,
              let context = coordinator.activeContext else { return }
        // Clear any prior result banner so a new capture starts
        // from a clean home screen.
        lastResult = .none
        isStartingCapture = true
        Task {
            do {
                try await service.startCapture(
                    workspaceID: context.workspace.id,
                    projectID: context.project.id,
                    label: defaultLabel()
                )
                // .recording transition is observed in handle(transition:)
            } catch let error as CaptureServiceError {
                lastResult = result(for: error)
            } catch {
                lastResult = .failed(reason: error.localizedDescription)
            }
            isStartingCapture = false
        }
    }

    /// Handler for the result-banner CTA. The closure is the same
    /// for every banner type; the action it performs is keyed off
    /// the current `lastResult`.
    ///
    /// * `.microphonePermissionDenied` → open the iOS Settings app
    ///   so the user can grant access.
    /// * `.networkUnavailable` → re-fire `startCapture`.
    /// * Anything else → no-op (the banners that hit this path
    ///   should be the only ones that have an action button).
    private func performResultAction() {
        switch lastResult {
        case .microphonePermissionDenied:
            openSettings()
        case .networkUnavailable:
            startCapture()
        default:
            break
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }

    private func stopCapture() {
        guard let service = coordinator.captureService else { return }
        Task {
            do {
                try await service.stopCapture()
            } catch {
                lastResult = .failed(reason: error.localizedDescription)
            }
        }
    }

    private func cancelCapture() {
        guard let service = coordinator.captureService else { return }
        Task {
            do {
                try await service.cancelCapture()
            } catch {
                lastResult = .failed(reason: error.localizedDescription)
            }
        }
    }

    // MARK: - Transition handler

    /// Single point that mirrors state updates and derives the home
    /// view's result banner from terminal transitions.
    private func handle(transition: CaptureServiceState) {
        captureState = transition
        switch transition {
        case .completed(let context):
            lastResult = .completed(captureID: context.captureSessionID)
            isStartingCapture = false
        case .cancelled:
            lastResult = .cancelled
            isStartingCapture = false
        case .failed(let reason):
            lastResult = .failed(reason: reason)
            isStartingCapture = false
        case .recording, .finalizing:
            isStartingCapture = false
        case .idle:
            break
        }
    }

    /// Default capture label. Brief, unobtrusive — gives the
    /// session list a sortable timestamp without prompting the user
    /// for input every time they hit Record. Module 02 PR 7c will
    /// add a label-edit affordance on the sessions list.
    private func defaultLabel() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Capture \(formatter.string(from: Date()))"
    }

    /// Translate a typed `CaptureServiceError` into the
    /// home view's result banner. Specific cases get their own
    /// banner type (with an action affordance); the rest collapse
    /// into the generic `.failed` banner with a human-friendly
    /// reason string.
    static func result(for error: CaptureServiceError) -> HomeView.HomeViewResult {
        switch error {
        case .microphonePermissionDenied:
            return .microphonePermissionDenied
        case .createSessionNetworkUnavailable:
            return .networkUnavailable
        case .alreadyCapturing:
            return .failed(reason: "A capture is already in progress.")
        case .notRecording:
            return .failed(reason: "No active capture to stop.")
        case .createSessionFailed(let reason):
            return .failed(reason: "Couldn't open the session: \(reason)")
        case .recorderStartFailed(let reason):
            return .failed(reason: "Couldn't start recording: \(reason)")
        case .recorderStopFailed(let reason):
            return .failed(reason: "Couldn't stop the recorder cleanly: \(reason)")
        case .hashingFailed(let reason):
            return .failed(reason: "Couldn't hash the recording: \(reason)")
        case .enqueueFailed(let reason):
            return .failed(reason: "Couldn't queue the upload: \(reason)")
        case .photoCaptureFailed(let reason):
            return .failed(reason: "Couldn't capture the photo: \(reason)")
        case .photoCaptureUnavailable:
            return .failed(reason: "Photo capture isn't available on this device.")
        }
    }

    /// Instance shorthand for ``HomeContainerView/result(for:)``.
    private func result(for error: CaptureServiceError) -> HomeView.HomeViewResult {
        Self.result(for: error)
    }

    // MARK: - Re-pair banner

    @ViewBuilder
    private var repairBannerView: some View {
        switch repairBanner {
        case .none:
            EmptyView()
        case .success(let workspaceName, let until):
            RepairBannerRow(
                systemImage: "checkmark.circle.fill",
                tint: BrandColors.statusSuccess,
                title: "Pairing refreshed",
                detail: "\(workspaceName) — paired until \(Self.bannerFormatter.string(from: until))",
                onDismiss: { repairBanner = .none }
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        case .failure(let reason):
            RepairBannerRow(
                systemImage: "exclamationmark.triangle.fill",
                tint: BrandColors.statusError,
                title: "Couldn't re-pair",
                detail: reason,
                onDismiss: { repairBanner = .none }
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private static let bannerFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: - Re-pair handling

    /// Routes a scanned QR string into ``AppCoordinator/repairCurrentDevice``
    /// and reflects the outcome into the on-screen banner. The
    /// `allowWorkspaceSwitch` flag is set to true only on the
    /// confirm-dialog branch — the first attempt always defers to the
    /// user when the QR points at a different workspace.
    private func handleRepair(qrText: String, allowWorkspaceSwitch: Bool) async {
        let outcome = await coordinator.repairCurrentDevice(
            qrText: qrText,
            allowWorkspaceSwitch: allowWorkspaceSwitch
        )
        await MainActor.run {
            switch outcome {
            case .refreshed(let credential):
                repairBanner = .success(
                    workspaceName: credential.workspaceName,
                    until: credential.authMethod.sessionExpiresAt
                )
                // Auto-clear after 5 seconds so the banner doesn't
                // linger forever.
                Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    await MainActor.run {
                        if case .success = repairBanner {
                            repairBanner = .none
                        }
                    }
                }
            case .differentWorkspace(let name, _):
                differentWorkspacePrompt = DifferentWorkspacePrompt(
                    qrText: qrText,
                    scannedName: name
                )
            case .failed(let reason):
                repairBanner = .failure(reason: reason)
            }
        }
    }
}

/// One-line banner shown above the home navigation chrome after a
/// re-pair attempt. Auto-dismisses on success after a few seconds via
/// the `Task.sleep` in `handleRepair`; on failure the user has to tap
/// the close icon (so they actually read the reason).
private struct RepairBannerRow: View {
    let systemImage: String
    let tint: Color
    let title: String
    let detail: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .font(.body.weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(BrandTypography.bodyEmphasis)
                    .foregroundStyle(BrandColors.textPrimary)
                Text(detail)
                    .font(BrandTypography.caption)
                    .foregroundStyle(BrandColors.textSecondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(BrandColors.textSecondary)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(BrandColors.surfaceSecondary)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(BrandColors.borderDefault)
                .frame(height: 0.5)
        }
    }
}

/// Wraps ``QRScannerView`` in a navigation chrome with a Cancel
/// button. Lives next to ``HomeContainerView`` because it's the only
/// caller; if we ever surface the re-pair flow from another screen
/// we can promote it to its own file.
private struct RepairScannerSheet: View {

    let onScan: @MainActor (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            QRScannerView(
                prompt: "Scan the QR code from the lakeLoom Databricks App to refresh this device's pairing.",
                onCodeScanned: onScan
            )
            .ignoresSafeArea()
            .navigationTitle("Re-pair device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .tint(.white)
                }
            }
            .toolbarBackground(.black.opacity(0.5), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}
