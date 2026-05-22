import SwiftUI

/// Per-capture detail view. Pulls
/// `getCaptureSession(captureSessionID:, includeUploads: true)` on
/// `.task` and `.refreshable` and renders the resulting session +
/// its uploads.
///
/// v1 is read-only — the uploads list shows the server's view of
/// what's been ingested. A follow-on PR will merge in
/// `UploadCoordinator.currentUploads()` so in-flight client-side
/// uploads (queued / uploading / failed) surface here too, with
/// per-row retry / discard.
struct CaptureDetailView: View {

    let captureAPI: any CaptureAPIClient
    let workspaceID: String
    let captureSessionID: String

    @State private var loadState: LoadState = .loading

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
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Uploads")
                .font(BrandTypography.captionMedium)
                .textCase(.uppercase)
                .tracking(1)
                .foregroundStyle(BrandColors.textSecondary)
            if let uploads = session.uploads, !uploads.isEmpty {
                VStack(spacing: Spacing.sm) {
                    ForEach(uploads) { upload in
                        UploadRow(upload: upload)
                    }
                }
            } else {
                Text("No files have been ingested for this capture yet.")
                    .font(BrandTypography.caption)
                    .foregroundStyle(BrandColors.textMuted)
                    .padding(.vertical, Spacing.sm)
            }
        }
    }

    // MARK: - Loading

    /// First entry (`.task`) — show the spinner while we fetch.
    private func initialLoad() async {
        loadState = .loading
        await performFetch(preserveOnFailure: false)
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
