import SwiftUI

/// One row per client-side in-flight upload. Mirrors the visual
/// language of the server-side `UploadRow` (in `CaptureDetailView`)
/// but swaps the trailing success check for a state-aware indicator:
/// a spinner while queued/uploading, a green check when succeeded,
/// a red retry+discard pair on failure.
///
/// Used by both ``CaptureDetailView`` (filtered to one capture's
/// in-flight uploads) and ``PendingUploadsView`` (every upload in the
/// coordinator's queue, for orphan recovery). Lifted out of the
/// detail view as a top-level `struct` so the two surfaces share the
/// same visual treatment.
struct PendingUploadRow: View {
    let upload: PendingUpload
    let onRetry: () -> Void
    let onDiscard: () -> Void

    @State private var confirmingDiscard = false

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
                    Text(statusLabel)
                        .font(BrandTypography.caption)
                        .foregroundStyle(statusColor)
                }
                if let reason = errorReason {
                    Text(reason)
                        .font(BrandTypography.caption)
                        .foregroundStyle(BrandColors.statusError)
                        .lineLimit(2)
                }
            }
            Spacer()
            trailing
        }
        .padding(Spacing.md)
        .background(BrandColors.surfacePrimary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(BrandColors.borderDefault, lineWidth: 0.5)
        )
        .confirmationDialog(
            "Discard upload?",
            isPresented: $confirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) { onDiscard() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The local file will be deleted and the upload won't be retried.")
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch upload.state {
        case .queued, .uploading:
            ProgressView()
                .controlSize(.small)
                .tint(BrandColors.accentPrimary)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(BrandColors.statusSuccess)
        case .failed:
            HStack(spacing: Spacing.sm) {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(BrandTypography.bodyEmphasis)
                }
                .buttonStyle(.borderless)
                .tint(BrandColors.accentPrimary)
                .accessibilityLabel("Retry upload")
                Button {
                    confirmingDiscard = true
                } label: {
                    Image(systemName: "trash")
                        .font(BrandTypography.bodyEmphasis)
                }
                .buttonStyle(.borderless)
                .tint(BrandColors.statusError)
                .accessibilityLabel("Discard upload")
            }
        }
    }

    private var statusLabel: String {
        switch upload.state {
        case .queued:                   return "Queued"
        case .uploading:                return "Uploading…"
        case .succeeded:                return "Uploaded"
        case .failed(_, let permanent): return permanent ? "Failed" : "Retrying…"
        }
    }

    private var statusColor: Color {
        switch upload.state {
        case .queued:     return BrandColors.textSecondary
        case .uploading:  return BrandColors.accentPrimary
        case .succeeded:  return BrandColors.statusSuccess
        case .failed:     return BrandColors.statusError
        }
    }

    /// Show the last error string under the row, regardless of
    /// whether we're between retries (state.failed transient) or
    /// stuck at a permanent failure. `lastError` is cleared by the
    /// coordinator on the next successful attempt so this stays
    /// honest as the upload progresses.
    private var errorReason: String? {
        if case .failed(let reason, _) = upload.state { return reason }
        return upload.lastError
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
