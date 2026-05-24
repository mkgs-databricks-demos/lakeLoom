import SwiftUI

/// Sessions list for a project. Reads
/// `listProjectCaptureSessions(workspaceID:, projectID:, ...)` on
/// `.task` and `.refreshable`; renders rows that push to
/// ``CaptureDetailView`` on tap.
///
/// Brand-aware. v1 loads up to 50 sessions and skips cursor-based
/// pagination — the active project's window for an FDE will rarely
/// exceed that during a demo, and the follow-on PR can wire
/// `before:` to load older pages.
struct SessionsListView: View {

    let captureAPI: any CaptureAPIClient
    let uploadCoordinator: (any UploadCoordinator)?
    let workspaceID: String
    let projectID: String
    let projectName: String

    @State private var loadState: LoadState = .loading

    enum LoadState: Equatable {
        case loading
        case loaded([CaptureSession])
        case empty
        case error(String)
    }

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                loadingView
            case .empty:
                emptyView
            case .loaded(let sessions):
                listView(sessions: sessions)
            case .error(let reason):
                errorView(reason: reason)
            }
        }
        .navigationTitle("Captures")
        .navigationBarTitleDisplayMode(.large)
        .background(BrandColors.surfaceSecondary)
        .task { await initialLoad() }
        .refreshable { await refresh() }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
                .controlSize(.large)
                .tint(BrandColors.accentPrimary)
            Text("Loading captures…")
                .font(BrandTypography.caption)
                .foregroundStyle(BrandColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandColors.surfaceSecondary)
    }

    private var emptyView: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 56))
                .foregroundStyle(BrandColors.textMuted)
            Text("No captures yet")
                .font(BrandTypography.titleSmall)
                .foregroundStyle(BrandColors.textPrimary)
            Text("Tap Record on the home screen to start your first capture in \(projectName).")
                .font(BrandTypography.caption)
                .foregroundStyle(BrandColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandColors.surfaceSecondary)
    }

    private func errorView(reason: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(BrandColors.statusError)
            Text("Couldn't load captures")
                .font(BrandTypography.titleSmall)
                .foregroundStyle(BrandColors.textPrimary)
            Text(reason)
                .font(BrandTypography.caption)
                .foregroundStyle(BrandColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
            Button {
                Task { await initialLoad() }
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
                    .font(BrandTypography.bodyEmphasis)
                    .frame(maxWidth: 220, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandColors.accentPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandColors.surfaceSecondary)
    }

    private func listView(sessions: [CaptureSession]) -> some View {
        List(sessions) { session in
            NavigationLink {
                CaptureDetailView(
                    captureAPI: captureAPI,
                    uploadCoordinator: uploadCoordinator,
                    workspaceID: workspaceID,
                    captureSessionID: session.id
                )
            } label: {
                SessionRow(session: session)
            }
            .listRowBackground(BrandColors.surfacePrimary)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(BrandColors.surfaceSecondary)
    }

    // MARK: - Loading

    /// `.task` entry — fires on first appearance AND every
    /// re-appearance (e.g. pop-back from a pushed CaptureDetailView).
    /// First time through we want the loading spinner; on pop-back
    /// we want to silently refresh and preserve the loaded list if
    /// the refresh fails (so transient airplane-mode failures don't
    /// wipe the user's view). Both cases collapse to: "only flip to
    /// .loading if we don't already have data, and preserve on
    /// failure when we do."
    private func initialLoad() async {
        let hadData: Bool
        if case .loaded = loadState { hadData = true } else { hadData = false }
        if !hadData { loadState = .loading }
        await performFetch(preserveOnFailure: hadData)
    }

    /// Pull-to-refresh — keep the current list on screen behind the
    /// native refresh spinner. If the fetch fails AND we already have
    /// data, swallow the error so the user doesn't see the list flip
    /// to an error screen mid-pull (`Try again` would just succeed on
    /// the next attempt anyway). When we have no data yet (empty /
    /// error), let the error surface so the user has a recovery
    /// affordance.
    private func refresh() async {
        await performFetch(preserveOnFailure: true)
    }

    private func performFetch(preserveOnFailure: Bool) async {
        do {
            let sessions = try await captureAPI.listProjectCaptureSessions(
                workspaceID: workspaceID,
                projectID: projectID,
                state: nil,
                limit: 50,
                before: nil
            )
            loadState = sessions.isEmpty ? .empty : .loaded(sessions)
        } catch let error as CaptureAPIError {
            if preserveOnFailure, case .loaded = loadState { return }
            loadState = .error(reason(for: error))
        } catch {
            if preserveOnFailure, case .loaded = loadState { return }
            loadState = .error(error.localizedDescription)
        }
    }

    private func reason(for error: CaptureAPIError) -> String {
        switch error {
        case .notSignedIn:               return "Sign in again to view your captures."
        case .networkUnavailable:        return "You're offline. Try again when you have a signal."
        case .timeout:                   return "The request timed out. Try again in a moment."
        case .forbidden(let detail):     return "Not authorized: \(detail)"
        case .notFound:                  return "This project no longer exists."
        case .authFailed:                return "Your session expired. Re-pair to continue."
        case .serverUnavailable:         return "lakeLoom is having trouble right now. Try again in a moment."
        case .decodeFailed(let r):       return "Couldn't parse the server response: \(r)"
        case .validationFailed(let r):   return r
        case .invalidTransition(let r):  return r
        case .unexpectedResponse(let r): return r
        }
    }
}

/// Single session row. Label, started-at relative time, state pill.
private struct SessionRow: View {
    let session: CaptureSession

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(session.label ?? "Untitled capture")
                .font(BrandTypography.bodyEmphasis)
                .foregroundStyle(BrandColors.textPrimary)
                .lineLimit(1)
            HStack(spacing: Spacing.sm) {
                CaptureStateBadge(state: session.state)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(RelativeTimeFormatter.format(session.startedAt, now: context.date))
                        .font(BrandTypography.caption)
                        .foregroundStyle(BrandColors.textSecondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
