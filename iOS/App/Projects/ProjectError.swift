import Foundation

/// Typed errors surfaced by ``ProjectServicing``.
///
/// HTTP status codes from the Databricks App map to these cases via
/// ``ProjectErrorMapper``. Internal helpers may throw `URLError` or
/// `ProjectAPIError`; the ProjectService boundary translates them.
public enum ProjectError: Error, Sendable, Equatable {
    case notSignedIn
    case workspaceMismatch

    /// Client-side validation failed before we hit the network
    /// (empty name, oversize description, etc.).
    case validationFailed(reason: String)

    /// Server returned HTTP 409 — a project with this name already
    /// exists in the workspace. Carries the existing project ID so
    /// the UI can offer "Open existing project."
    case duplicateName(existingProjectID: String)

    /// Server returned HTTP 404. The project doesn't exist or the
    /// signed-in user can't see it under `workspaceID`.
    case notFound(projectID: String)

    /// Server returned HTTP 403. User's token is valid but the App
    /// rejects the call (downstream UC / Lakebase grant missing).
    case permissionDenied(reason: String)

    /// Refresh-failed propagated from AuthService after the inline
    /// 401 retry. The user must sign in again.
    case authFailed(reason: String)

    /// Unstructured 4xx response other than 401/403/404/409 — useful
    /// when the App returns a new error code we don't yet pattern-match on.
    case rejectedByServer(httpStatus: Int, reason: String)

    /// 5xx from the App or its downstream. Retryable from the caller's
    /// perspective.
    case serverUnavailable(reason: String)

    /// Server returned HTTP 429. `retryAfter` carries the absolute date
    /// derived from the response's `Retry-After` header (or nil if absent).
    case rateLimited(retryAfter: Date?)

    case networkUnavailable
    case timeout
    case unknown(reason: String)
}
