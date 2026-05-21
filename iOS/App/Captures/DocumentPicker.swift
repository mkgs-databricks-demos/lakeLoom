import SwiftUI
import UniformTypeIdentifiers

/// SwiftUI bridge for `UIDocumentPickerViewController` in import mode.
///
/// Picks a single file matching `allowedContentTypes` and returns its
/// URL via `onPick`. The returned URL is **security-scoped**: callers
/// must wrap any read access in `startAccessingSecurityScopedResource()`
/// + `stopAccessingSecurityScopedResource()`, or copy the bytes out
/// to an app-owned location for later use.
///
/// Used by ``EndpointSmokeTestView`` to drive
/// `POST /api/projects/:id/documents`. Module 02 PR 7's real "Attach
/// document" affordance will reuse this same wrapper.
struct DocumentPicker: UIViewControllerRepresentable {

    /// Allowed UTTypes. Defaults to the server-side allowlist Genie
    /// documented in `architecture/hey_isaac/2026-05-13_upload-traceability-response.md`:
    /// PDF + DOCX. Override at the call site if the smoke-test sheet
    /// wants a broader picker for diagnostic purposes.
    let allowedContentTypes: [UTType]
    let onPick: @MainActor (URL) -> Void
    let onCancel: @MainActor () -> Void

    init(
        allowedContentTypes: [UTType] = DocumentPicker.defaultAllowedTypes,
        onPick: @escaping @MainActor (URL) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.allowedContentTypes = allowedContentTypes
        self.onPick = onPick
        self.onCancel = onCancel
    }

    /// PDF + DOCX, matching the server's documents allowlist.
    static let defaultAllowedTypes: [UTType] = {
        var types: [UTType] = [.pdf]
        // DOCX has a registered UTI on iOS 14+; fall back gracefully
        // if the OS doesn't know the exact identifier.
        if let docx = UTType(filenameExtension: "docx") {
            types.append(docx)
        }
        return types
    }()

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: allowedContentTypes,
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    /// Bridges Obj-C delegate callbacks into the SwiftUI closures.
    /// `@unchecked Sendable` because the coordinator is single-use,
    /// held by SwiftUI for the lifetime of the picker presentation,
    /// and its closures hop back to MainActor before mutating any
    /// state.
    final class Coordinator: NSObject, UIDocumentPickerDelegate, @unchecked Sendable {

        private let onPick: @MainActor (URL) -> Void
        private let onCancel: @MainActor () -> Void

        init(
            onPick: @escaping @MainActor (URL) -> Void,
            onCancel: @escaping @MainActor () -> Void
        ) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard let url = urls.first else {
                Task { @MainActor [onCancel] in onCancel() }
                return
            }
            Task { @MainActor [onPick] in onPick(url) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            Task { @MainActor [onCancel] in onCancel() }
        }
    }
}
