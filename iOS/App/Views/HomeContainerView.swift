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

    var body: some View {
        NavigationStack {
            HomeView(
                workspaceName: workspaceName,
                projectName: projectName,
                userName: userName,
                lastResult: lastResult,
                isStartingCapture: isStartingCapture,
                onRecord: startCapture,
                onClearResult: { lastResult = .none },
                onResultAction: performResultAction
            )
            .toolbar { toolbar }
        }
        .fullScreenCover(isPresented: bindingForRecordingPresentation) {
            if let context = currentCaptureContext {
                RecordingView(
                    state: captureState,
                    onStop: stopCapture,
                    onCancel: cancelCapture,
                    projectName: projectName.isEmpty ? "Capture" : projectName
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
        #if DEBUG
        .sheet(isPresented: $showingSmokeTest) {
            if let api = coordinator.captureAPI,
               let context = coordinator.activeContext {
                EndpointSmokeTestView(
                    captureAPI: api,
                    uploadCoordinator: coordinator.uploadCoordinator,
                    photoCapture: coordinator.photoCapture,
                    workspaceID: context.workspace.id,
                    projectID: context.project.id,
                    onDismiss: { showingSmokeTest = false }
                )
            }
        }
        #endif
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
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

    // MARK: - Derived context

    private var workspaceName: String {
        coordinator.activeContext?.workspace.workspaceName ?? "—"
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
        }
    }

    /// Instance shorthand for ``HomeContainerView/result(for:)``.
    private func result(for error: CaptureServiceError) -> HomeView.HomeViewResult {
        Self.result(for: error)
    }
}
