import Foundation
import Testing

@testable import LakeloomApp

@Suite("PendingUpload.endpointPath() — kind-based routing")
struct PendingUploadRoutingTests {

    private static func makeUpload(
        kind: PendingUpload.Kind,
        captureSessionID: String = "cap-1",
        projectID: String? = nil
    ) -> PendingUpload {
        PendingUpload(
            id: "u-1",
            workspaceID: "ws-1",
            captureSessionID: captureSessionID,
            projectID: projectID,
            kind: kind,
            localFileURL: URL(fileURLWithPath: "/tmp/x"),
            mimeType: "audio/mp4",
            sizeBytes: 1,
            sha256Hex: "deadbeef",
            clientTimestamp: Date(),
            originalFilename: "x",
            createdAt: Date()
        )
    }

    @Test("audio routes under /api/captures/<id>/audio")
    func audioPath() {
        let upload = Self.makeUpload(kind: .audio, captureSessionID: "cap-abc")
        #expect(upload.endpointPath() == "/api/captures/cap-abc/audio")
    }

    @Test("screenshot routes under /api/captures/<id>/screenshots")
    func screenshotPath() {
        let upload = Self.makeUpload(kind: .screenshot, captureSessionID: "cap-abc")
        #expect(upload.endpointPath() == "/api/captures/cap-abc/screenshots")
    }

    @Test("photo routes under /api/captures/<id>/photos")
    func photoPath() {
        let upload = Self.makeUpload(kind: .photo, captureSessionID: "cap-abc")
        #expect(upload.endpointPath() == "/api/captures/cap-abc/photos")
    }

    @Test("document routes under /api/projects/<projectID>/documents")
    func documentPath() {
        let upload = Self.makeUpload(
            kind: .document,
            captureSessionID: "ignored",
            projectID: "proj-xyz"
        )
        #expect(upload.endpointPath() == "/api/projects/proj-xyz/documents")
    }

    @Test("document without projectID returns nil — upload coordinator surfaces as permanent failure")
    func documentMissingProjectID() {
        let upload = Self.makeUpload(kind: .document, captureSessionID: "ignored", projectID: nil)
        #expect(upload.endpointPath() == nil)
    }

    @Test("document with empty projectID returns nil")
    func documentEmptyProjectID() {
        let upload = Self.makeUpload(kind: .document, captureSessionID: "ignored", projectID: "")
        #expect(upload.endpointPath() == nil)
    }

    @Test("non-document kinds ignore projectID even when set")
    func nonDocumentIgnoresProjectID() {
        let upload = Self.makeUpload(
            kind: .audio,
            captureSessionID: "cap-1",
            projectID: "proj-1"
        )
        #expect(upload.endpointPath() == "/api/captures/cap-1/audio")
    }
}
