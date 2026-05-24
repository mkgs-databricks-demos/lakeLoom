import SwiftUI

/// Lists every upload currently tracked by the ``UploadCoordinator``
/// — across all capture sessions, not filtered to one — and offers
/// orphan-recovery affordances.
///
/// Surfaces two cleanup paths:
///
/// 1. **Per-row** — every row carries Retry / Discard buttons via
///    ``PendingUploadRow`` for the kinds of one-at-a-time cleanup
///    users do when they recognize a specific orphan.
/// 2. **Retry & clear** — a single button up-top that re-queues
///    every non-succeeded upload, waits for them to reach terminal
///    state, then discards everything that reached
///    ``PendingUpload/State/succeeded``. This is the one-shot
///    affordance for the orphan-leak scenario observed on real
///    device (uploads that landed server-side but couldn't drain
///    the on-disk queue because of the pre-fix watcher race —
///    `upload.queue.restored count=12` after only a few sessions).
///
/// Subscribes to ``UploadCoordinator/stateUpdates()`` so the list
/// reflects every queue mutation live; the watch task seeds itself
/// with a `currentUploads()` snapshot on appear so a freshly-opened
/// sheet doesn't render blank for a tick.
struct PendingUploadsView: View {

    let uploadCoordinator: any UploadCoordinator
    let onDismiss: () -> Void

    @State private var uploads: [PendingUpload] = []
    @State private var isProcessing = false

    var body: some View {
        NavigationStack {
            Group {
                if uploads.isEmpty {
                    emptyView
                } else {
                    listView
                }
            }
            .navigationTitle("Pending uploads")
            .navigationBarTitleDisplayMode(.inline)
            .background(BrandColors.surfaceSecondary)
            .toolbar { toolbar }
        }
        .task { await observe() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Done") { onDismiss() }
                .tint(BrandColors.accentPrimary)
        }
        ToolbarItem(placement: .topBarTrailing) {
            if !uploads.isEmpty {
                Button {
                    Task { await retryAndClear() }
                } label: {
                    if isProcessing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Retry & clear")
                            .font(BrandTypography.bodyEmphasis)
                    }
                }
                .disabled(isProcessing)
                .tint(BrandColors.accentPrimary)
            }
        }
    }

    // MARK: - States

    private var emptyView: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(BrandColors.textMuted)
            Text("No pending uploads")
                .font(BrandTypography.titleSmall)
                .foregroundStyle(BrandColors.textPrimary)
            Text("Anything you record will show up here while it uploads.")
                .font(BrandTypography.caption)
                .foregroundStyle(BrandColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandColors.surfaceSecondary)
    }

    private var listView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                summaryHeader
                VStack(spacing: Spacing.sm) {
                    ForEach(uploads) { upload in
                        PendingUploadRow(
                            upload: upload,
                            onRetry: { Task { await uploadCoordinator.retry(uploadID: upload.id) } },
                            onDiscard: { Task { await discard(upload.id) } }
                        )
                    }
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.lg)
        }
        .background(BrandColors.surfaceSecondary)
    }

    private var summaryHeader: some View {
        let counts = stateCounts(uploads)
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("\(uploads.count) upload\(uploads.count == 1 ? "" : "s") in queue")
                .font(BrandTypography.captionMedium)
                .textCase(.uppercase)
                .tracking(1)
                .foregroundStyle(BrandColors.textSecondary)
            HStack(spacing: Spacing.md) {
                summaryChip(label: "In flight", value: counts.active, color: BrandColors.accentPrimary)
                summaryChip(label: "Uploaded", value: counts.succeeded, color: BrandColors.statusSuccess)
                summaryChip(label: "Failed", value: counts.failed, color: BrandColors.statusError)
            }
        }
    }

    private func summaryChip(label: String, value: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(value) \(label)")
                .font(BrandTypography.caption)
                .foregroundStyle(BrandColors.textPrimary)
        }
    }

    // MARK: - Coordinator wiring

    private func observe() async {
        await refresh()
        let stream = await uploadCoordinator.stateUpdates()
        for await _ in stream {
            await refresh()
        }
    }

    private func refresh() async {
        uploads = await uploadCoordinator.currentUploads()
    }

    private func discard(_ id: String) async {
        await uploadCoordinator.discard(uploadID: id)
        // discard() doesn't broadcast through stateUpdates(), so
        // refresh the snapshot manually.
        await refresh()
    }

    /// Re-queue every non-succeeded upload, wait for everything to
    /// reach a terminal state, then discard the ones that succeeded.
    /// Failed-permanent items are left for manual handling so the
    /// user sees what couldn't be recovered.
    private func retryAndClear() async {
        isProcessing = true
        defer { isProcessing = false }

        let snapshot = await uploadCoordinator.currentUploads()
        for upload in snapshot where !upload.state.isTerminalSucceeded {
            await uploadCoordinator.retry(uploadID: upload.id)
        }

        // Poll until nothing is queued/uploading. The stateUpdates()
        // task above mirrors transitions into `uploads`, but we read
        // a fresh snapshot here to avoid any actor-isolation lag.
        while await hasInFlight() {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
        }

        let final = await uploadCoordinator.currentUploads()
        for upload in final where upload.state.isTerminalSucceeded {
            await uploadCoordinator.discard(uploadID: upload.id)
        }
        await refresh()
    }

    private func hasInFlight() async -> Bool {
        let current = await uploadCoordinator.currentUploads()
        return current.contains { upload in
            switch upload.state {
            case .queued, .uploading: return true
            default: return false
            }
        }
    }

    private func stateCounts(_ list: [PendingUpload]) -> (active: Int, succeeded: Int, failed: Int) {
        var active = 0
        var succeeded = 0
        var failed = 0
        for upload in list {
            switch upload.state {
            case .queued, .uploading: active += 1
            case .succeeded:          succeeded += 1
            case .failed:             failed += 1
            }
        }
        return (active, succeeded, failed)
    }
}

private extension PendingUpload.State {
    /// True only for `.succeeded`. Distinct from
    /// ``PendingUpload/State/isTerminal``, which also matches
    /// permanent failures — we don't want to discard those.
    var isTerminalSucceeded: Bool {
        if case .succeeded = self { return true }
        return false
    }
}
