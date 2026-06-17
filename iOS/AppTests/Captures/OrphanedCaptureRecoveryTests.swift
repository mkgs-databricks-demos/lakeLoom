import Foundation
import Testing

@testable import LakeloomApp

@Suite("OrphanedCaptureRecovery — cold-start reconcile")
struct OrphanedCaptureRecoveryTests {

    private static func upload(
        id: String = UUID().uuidString,
        kind: PendingUpload.Kind,
        captureSessionID: String,
        state: PendingUpload.State
    ) -> PendingUpload {
        PendingUpload(
            id: id,
            workspaceID: "ws-1",
            captureSessionID: captureSessionID,
            projectID: kind == .document ? captureSessionID : nil,
            kind: kind,
            localFileURL: URL(fileURLWithPath: "/tmp/\(id)"),
            mimeType: "audio/mp4",
            sizeBytes: 1,
            sha256Hex: "deadbeef",
            clientTimestamp: Date(timeIntervalSince1970: 1_747_152_120),
            originalFilename: "\(id).m4a",
            createdAt: Date(timeIntervalSince1970: 1_747_152_120),
            state: state
        )
    }

    @Test("revives create ops only for sessions with non-terminal capture uploads")
    func revivesStrandedSessions() async {
        let uploads = FakeUploadCoordinator()
        await uploads.setStoredUploads([
            // cap-A: a parked (failed-transient) chunk + another still queued
            // → one revive for the session, deduped.
            Self.upload(kind: .audio, captureSessionID: "cap-A", state: .failed(reason: "404", permanent: false)),
            Self.upload(kind: .audio, captureSessionID: "cap-A", state: .queued),
            // cap-B: a queued screenshot also depends on the capture create.
            Self.upload(kind: .screenshot, captureSessionID: "cap-B", state: .queued),
            // cap-C: already succeeded (terminal) → not stranded, skip.
            Self.upload(kind: .audio, captureSessionID: "cap-C", state: .succeeded),
            // cap-D: permanently failed (terminal) → skip.
            Self.upload(kind: .audio, captureSessionID: "cap-D", state: .failed(reason: "x", permanent: true)),
            // proj-X: a document routes under the project, not a capture → skip.
            Self.upload(kind: .document, captureSessionID: "proj-X", state: .queued),
        ])
        let opQueue = FakeOperationQueue()

        await OrphanedCaptureRecovery.reconcile(uploadCoordinator: uploads, operationQueue: opQueue)

        let revived = Set(await opQueue.revivedCreateSessionIDs)
        #expect(revived == ["cap-A", "cap-B"])
        // cap-A deduped to a single revive despite two uploads.
        let revivedList = await opQueue.revivedCreateSessionIDs
        #expect(revivedList.filter { $0 == "cap-A" }.count == 1)
    }

    @Test("no pending uploads → no revivals")
    func noPendingNoRevival() async {
        let uploads = FakeUploadCoordinator()
        let opQueue = FakeOperationQueue()
        await OrphanedCaptureRecovery.reconcile(uploadCoordinator: uploads, operationQueue: opQueue)
        let revived = await opQueue.revivedCreateSessionIDs
        #expect(revived.isEmpty)
    }
}
