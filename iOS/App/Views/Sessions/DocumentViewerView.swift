import QuickLook
import SwiftUI
import UIKit

/// Push destination for a tap on a row in ``ProjectDocumentsView``.
/// Downloads the document's bytes through ``MediaContentService``
/// and previews them inline via `QLPreviewController` — handles
/// PDFs, images, audio, video, plain text, and a few other types
/// natively without any custom rendering.
///
/// Lifecycle:
/// 1. Mounts as part of a push from `ProjectDocumentsView`'s
///    `NavigationLink`.
/// 2. `.task` kicks off `MediaContentService.downloadMedia(...)`;
///    we show a spinner while the bytes stream through Genie's
///    proxy.
/// 3. On success, the loaded state holds the local file URL and
///    swaps to `QuickLookPreview` (a `UIViewControllerRepresentable`
///    wrapping `QLPreviewController`).
/// 4. On failure, an error state with a Try Again button refires
///    the download.
///
/// Markdown (`text/markdown`) renders as plain text via QuickLook in
/// v1. A future iteration could swap in a `WKWebView` markdown
/// render for prettier output.
struct DocumentViewerView: View {

    let document: ProjectDocument
    let workspaceID: String
    let mediaContent: any MediaContentService

    @State private var loadState: LoadState = .loading

    enum LoadState {
        case loading
        case loaded(URL)
        case error(String)
    }

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                loadingView
            case .loaded(let url):
                QuickLookPreview(url: url)
                    .ignoresSafeArea(edges: .bottom)
            case .error(let reason):
                errorView(reason: reason)
            }
        }
        .navigationTitle(document.originalFilename ?? document.kind.rawValue.capitalized)
        .navigationBarTitleDisplayMode(.inline)
        .background(BrandColors.surfaceSecondary)
        .task { await load() }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
                .controlSize(.large)
                .tint(BrandColors.accentPrimary)
            Text("Loading \(document.originalFilename ?? "document")…")
                .font(BrandTypography.caption)
                .foregroundStyle(BrandColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandColors.surfaceSecondary)
    }

    private func errorView(reason: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(BrandColors.statusError)
            Text("Couldn't open this document")
                .font(BrandTypography.titleSmall)
                .foregroundStyle(BrandColors.textPrimary)
            Text(reason)
                .font(BrandTypography.caption)
                .foregroundStyle(BrandColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
            Button {
                Task { await load() }
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

    // MARK: - Load

    private func load() async {
        loadState = .loading
        do {
            let url = try await mediaContent.downloadMedia(
                uploadID: document.id,
                workspaceID: workspaceID,
                mimeType: document.mimeType,
                suggestedFilename: document.originalFilename
            )
            loadState = .loaded(url)
        } catch let error as LakeloomAppError {
            loadState = .error(Self.reason(for: error))
        } catch {
            loadState = .error(error.localizedDescription)
        }
    }

    private static func reason(for error: LakeloomAppError) -> String {
        switch error {
        case .workspaceNotConfigured, .unauthorized, .tokenExchangeFailed:
            return "Sign in again to view this document."
        case .networkUnavailable:
            return "You're offline. Try again when you have a signal."
        case .timeout:
            return "The download timed out. Try again in a moment."
        case .httpError(let status, let detail, _):
            return "Server returned \(status): \(detail)"
        case .transport(let reason):
            return reason
        case .decodeFailed(let reason):
            return reason
        }
    }
}

/// `UIViewControllerRepresentable` wrapper for `QLPreviewController`.
/// The controller's `dataSource` is a small adapter that exposes one
/// preview item (the local file URL we just wrote). QuickLook picks
/// the right renderer from the file's extension.
private struct QuickLookPreview: UIViewControllerRepresentable {

    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        // The url is stable for the life of the view — captured in
        // the Coordinator at make time. If the URL changes we'd
        // need to call `reloadData()` here; for v1 it doesn't.
        if context.coordinator.url != url {
            context.coordinator.url = url
            controller.reloadData()
        }
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            url as NSURL
        }
    }
}
