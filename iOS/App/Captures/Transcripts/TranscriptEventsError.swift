import Foundation

/// Typed errors surfaced by ``TranscriptEventsClient``. Internal
/// helpers may throw ``LakeloomAppError``; the public surface
/// translates those into one of these cases so callers (the
/// soon-to-exist `TranscriptStreamer`, the smoke-test sheet,
/// AppCoordinator) can pattern-match without leaking the transport.
public enum TranscriptEventsError: Error, Sendable, Equatable {

    /// The signed-in user has no active workspace. iOS surfaces this
    /// as "pair to continue."
    case notSignedIn

    /// Server rejected the request body (400 / 422) — usually a
    /// missing required field for the chosen event type.
    case validationFailed(reason: String)

    /// User isn't authorized to write to this paired session.
    case forbidden(reason: String)

    /// Paired session not found, or the user can't see it. Surfaces
    /// when the App's Lakebase row was deleted or the session
    /// expired and was reaped.
    case notFound

    /// Layer 0/1 auth failed — session token expired or revoked.
    /// AppCoordinator surfaces this by dropping the user into the
    /// QR scanner.
    case authFailed(reason: String)

    /// Network reachability dropped during the call.
    case networkUnavailable

    /// Request timed out.
    case timeout

    /// Server returned 5xx — Genie's side has an outage.
    case serverUnavailable(status: Int, reason: String)

    /// JSON decoder couldn't parse the response. Usually means iOS
    /// and server response schemas have drifted.
    case decodeFailed(reason: String)

    /// Caller asked us to send 0 events. We refuse rather than POST
    /// an empty array (the server would 422; we save the round-trip).
    case empty

    /// Caller asked us to send more than 100 events in one POST. Per
    /// Genie's note, the server caps batches at 100; surface this
    /// before sending so the caller can split.
    case batchTooLarge(count: Int)

    /// Anything else — keeps the catch-all small + diagnosable.
    case unexpectedResponse(reason: String)
}

extension TranscriptEventsError {
    /// Convert a ``LakeloomAppError`` from `LakeloomAppClient` into
    /// the transcript-specific surface. Shape matches
    /// ``CaptureAPIError.from(_:)`` so callers see the same patterns
    /// across the capture + transcript subsystems.
    static func from(_ error: LakeloomAppError) -> TranscriptEventsError {
        switch error {
        case .workspaceNotConfigured: return .notSignedIn
        case .networkUnavailable: return .networkUnavailable
        case .timeout: return .timeout
        case .tokenExchangeFailed(let reason):
            return .authFailed(reason: reason)
        case .unauthorized(let kind, let detail):
            switch kind {
            case .tokenNotFound, .tokenExpired:
                return .authFailed(reason: detail)
            case .signatureInvalid, .timestampSkew, .unknown:
                return .unexpectedResponse(reason: "Layer 1 \(kind.rawValue): \(detail)")
            }
        case .httpError(let status, let detail, _):
            switch status {
            case 400, 422: return .validationFailed(reason: detail)
            case 403: return .forbidden(reason: detail)
            case 404: return .notFound
            case 500...599: return .serverUnavailable(status: status, reason: detail)
            default: return .unexpectedResponse(reason: "HTTP \(status): \(detail)")
            }
        case .transport(let reason):
            return .unexpectedResponse(reason: reason)
        case .decodeFailed(let reason):
            return .decodeFailed(reason: reason)
        }
    }
}
