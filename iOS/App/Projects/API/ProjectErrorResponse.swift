import Foundation

/// Standard error envelope returned by the Databricks App on non-2xx
/// responses. The `error` field is a stable enum value the iOS client
/// pattern-matches on; `message` is a human-readable explanation;
/// `existingProjectID` is set on `project_name_taken` (HTTP 409) so
/// the UI can offer "Open existing project."
///
/// See Module 06 §7.5.
public struct ProjectErrorResponse: Sendable, Equatable, Codable {
    public let error: String
    public let message: String?
    public let existingProjectID: String?

    public init(error: String, message: String?, existingProjectID: String?) {
        self.error = error
        self.message = message
        self.existingProjectID = existingProjectID
    }

    private enum CodingKeys: String, CodingKey {
        case error
        case message
        case existingProjectID = "existing_project_id"
    }

    /// Stable enum values the App returns. Any value the iOS client
    /// doesn't recognize falls through to ``ProjectError/rejectedByServer``
    /// — `MetricsCatalog` registers a counter for "unknown" reasons so
    /// we can detect drift between Genie Code and iOS contracts.
    public enum Reason: String, Sendable {
        case projectNameTaken = "project_name_taken"
        case workspaceNotAuthorized = "workspace_not_authorized"
        case projectNotFound = "project_not_found"
        case validationFailed = "validation_failed"
    }
}
