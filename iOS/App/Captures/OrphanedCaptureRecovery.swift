import Foundation

/// Cold-start reconciliation between the data-plane upload queue and the
/// control-plane operation queue.
///
/// **The June-2 field-session deadlock.** A recording's
/// `createCaptureSession` op can fail in a way that parks it (a flaky
/// reconnect, a stale token), after which the operation worker never
/// retries it — `LiveOperationQueue.nextWorkableID` skips permanent ops
/// forever. Meanwhile that recording's audio uploads keep retrying their
/// `UPLOAD_CAPTURE_NOT_FOUND` 404 indefinitely (the upload coordinator
/// treats 404 as transient, expecting the create to "catch up"). Neither
/// queue breaks the stalemate on its own, so the audio is stranded on
/// disk against a session that will never be created.
///
/// On every cold start — after both queues have rehydrated — this walks
/// the pending uploads and, for each capture session that still has
/// non-terminal uploads waiting, revives its create op. The session then
/// lands and the audio drains. `reviveCreate` is a no-op when the create
/// already succeeded or is in flight, so running this unconditionally at
/// launch is safe and cheap.
enum OrphanedCaptureRecovery {

    /// Revive the `createCaptureSession` op for every capture session
    /// that still has non-terminal, capture-routed uploads waiting.
    static func reconcile(
        uploadCoordinator: any UploadCoordinator,
        operationQueue: any OperationQueueing
    ) async {
        let pending = await uploadCoordinator.currentUploads()
        let strandedSessionIDs = Set(
            pending
                .filter { !$0.state.isTerminal }
                .filter { kindDependsOnCaptureSession($0.kind) }
                .map(\.captureSessionID)
        )
        for sessionID in strandedSessionIDs {
            await operationQueue.reviveCreate(forCaptureSessionID: sessionID)
        }
    }

    /// Uploads that POST under `/api/captures/:id/...` depend on the
    /// capture-session row existing. Documents route under projects
    /// (`/api/projects/:id/documents`) and never block on a capture
    /// create, so they're excluded.
    private static func kindDependsOnCaptureSession(_ kind: PendingUpload.Kind) -> Bool {
        switch kind {
        case .audio, .screenshot, .photo: return true
        case .document:                   return false
        }
    }
}
