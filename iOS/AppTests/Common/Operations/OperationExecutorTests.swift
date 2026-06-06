import Foundation
import Testing

@testable import LakeloomApp

/// Classification tests for ``OperationExecutor`` — specifically the
/// June-2 field-session fix: a `createCaptureSession` op gates an
/// entire recording's audio, so it must only park on a *definitive*
/// client error. Anything ambiguous stays transient (revivable) so the
/// recording's chunks are never stranded.
@Suite("OperationExecutor — capture op failure classification")
struct OperationExecutorTests {

    private static func makeExecutor(
        captureAPI: FakeCaptureAPIClient
    ) -> LiveOperationQueue.Executor {
        OperationExecutor.make(captureAPI: captureAPI, projects: StubProjectServicing())
    }

    private static func createOp() -> PendingOperation {
        PendingOperation(
            workspaceID: "ws-1",
            variant: .createCaptureSession(
                captureSessionID: "cap-A",
                projectID: "proj-1",
                label: nil,
                clientTimestamp: Date(timeIntervalSince1970: 1_747_152_120),
                deviceID: nil
            )
        )
    }

    private static func patchOp() -> PendingOperation {
        PendingOperation(
            workspaceID: "ws-1",
            variant: .updateCaptureSessionState(
                captureSessionID: "cap-A",
                endState: .completed,
                endedAt: Date(timeIntervalSince1970: 1_747_152_200)
            )
        )
    }

    /// Run the executor for `op` after the fake is primed to fail with
    /// `error`, and classify the outcome: `.permanent` if the executor
    /// wrapped it in `OperationPermanentFailure` (queue parks it),
    /// `.transient` if it re-threw the original (queue retries).
    private enum Outcome { case transient, permanent, noThrow }

    private static func outcome(
        op: PendingOperation,
        failingWith error: CaptureAPIError
    ) async -> Outcome {
        let api = FakeCaptureAPIClient()
        await api.enqueueCreateResult(.failure(error))
        await api.enqueueUpdateResult(.failure(error))
        let exec = makeExecutor(captureAPI: api)
        do {
            try await exec(op)
            return .noThrow
        } catch is OperationPermanentFailure {
            return .permanent
        } catch {
            return .transient
        }
    }

    // MARK: - createCaptureSession: bias toward transient/revivable

    @Test("create + notFound is transient (project create may still be draining)")
    func createNotFoundTransient() async {
        #expect(await Self.outcome(op: Self.createOp(), failingWith: .notFound) == .transient)
    }

    @Test("create + decodeFailed is transient (cold-start edge shouldn't strand audio)")
    func createDecodeTransient() async {
        #expect(await Self.outcome(op: Self.createOp(), failingWith: .decodeFailed(reason: "x")) == .transient)
    }

    @Test("create + unexpectedResponse is transient")
    func createUnexpectedTransient() async {
        #expect(await Self.outcome(op: Self.createOp(), failingWith: .unexpectedResponse(reason: "x")) == .transient)
    }

    @Test("create + serverUnavailable is transient")
    func createServerUnavailableTransient() async {
        #expect(await Self.outcome(op: Self.createOp(), failingWith: .serverUnavailable(status: 503, reason: "x")) == .transient)
    }

    // MARK: - createCaptureSession: still park on definitive client errors

    @Test("create + validationFailed parks permanent")
    func createValidationPermanent() async {
        #expect(await Self.outcome(op: Self.createOp(), failingWith: .validationFailed(reason: "x")) == .permanent)
    }

    @Test("create + forbidden parks permanent")
    func createForbiddenPermanent() async {
        #expect(await Self.outcome(op: Self.createOp(), failingWith: .forbidden(reason: "x")) == .permanent)
    }

    @Test("create + authFailed parks permanent (needs re-pair; revival re-drives later)")
    func createAuthPermanent() async {
        #expect(await Self.outcome(op: Self.createOp(), failingWith: .authFailed(reason: "x")) == .permanent)
    }

    // MARK: - PATCH classification unchanged

    @Test("patch + notFound is transient (create op may not have drained)")
    func patchNotFoundTransient() async {
        #expect(await Self.outcome(op: Self.patchOp(), failingWith: .notFound) == .transient)
    }

    @Test("patch + decodeFailed parks permanent (unchanged — only create softens decode)")
    func patchDecodePermanent() async {
        #expect(await Self.outcome(op: Self.patchOp(), failingWith: .decodeFailed(reason: "x")) == .permanent)
    }

    @Test("patch + unexpectedResponse parks permanent (unchanged)")
    func patchUnexpectedPermanent() async {
        #expect(await Self.outcome(op: Self.patchOp(), failingWith: .unexpectedResponse(reason: "x")) == .permanent)
    }
}
