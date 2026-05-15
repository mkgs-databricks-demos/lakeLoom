import Foundation

/// Typed errors surfaced by ``CaptureAPIClient``. Internal helpers
/// may throw ``LakeloomAppError``; the public surface translates
/// those into one of these cases so callers (CaptureService,
/// AppCoordinator) can pattern-match without leaking the transport
/// layer.
public enum CaptureAPIError: Error, Sendable, Equatable {
    /// The signed-in user has no active workspace. iOS surfaces this
    /// as "pair to continue."
    case notSignedIn

    /// Server rejected the request body (e.g., label too long).
    case validationFailed(reason: String)

    /// User isn't authorized to operate on this capture (e.g., the
    /// session belongs to a different user, or the project is in a
    /// workspace the user isn't paired with).
    case forbidden(reason: String)

    /// Capture session ID not found, or the user can't see it (which
    /// the server intentionally surfaces as 404 to avoid leaking
    /// existence).
    case notFound

    /// State transition rejected — e.g., trying to `PATCH state =
    /// completed` on a capture that's already `cancelled`. Server
    /// returns 409.
    case invalidTransition(reason: String)

    /// Layer 0/1 auth failed — session token expired or revoked.
    /// AppCoordinator surfaces this by dropping the user into the
    /// QR scanner.
    case authFailed(reason: String)

    /// Network reachability dropped during the call.
    case networkUnavailable

    /// Request timed out.
    case timeout

    /// Server returned 5xx — Genie's side has an outage. Caller
    /// surfaces "Something went wrong on our end, try again."
    case serverUnavailable(status: Int, reason: String)

    /// Decoder couldn't parse the response. Usually means iOS and
    /// server schemas have drifted.
    case decodeFailed(reason: String)

    /// Anything else — keeps the catch-all small + diagnosable.
    case unexpectedResponse(reason: String)
}

extension CaptureAPIError {
    /// Convert a ``LakeloomAppError`` from `LakeloomAppClient` into
    /// the capture-specific surface.
    static func from(_ error: LakeloomAppError) -> CaptureAPIError {
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
        case .httpError(let status, let detail):
            switch status {
            case 400: return .validationFailed(reason: detail)
            case 403: return .forbidden(reason: detail)
            case 404: return .notFound
            case 409: return .invalidTransition(reason: detail)
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
