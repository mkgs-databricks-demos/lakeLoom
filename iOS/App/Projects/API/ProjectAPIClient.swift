import Foundation

/// Transport-layer protocol for the Databricks App's `/api/v1/projects`
/// endpoints. Stateless — no token storage, no caching. ProjectService
/// composes this with AuthService + the cache to produce user-visible
/// behavior.
///
/// Tests inject ``ScriptedProjectAPIClient``; production wires
/// ``LiveProjectAPIClient``.
public protocol ProjectAPIClient: Sendable {

    /// `GET {appBaseURL}/api/v1/projects?workspace_id={ws}&q={query}&limit=200`.
    /// `query` is sent as-is when non-nil; the App handles substring
    /// matching server-side.
    func list(
        workspaceID: String,
        query: String?,
        limit: Int,
        token: AccessToken,
        endpoint: AppEndpoint
    ) async throws -> ProjectListResponse

    /// `GET {appBaseURL}/api/v1/projects/{project_id}?workspace_id={ws}`.
    func fetch(
        projectID: String,
        workspaceID: String,
        token: AccessToken,
        endpoint: AppEndpoint
    ) async throws -> ProjectMetadata

    /// `POST {appBaseURL}/api/v1/projects` with the idempotency key.
    /// Returns HTTP 201 (or 200 on idempotent re-submit) plus the canonical
    /// ProjectMetadata in the body.
    func create(
        _ payload: CreateProjectPayload,
        token: AccessToken,
        endpoint: AppEndpoint
    ) async throws -> ProjectMetadata

    /// `PATCH {appBaseURL}/api/v1/projects/{project_id}/archive`.
    /// 204 No Content on success.
    func archive(
        projectID: String,
        workspaceID: String,
        token: AccessToken,
        endpoint: AppEndpoint
    ) async throws

    /// `PATCH {appBaseURL}/api/v1/projects/{project_id}/restore`.
    /// 204 No Content on success.
    func unarchive(
        projectID: String,
        workspaceID: String,
        token: AccessToken,
        endpoint: AppEndpoint
    ) async throws
}
