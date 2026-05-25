import SwiftUI

/// Sessions list for a project. Reads
/// `listProjectCaptureSessions(workspaceID:, projectID:, ...)` on
/// `.task` and `.refreshable`; renders rows that push to
/// ``CaptureDetailView`` on tap.
///
/// Pagination: pages of up to ``Self/pageSize`` sessions, newest
/// first. When the user scrolls to the last visible row we fire the
/// next page using `before: <oldest session's startedAt>` — same
/// cursor shape the server already supports. A response shorter than
/// the page size flips `reachedEnd`, after which no further pages
/// fire. Pull-to-refresh resets the cursor and replaces the list.
struct SessionsListView: View {

    let captureAPI: any CaptureAPIClient
    let uploadCoordinator: (any UploadCoordinator)?
    let workspaceID: String
    let projectID: String
    let projectName: String

    /// Page size for both the initial fetch and every paginated
    /// follow-up. Server caps at 200; 50 is a good demo-time balance
    /// between snappy load and not requiring scroll to see all
    /// sessions on a fresh device.
    private static let pageSize = 50

    @State private var loadState: LoadState = .loading
    @State private var isLoadingMore = false
    @State private var reachedEnd = false

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
        List {
            ForEach(sessions) { session in
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
                .onAppear {
                    // Trigger the next page when the bottom row
                    // enters view. The guards in loadNextPage()
                    // dedupe concurrent calls so a fast scroll
                    // can't fire multiple in-flight requests.
                    if session.id == sessions.last?.id {
                        Task { await loadNextPage(after: sessions) }
                    }
                }
            }
            if isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                        .tint(BrandColors.accentPrimary)
                    Spacer()
                }
                .listRowBackground(BrandColors.surfacePrimary)
                .listRowSeparator(.hidden)
            }
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
        await performInitialFetch(preserveOnFailure: hadData)
    }

    /// Pull-to-refresh — keep the current list on screen behind the
    /// native refresh spinner. If the fetch fails AND we already have
    /// data, swallow the error so the user doesn't see the list flip
    /// to an error screen mid-pull (`Try again` would just succeed on
    /// the next attempt anyway). When we have no data yet (empty /
    /// error), let the error surface so the user has a recovery
    /// affordance.
    private func refresh() async {
        await performInitialFetch(preserveOnFailure: true)
    }

    /// First-page fetch. Replaces the list and resets the cursor
    /// state so a new round of pagination can begin.
    private func performInitialFetch(preserveOnFailure: Bool) async {
        do {
            let sessions = try await captureAPI.listProjectCaptureSessions(
                workspaceID: workspaceID,
                projectID: projectID,
                state: nil,
                limit: Self.pageSize,
                before: nil
            )
            reachedEnd = sessions.count < Self.pageSize
            loadState = sessions.isEmpty ? .empty : .loaded(sessions)
        } catch let error as CaptureAPIError {
            if preserveOnFailure, case .loaded = loadState { return }
            loadState = .error(reason(for: error))
        } catch {
            if preserveOnFailure, case .loaded = loadState { return }
            loadState = .error(error.localizedDescription)
        }
    }

    /// Paginated fetch — append older sessions using the oldest
    /// loaded session's `startedAt` as the `before` cursor. No-op
    /// when we've already reached the end or another page is
    /// in-flight; both guards make the per-row `.onAppear` trigger
    /// safe to fire on every scroll tick.
    ///
    /// Failures during pagination are intentionally swallowed (just
    /// the spinner clears). Pull-to-refresh is the recovery path —
    /// flipping the whole list to an error screen mid-scroll would
    /// be much worse than the user losing one page they'll get back
    /// on the next scroll attempt.
    private func loadNextPage(after current: [CaptureSession]) async {
        guard !reachedEnd, !isLoadingMore else { return }
        guard let cursor = current.last?.startedAt else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await captureAPI.listProjectCaptureSessions(
                workspaceID: workspaceID,
                projectID: projectID,
                state: nil,
                limit: Self.pageSize,
                before: cursor
            )
            reachedEnd = next.count < Self.pageSize
            guard case .loaded(let existing) = loadState else { return }
            loadState = .loaded(existing + next)
        } catch {
            // Silent failure — see doc above. The user can scroll
            // again to retry or pull-to-refresh from the top.
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

/// Single session row. Label, state pill, relative time, plus —
/// when the server populates `upload_kinds` (added in Genie's
/// PR #61) — a row of small SF Symbol chips telling the user at a
/// glance what kinds of artifacts the session contains
/// (audio / photo / screenshot / document). The chips stay hidden
/// when the field is nil or empty so older / sparser captures
/// don't render a stray row of icons.
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
                Spacer(minLength: Spacing.sm)
                uploadKindsBadges
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var uploadKindsBadges: some View {
        if let kinds = session.uploadKinds, !kinds.isEmpty {
            HStack(spacing: 6) {
                ForEach(orderedKinds(kinds), id: \.self) { kind in
                    Image(systemName: kind.sfSymbol)
                        .font(BrandTypography.caption)
                        .foregroundStyle(BrandColors.textSecondary)
                        .accessibilityLabel(kind.accessibleName)
                }
            }
        }
    }

    /// Stable display order — audio first (the primary artifact),
    /// then photos, then screenshots, then documents. Independent
    /// of the order the server's `array_agg` happens to return.
    private func orderedKinds(_ kinds: [CaptureUpload.Kind]) -> [CaptureUpload.Kind] {
        let priority: [CaptureUpload.Kind] = [.audio, .photo, .screenshot, .document]
        let set = Set(kinds)
        return priority.filter { set.contains($0) }
    }
}

extension CaptureUpload.Kind {
    /// SF Symbol for the kind, used by `SessionRow`'s badge chips
    /// and matching the per-row icon styling in `CaptureDetailView`'s
    /// uploads list so the two surfaces stay visually consistent.
    var sfSymbol: String {
        switch self {
        case .audio:      return "waveform"
        case .photo:      return "camera.fill"
        case .screenshot: return "rectangle.dashed"
        case .document:   return "doc.fill"
        }
    }

    /// Accessibility label for VoiceOver — Image-only chips need
    /// a spoken name since the icon glyph alone isn't read.
    var accessibleName: String {
        switch self {
        case .audio:      return "Audio"
        case .photo:      return "Photo"
        case .screenshot: return "Screenshot"
        case .document:   return "Document"
        }
    }
}
