import Foundation

/// Factory for the closure that ``LiveOperationQueue`` invokes when
/// draining each ``PendingOperation``.
///
/// Bound at app bootstrap to the live ``CaptureAPIClient`` + the
/// ``ProjectServicing`` actor; routes each variant to the correct
/// HTTP call. Error classification rules apply uniformly across
/// variants:
///
/// * Network unavailable / timeout / 5xx → re-thrown as the original
///   error so the queue treats it as transient and backs off.
/// * 400 / 403 / 409 / decode failure → wrapped in
///   ``OperationPermanentFailure`` so the queue parks the op for the
///   user to inspect; no further retries fire automatically.
/// * **404 on PATCH variants** (state / label) → re-thrown as
///   transient. The create op for the same capture may not have
///   drained yet — the natural drain order will catch up, and a
///   transient retry will eventually find the row.
/// * Auth failures (`notSignedIn` / `authFailed`) → permanent. The
///   queue can't recover from a missing or invalid session token
///   on its own; the user has to re-pair via AccountSettingsView.
enum OperationExecutor {

    static func make(
        captureAPI: any CaptureAPIClient,
        projects: any ProjectServicing,
        logger: AppLogger = AppLogger(category: .ingest)
    ) -> LiveOperationQueue.Executor {
        return { op in
            switch op.variant {
            case .createCaptureSession(
                let captureSessionID,
                let projectID,
                let label,
                let clientTimestamp,
                let deviceID
            ):
                do {
                    _ = try await captureAPI.createCaptureSession(
                        workspaceID: op.workspaceID,
                        projectID: projectID,
                        label: label,
                        clientTimestamp: clientTimestamp,
                        deviceID: deviceID,
                        clientGeneratedID: captureSessionID
                    )
                } catch let error as CaptureAPIError {
                    try throwClassifiedCapture(error: error, isPatch: false)
                }

            case .updateCaptureSessionState(
                let captureSessionID,
                let endState,
                let endedAt
            ):
                let mapped: CaptureSession.EndState
                switch endState {
                case .completed: mapped = .completed
                case .cancelled: mapped = .cancelled
                }
                do {
                    _ = try await captureAPI.updateCaptureSession(
                        workspaceID: op.workspaceID,
                        captureSessionID: captureSessionID,
                        state: mapped,
                        endedAt: endedAt
                    )
                } catch let error as CaptureAPIError {
                    try throwClassifiedCapture(error: error, isPatch: true)
                }

            case .updateCaptureLabel(let captureSessionID, let label):
                do {
                    _ = try await captureAPI.updateCaptureLabel(
                        workspaceID: op.workspaceID,
                        captureSessionID: captureSessionID,
                        label: label
                    )
                } catch let error as CaptureAPIError {
                    try throwClassifiedCapture(error: error, isPatch: true)
                }

            case .createProject, .updateProject:
                // No production caller enqueues these in Phase 3 — the
                // offline-project-create / -edit user flow lands in a
                // separate PR. Park as permanent so a stray enqueue
                // doesn't loop forever; the user (or a diagnostic
                // sweep) can discard it from the outbox.
                await logger.error(
                    "operation.executor.unimplemented_variant",
                    metadata: [
                        "operation_id": .uuidPrefix(op.id),
                        "category": .string(op.variant.category)
                    ],
                    errorCode: "unimplemented"
                )
                throw OperationPermanentFailure(
                    reason: "variant \(op.variant.category) not wired in Phase 3"
                )
            }
        }
    }

    /// Map a `CaptureAPIError` to either an
    /// ``OperationPermanentFailure`` (parks the op) or a plain
    /// re-throw (queue treats as transient). `isPatch` flips 404 to
    /// transient — the parent capture may not exist yet because the
    /// create op hasn't drained.
    private static func throwClassifiedCapture(
        error: CaptureAPIError,
        isPatch: Bool
    ) throws {
        switch error {
        case .networkUnavailable,
             .timeout,
             .serverUnavailable:
            // Transport-layer issues — let the queue back off + retry.
            throw error
        case .notFound where isPatch:
            // Capture row probably not yet created. Retry until the
            // create op catches up.
            throw error
        case .notFound:
            // 404 on a CREATE means the server can't find the project.
            // That's a real validation problem — park.
            throw OperationPermanentFailure(reason: "404: \(String(describing: error))")
        case .validationFailed,
             .forbidden,
             .invalidTransition,
             .decodeFailed,
             .unexpectedResponse:
            throw OperationPermanentFailure(reason: String(describing: error))
        case .notSignedIn, .authFailed:
            // The queue can't fix this — the user must re-pair. Park
            // so the operation surfaces in the outbox; the user can
            // retry after authenticating.
            throw OperationPermanentFailure(reason: "auth: \(String(describing: error))")
        }
    }
}
