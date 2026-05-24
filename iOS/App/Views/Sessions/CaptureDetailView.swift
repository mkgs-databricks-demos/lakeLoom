import SwiftUI

/// Per-capture detail view. Pulls
/// `getCaptureSession(captureSessionID:, includeUploads: true)` on
/// `.task` and `.refreshable` and renders the resulting session +
/// its uploads.
///
/// Uploads list merges two sources:
/// * **Server-ingested** — `session.uploads` returned by the API.
///   Terminal-good rows; show a success check.
/// * **Client-side in-flight** — `UploadCoordinator.currentUploads()`
///   filtered to this capture. Renders queued / uploading / failed
///   states with a progress spinner and (on failure) per-row retry +
///   discard. Dedupe by `sha256Hex`: once the server reflects the
///   upload, the client row drops out so a successful upload doesn't
///   render twice.
///
/// A `.task` modifier subscribes to `stateUpdates()` so the UI keeps
/// up live; `.succeeded` transitions also kick a silent refetch of
/// the server's view so newly-ingested rows replace their client-side
/// counterparts without the user having to pull-to-refresh.
struct CaptureDetailView: View {

    let captureAPI: any CaptureAPIClient
    let uploadCoordinator: (any UploadCoordinator)?
    let workspaceID: String
    let captureSessionID: String

    @State private var loadState: LoadState = .loading
    @State private var pendingUploads: [PendingUpload] = []

    enum LoadState {
        case loading
        case loaded(CaptureSession)
        case error(String)
    }

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                loadingView
            case .loaded(let session):
                detailView(for: session)
            case .error(let reason):
                errorView(reason: reason)
            }
        }
        .navigationTitle("Capture")
        .navigationBarTitleDisplayMode(.inline)
        .background(BrandColors.surfaceSecondary)
        .task { await initialLoad() }
        .task { await observePendingUploads() }
        .refreshable { await refresh() }
    }

    // MARK: - States

    private var loadingView: some View {
        ProgressView()
            .controlSize(.large)
            .tint(BrandColors.accentPrimary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrandColors.surfaceSecondary)
    }

    private func errorView(reason: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(BrandColors.statusError)
            Text("Couldn't load this capture")
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

    private func detailView(for session: CaptureSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                header(for: session)
                Divider()
                uploadsSection(for: session)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.lg)
        }
        .background(BrandColors.surfaceSecondary)
    }

    // MARK: - Header

    private func header(for session: CaptureSession) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                CaptureStateBadge(state: session.state)
                Spacer()
                Text(idShort(session.id))
                    .font(BrandTypography.caption.monospaced())
                    .foregroundStyle(BrandColors.textMuted)
            }
            Text(session.label ?? "Untitled capture")
                .font(BrandTypography.titleSmall)
                .foregroundStyle(BrandColors.textPrimary)

            VStack(alignment: .leading, spacing: 2) {
                metadataRow(
                    icon: "play.circle",
                    label: "Started",
                    value: dateAbsolute(session.startedAt),
                    relative: session.startedAt
                )
                if let endedAt = session.endedAt {
                    metadataRow(
                        icon: "stop.circle",
                        label: "Ended",
                        value: dateAbsolute(endedAt),
                        relative: endedAt
                    )
                }
                if let device = session.deviceLabel {
                    metadataRow(
                        icon: "iphone",
                        label: "Device",
                        value: device,
                        relative: nil
                    )
                }
            }
        }
    }

    private func metadataRow(
        icon: String,
        label: String,
        value: String,
        relative: Date?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(BrandTypography.caption)
                .foregroundStyle(BrandColors.textSecondary)
                .frame(width: 16)
            Text(label)
                .font(BrandTypography.caption)
                .foregroundStyle(BrandColors.textSecondary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(BrandTypography.caption)
                .foregroundStyle(BrandColors.textPrimary)
            if let relative {
                Text("·")
                    .font(BrandTypography.caption)
                    .foregroundStyle(BrandColors.textMuted)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(RelativeTimeFormatter.format(relative, now: context.date))
                        .font(BrandTypography.caption)
                        .foregroundStyle(BrandColors.textMuted)
                }
            }
        }
    }

    // MARK: - Uploads

    private func uploadsSection(for session: CaptureSession) -> some View {
        let server = session.uploads ?? []
        let serverShas = Set(server.map { $0.sha256Hex })
        // Hide client-side rows the server has already reflected.
        // Until then (including .succeeded just-before-server-fetches)
        // we keep the client row visible so the user always sees the
        // most up-to-date status for what they recorded.
        let clientOnly = pendingUploads.filter { !serverShas.contains($0.sha256Hex) }

        return VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Uploads")
                .font(BrandTypography.captionMedium)
                .textCase(.uppercase)
                .tracking(1)
                .foregroundStyle(BrandColors.textSecondary)
            if clientOnly.isEmpty && server.isEmpty {
                Text("No files have been ingested for this capture yet.")
                    .font(BrandTypography.caption)
                    .foregroundStyle(BrandColors.textMuted)
                    .padding(.vertical, Spacing.sm)
            } else {
                VStack(spacing: Spacing.sm) {
                    ForEach(clientOnly) { upload in
                        PendingUploadRow(
                            upload: upload,
                            onRetry: { Task { await uploadCoordinator?.retry(uploadID: upload.id) } },
                            onDiscard: { Task { await discardClientUpload(upload.id) } }
                        )
                    }
                    ForEach(server) { upload in
                        UploadRow(upload: upload)
                    }
                }
            }
        }
    }

    // MARK: - Pending uploads (client-side)

    /// Mirror `UploadCoordinator.currentUploads()` for this capture
    /// into `pendingUploads` and keep it live as the queue progresses.
    /// Each yield from `stateUpdates()` re-snapshots so we catch
    /// enqueues that arrive while the view is open, plus
    /// queued → uploading → terminal transitions for rows we already
    /// know about. On `.succeeded` we also kick a silent server
    /// refetch so the row swaps from the client to the server side
    /// without the user having to pull-to-refresh.
    private func observePendingUploads() async {
        guard let coordinator = uploadCoordinator else { return }
        await refreshPending(from: coordinator)
        let stream = await coordinator.stateUpdates()
        for await change in stream {
            await refreshPending(from: coordinator)
            if case .succeeded = change.state {
                await silentlyRefetchSession()
            }
        }
    }

    private func refreshPending(from coordinator: any UploadCoordinator) async {
        let all = await coordinator.currentUploads()
        pendingUploads = all.filter { $0.captureSessionID == captureSessionID }
    }

    private func discardClientUpload(_ id: String) async {
        await uploadCoordinator?.discard(uploadID: id)
        // Discard doesn't broadcast via stateUpdates(), so refresh
        // the local snapshot explicitly.
        if let coordinator = uploadCoordinator {
            await refreshPending(from: coordinator)
        }
    }

    private func silentlyRefetchSession() async {
        await performFetch(preserveOnFailure: true)
    }

    // MARK: - Loading

    /// `.task` entry — fires on first appearance AND every
    /// re-appearance (e.g. pop-back from a pushed destination). On
    /// first appearance we want the spinner; if we already have
    /// loaded data, refresh silently and preserve it on failure so
    /// transient airplane-mode failures don't wipe the user's view.
    private func initialLoad() async {
        let hadData: Bool
        if case .loaded = loadState { hadData = true } else { hadData = false }
        if !hadData { loadState = .loading }
        await performFetch(preserveOnFailure: hadData)
    }

    /// Pull-to-refresh — keep the loaded detail visible behind the
    /// native refresh spinner. On failure, only flip to `.error` when
    /// we have nothing on screen to begin with.
    private func refresh() async {
        await performFetch(preserveOnFailure: true)
    }

    private func performFetch(preserveOnFailure: Bool) async {
        do {
            let session = try await captureAPI.getCaptureSession(
                workspaceID: workspaceID,
                captureSessionID: captureSessionID,
                includeUploads: true
            )
            loadState = .loaded(session)
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
        case .notSignedIn:               return "Sign in again to view this capture."
        case .networkUnavailable:        return "You're offline. Try again when you have a signal."
        case .timeout:                   return "The request timed out. Try again in a moment."
        case .forbidden(let detail):     return "Not authorized: \(detail)"
        case .notFound:                  return "This capture no longer exists."
        case .authFailed:                return "Your session expired. Re-pair to continue."
        case .serverUnavailable:         return "lakeLoom is having trouble right now. Try again in a moment."
        case .decodeFailed(let r):       return "Couldn't parse the server response: \(r)"
        case .validationFailed(let r):   return r
        case .invalidTransition(let r):  return r
        case .unexpectedResponse(let r): return r
        }
    }

    // MARK: - Helpers

    private func idShort(_ id: String) -> String {
        let prefix = id.prefix(8)
        return prefix.count == id.count ? String(prefix) : "\(prefix)…"
    }

    private func dateAbsolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// One row per ingested file.
private struct UploadRow: View {
    let upload: CaptureUpload

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: kindIcon)
                .font(.title3)
                .foregroundStyle(BrandColors.accentPrimary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(upload.originalFilename ?? upload.kind.rawValue.capitalized)
                    .font(BrandTypography.bodyEmphasis)
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(upload.kind.rawValue.uppercased())
                        .font(BrandTypography.caption)
                        .foregroundStyle(BrandColors.textSecondary)
                    Text("·")
                        .foregroundStyle(BrandColors.textMuted)
                    Text(ByteCountFormatter.string(fromByteCount: upload.sizeBytes, countStyle: .file))
                        .font(BrandTypography.caption)
                        .foregroundStyle(BrandColors.textSecondary)
                    Text("·")
                        .foregroundStyle(BrandColors.textMuted)
                    Text(upload.sha256Hex.prefix(8))
                        .font(BrandTypography.caption.monospaced())
                        .foregroundStyle(BrandColors.textMuted)
                }
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(BrandColors.statusSuccess)
        }
        .padding(Spacing.md)
        .background(BrandColors.surfacePrimary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(BrandColors.borderDefault, lineWidth: 0.5)
        )
    }

    private var kindIcon: String {
        switch upload.kind {
        case .audio:      return "waveform"
        case .screenshot: return "rectangle.dashed"
        case .photo:      return "camera.fill"
        case .document:   return "doc.fill"
        }
    }
}

// PendingUploadRow lives in its own file (`PendingUploadRow.swift`)
// so ``PendingUploadsView`` can reuse the same visual treatment.
