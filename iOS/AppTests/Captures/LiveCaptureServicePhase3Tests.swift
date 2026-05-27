import Foundation
import Testing

@testable import LakeloomApp

/// Phase 3 cutover tests — when `LiveCaptureService` is wired with
/// an `OperationQueueing`, `startCapture` MUST:
///   * generate a UUIDv7 locally + use it as the capture session id
///   * enqueue a `.createCaptureSession` op carrying that id +
///     project + label + clientTimestamp + deviceID
///   * start the recorder immediately, without calling the
///     `captureAPI.createCaptureSession` path on the main thread
///
/// And on the cleanup paths, `cancelCapture` MUST enqueue a
/// `.updateCaptureSessionState(.cancelled)` op rather than firing a
/// direct PATCH.
@Suite("LiveCaptureService — Phase 3 (operation-queue cutover)")
struct LiveCaptureServicePhase3Tests {

    private static let workspaceID = "ws-1"
    private static let projectID = "proj-1"
    private static let fixedNow = Date(timeIntervalSince1970: 1_747_152_120)

    private struct Bundle {
        let service: LiveCaptureService
        let api: FakeCaptureAPIClient
        let recorder: FakeAudioRecorder
        let uploads: FakeUploadCoordinator
        let queue: FakeOperationQueue
    }

    private static func makeBundle() -> Bundle {
        let api = FakeCaptureAPIClient()
        let recorder = FakeAudioRecorder()
        let uploads = FakeUploadCoordinator()
        let queue = FakeOperationQueue()
        let service = LiveCaptureService(
            captureAPI: api,
            recorder: recorder,
            uploadCoordinator: uploads,
            operationQueue: queue,
            nowProvider: { fixedNow },
            uploadIDProvider: { "u-1" },
            fileHasher: { _ in "deadbeef" }
        )
        return Bundle(service: service, api: api, recorder: recorder, uploads: uploads, queue: queue)
    }

    @Test("startCapture enqueues createCaptureSession and starts the recorder — no direct API call")
    func startEnqueuesAndStartsRecorder() async throws {
        let bundle = Self.makeBundle()

        try await bundle.service.startCapture(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            label: "Kickoff"
        )

        // Direct API path must NOT have fired.
        let createCalls = await bundle.api.createCalls
        #expect(createCalls.isEmpty)

        // Exactly one op enqueued, with the createCaptureSession variant.
        let enqueued = await bundle.queue.enqueued
        #expect(enqueued.count == 1)
        guard let op = enqueued.first,
              case .createCaptureSession(let captureSessionID, let projectID, let label, _, _) = op.variant
        else {
            Issue.record("expected createCaptureSession variant, got \(enqueued.first?.variant as Any)")
            return
        }
        #expect(op.workspaceID == Self.workspaceID)
        #expect(projectID == Self.projectID)
        #expect(label == "Kickoff")
        // The locally-generated id should be a UUIDv7 (36 chars with
        // hyphens in the right positions); not empty, not a server
        // placeholder.
        #expect(captureSessionID.count == 36)
        #expect(!captureSessionID.contains("cap-"))

        // Recorder.start was invoked with the SAME local id.
        let recorderCalls = await bundle.recorder.calls
        guard case .start(let recorderID) = recorderCalls.first else {
            Issue.record("expected first recorder call to be .start, got \(String(describing: recorderCalls.first))")
            return
        }
        #expect(recorderID == captureSessionID)
    }

    @Test("cancelCapture enqueues updateCaptureSessionState(.cancelled)")
    func cancelEnqueuesStatePatch() async throws {
        let bundle = Self.makeBundle()

        try await bundle.service.startCapture(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            label: nil
        )
        try await bundle.service.cancelCapture()

        let enqueued = await bundle.queue.enqueued
        // First op is the create from startCapture; second is the
        // cancel state PATCH from cancelCapture.
        #expect(enqueued.count == 2)
        guard
            enqueued.count == 2,
            case .createCaptureSession(let createID, _, _, _, _) = enqueued[0].variant,
            case .updateCaptureSessionState(let cancelID, let endState, _) = enqueued[1].variant
        else {
            Issue.record("expected create + cancel pair, got \(enqueued.map(\.variant))")
            return
        }
        #expect(createID == cancelID)
        #expect(endState == .cancelled)

        // The direct PATCH path must NOT have fired.
        let updateCalls = await bundle.api.updateCalls
        #expect(updateCalls.isEmpty)
    }
}
