import Foundation
import Testing

@testable import LakeloomApp

@Suite("UploadErrorCode + isPermanent retry classification")
struct UploadErrorCodeTests {

    @Test("raw-value mapping for documented codes")
    func rawValueMapping() {
        #expect(UploadErrorCode(rawValue: "UPLOAD_VOLUME_WRITE_FAILED") == .uploadVolumeWriteFailed)
        #expect(UploadErrorCode(rawValue: "UPLOAD_INTEGRITY_MISMATCH") == .uploadIntegrityMismatch)
        #expect(UploadErrorCode(rawValue: "UNSUPPORTED_MEDIA_TYPE") == .unsupportedMediaType)
        #expect(UploadErrorCode(rawValue: "made_up_code") == nil)
    }

    @Test("isPermanent matches the contract")
    func isPermanentMapping() {
        // Volume write failed → retry-safe (transient backend issue)
        #expect(UploadErrorCode.uploadVolumeWriteFailed.isPermanent == false)
        // Integrity mismatch → permanent (same bytes will fail again)
        #expect(UploadErrorCode.uploadIntegrityMismatch.isPermanent == true)
        // Unsupported MIME → permanent (4xx contract violation)
        #expect(UploadErrorCode.unsupportedMediaType.isPermanent == true)
    }

    // The next two tests exercise LiveUploadCoordinator.isPermanent
    // indirectly through the full retry loop. They run against the
    // FakeLakeloomAppClient and assert that:
    //   1. A 500 with the `UPLOAD_VOLUME_WRITE_FAILED` typed code
    //      triggers a retry (not classified permanent).
    //   2. A 400 with the `UPLOAD_INTEGRITY_MISMATCH` typed code
    //      stops immediately on attempt 1.

    private static func makeSandbox() -> (
        coordinator: LiveUploadCoordinator,
        app: FakeLakeloomAppClient,
        fileURL: URL,
        queueStore: UploadQueueStore
    ) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lakeloom-uec-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("audio.m4a", isDirectory: false)
        try? Data([0x01, 0x02, 0x03]).write(to: fileURL)
        let queueStore = UploadQueueStore(fileURL: root.appendingPathComponent("queue.json"))
        let app = FakeLakeloomAppClient()
        let coordinator = LiveUploadCoordinator(
            lakeloomApp: app,
            queueStore: queueStore,
            sleep: { _ in },
            multipartBoundaryProvider: { "fixed-boundary" }
        )
        return (coordinator, app, fileURL, queueStore)
    }

    private static func makePending(fileURL: URL) -> PendingUpload {
        PendingUpload(
            id: "u-\(UUID().uuidString)",
            workspaceID: "ws-1",
            captureSessionID: "cap-1",
            kind: .audio,
            localFileURL: fileURL,
            mimeType: "audio/mp4",
            sizeBytes: 3,
            sha256Hex: "deadbeef",
            clientTimestamp: Date(),
            originalFilename: "audio.m4a",
            createdAt: Date()
        )
    }

    @Test("500 + UPLOAD_VOLUME_WRITE_FAILED typed code retries (transient)")
    func volumeWriteFailedRetries() async throws {
        let (coordinator, app, fileURL, _) = Self.makeSandbox()
        // First attempt fails with the typed volume-write code.
        // Second attempt succeeds — proves the worker retried.
        await app.enqueueResponse(.failure(.httpError(
            status: 500,
            detail: "volume write failed",
            code: "UPLOAD_VOLUME_WRITE_FAILED"
        )))
        await app.enqueueResponse(.success(Data("""
        {
          "id": "remote-volume-retry",
          "kind": "audio",
          "volume_path": "/v/p",
          "mime_type": "audio/mp4",
          "size_bytes": 3,
          "sha256_hex": "deadbeef",
          "uploaded_at": "2026-05-20T15:48:50Z"
        }
        """.utf8)))

        let stream = await coordinator.stateUpdates()
        var iterator = stream.makeAsyncIterator()

        let pending = Self.makePending(fileURL: fileURL)
        try await coordinator.enqueue(pending)
        await coordinator.start()

        var sawSucceeded = false
        for _ in 0..<6 {
            if let change = await iterator.next(), change.state == .succeeded {
                sawSucceeded = true
                break
            }
        }
        #expect(sawSucceeded)
        let calls = await app.requestCalls
        #expect(calls.count == 2)
        await coordinator.stop()
    }

    @Test("400 + UPLOAD_INTEGRITY_MISMATCH typed code fails permanently — no retry")
    func integrityMismatchPermanent() async throws {
        let (coordinator, app, fileURL, _) = Self.makeSandbox()
        await app.enqueueResponse(.failure(.httpError(
            status: 400,
            detail: "sha256 mismatch",
            code: "UPLOAD_INTEGRITY_MISMATCH"
        )))

        let stream = await coordinator.stateUpdates()
        var iterator = stream.makeAsyncIterator()

        let pending = Self.makePending(fileURL: fileURL)
        try await coordinator.enqueue(pending)
        await coordinator.start()

        var finalState: PendingUpload.State?
        for _ in 0..<6 {
            if let change = await iterator.next() {
                if case .failed = change.state {
                    finalState = change.state
                    break
                }
            }
        }
        guard case .failed(_, let permanent) = finalState else {
            Issue.record("expected .failed, got \(String(describing: finalState))")
            return
        }
        #expect(permanent == true)
        let calls = await app.requestCalls
        #expect(calls.count == 1) // no retry
        await coordinator.stop()
    }
}
