import SwiftUI

/// Project-level documents surface. Lists every `CaptureUpload` with
/// `kind=.document` for the active project — the AI pipeline's output
/// (Whisper transcript, requirements doc, architecture diagram, Genie
/// Code session plan per Genie's `2026-05-23` answer note), plus any
/// reference materials the user uploaded server-side.
///
/// Read-only in v1. iOS doesn't upload documents from the device
/// today; they land here via the post-capture AI pipeline + the
/// browser UI. A future PR will add a "Upload document" affordance
/// once the multipart route is exercised from iOS.
struct ProjectDocumentsView: View {

    let captureAPI: any CaptureAPIClient
    let workspaceID: String
    let projectID: String
    let projectName: String
    let onDismiss: () -> Void

    @State private var loadState: LoadState = .loading

    enum LoadState {
        case loading
        case loaded([CaptureUpload])
        case empty
        case error(String)
    }

    private static let pageSize = 50

    var body: some View {
        NavigationStack {
            Group {
                switch loadState {
                case .loading:
                    loadingView
                case .loaded(let list):
                    listView(list)
                case .empty:
                    emptyView
                case .error(let reason):
                    errorView(reason: reason)
                }
            }
            .navigationTitle("Documents")
            .navigationBarTitleDisplayMode(.inline)
            .background(BrandColors.surfaceSecondary)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { onDismiss() }
                        .tint(BrandColors.accentPrimary)
                }
                ToolbarItem(placement: .principal) {
                    Text(projectName)
                        .font(BrandTypography.bodyEmphasis)
                        .foregroundStyle(BrandColors.textPrimary)
                        .lineLimit(1)
                }
            }
            .refreshable { await load() }
        }
        .task { await initialLoad() }
    }

    // MARK: - States

    private var loadingView: some View {
        ProgressView()
            .controlSize(.large)
            .tint(BrandColors.accentPrimary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrandColors.surfaceSecondary)
    }

    private var emptyView: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(BrandColors.textMuted)
            Text("No documents yet")
                .font(BrandTypography.titleSmall)
                .foregroundStyle(BrandColors.textPrimary)
            Text("The AI pipeline writes documents here after a capture session is processed. Reference materials uploaded from the web also appear in this list.")
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
            Text("Couldn't load documents")
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

    private func listView(_ list: [CaptureUpload]) -> some View {
        ScrollView {
            VStack(spacing: Spacing.sm) {
                ForEach(list) { document in
                    DocumentRow(document: document)
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.lg)
        }
        .background(BrandColors.surfaceSecondary)
    }

    // MARK: - Load

    private func initialLoad() async {
        if case .loaded = loadState { return }
        await load()
    }

    private func load() async {
        do {
            let documents = try await captureAPI.listProjectDocuments(
                workspaceID: workspaceID,
                projectID: projectID,
                limit: Self.pageSize,
                before: nil
            )
            loadState = documents.isEmpty ? .empty : .loaded(documents)
        } catch let error as CaptureAPIError {
            loadState = .error(reason(for: error))
        } catch {
            loadState = .error(error.localizedDescription)
        }
    }

    private func reason(for error: CaptureAPIError) -> String {
        switch error {
        case .notSignedIn:               return "Sign in again to view documents."
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

/// One row per document. Surfaces filename, kind tag, byte size,
/// short sha prefix, and the wall-clock `uploadedAt` time. Mirrors
/// the visual treatment of `UploadRow` in `CaptureDetailView` so the
/// two surfaces feel like the same family — captures and documents
/// are both upload-records living under the same project.
private struct DocumentRow: View {
    let document: CaptureUpload

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "doc.fill")
                .font(.title3)
                .foregroundStyle(BrandColors.accentPrimary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.originalFilename ?? "Document")
                    .font(BrandTypography.bodyEmphasis)
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(ByteCountFormatter.string(fromByteCount: document.sizeBytes, countStyle: .file))
                        .font(BrandTypography.caption)
                        .foregroundStyle(BrandColors.textSecondary)
                    Text("·")
                        .foregroundStyle(BrandColors.textMuted)
                    Text(document.sha256Hex.prefix(8))
                        .font(BrandTypography.caption.monospaced())
                        .foregroundStyle(BrandColors.textMuted)
                    Text("·")
                        .foregroundStyle(BrandColors.textMuted)
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(RelativeTimeFormatter.format(document.uploadedAt, now: context.date))
                            .font(BrandTypography.caption)
                            .foregroundStyle(BrandColors.textSecondary)
                    }
                }
            }
            Spacer()
        }
        .padding(Spacing.md)
        .background(BrandColors.surfacePrimary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(BrandColors.borderDefault, lineWidth: 0.5)
        )
    }
}
