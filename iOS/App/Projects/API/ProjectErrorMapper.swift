import Foundation

/// Transport-layer error type produced by ``LiveProjectAPIClient``.
/// ``ProjectService`` translates these onto the public ``ProjectError``
/// surface.
public enum ProjectAPIError: Error, Sendable, Equatable {
    /// HTTP 401 — caller should force-refresh and retry once.
    case unauthorized
    case forbidden(ProjectErrorResponse?)
    case notFound(ProjectErrorResponse?)
    case duplicate(ProjectErrorResponse)
    case badRequest(ProjectErrorResponse?)
    case rateLimited(retryAfter: Date?)
    case payloadTooLarge
    case serverUnavailable(httpStatus: Int)
    case timeout
    case networkUnavailable
    case canceled
    case decodeFailed(reason: String)
    case unexpectedResponse(reason: String)
}

/// Maps `(HTTP status, optional ProjectErrorResponse)` onto the
/// public ``ProjectError`` cases. Lives next to ``LiveProjectAPIClient``
/// so the mapping is one place — ProjectService just calls it.
///
/// See Module 06 §5.5 for the full mapping table.
public enum ProjectErrorMapper {

    public static func map(_ error: any Error) -> ProjectError {
        if let projectError = error as? ProjectError { return projectError }
        guard let apiError = error as? ProjectAPIError else {
            return .unknown(reason: error.localizedDescription)
        }
        switch apiError {
        case .unauthorized:
            return .authFailed(reason: "401 — token rejected after refresh attempt")
        case .forbidden(let envelope):
            let reason = envelope?.message ?? envelope?.error ?? "forbidden"
            return .permissionDenied(reason: reason)
        case .notFound(let envelope):
            let id = envelope?.existingProjectID ?? "<unknown>"
            return .notFound(projectID: id)
        case .duplicate(let envelope):
            return .duplicateName(existingProjectID: envelope.existingProjectID ?? "")
        case .badRequest(let envelope):
            let reason = envelope?.message ?? envelope?.error ?? "bad_request"
            return .validationFailed(reason: reason)
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfter: retryAfter)
        case .payloadTooLarge:
            return .rejectedByServer(httpStatus: 413, reason: "payload_too_large")
        case .serverUnavailable(let status):
            return .serverUnavailable(reason: "HTTP \(status)")
        case .timeout:
            return .timeout
        case .networkUnavailable:
            return .networkUnavailable
        case .canceled:
            return .unknown(reason: "canceled")
        case .decodeFailed(let reason):
            return .unknown(reason: "decode_failed: \(reason)")
        case .unexpectedResponse(let reason):
            return .unknown(reason: reason)
        }
    }

    /// Parse a `Retry-After` header value. Spec allows either an
    /// HTTP-date or a number of seconds — we honor the seconds form
    /// (the common case) and fall through to nil for HTTP-date headers,
    /// which the caller can treat as "use standard backoff."
    public static func parseRetryAfter(_ raw: String?, now: Date = Date()) -> Date? {
        guard let raw, let seconds = Double(raw.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return now.addingTimeInterval(seconds)
    }
}
