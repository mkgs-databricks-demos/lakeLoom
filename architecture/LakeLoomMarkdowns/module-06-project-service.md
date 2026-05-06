# Module 06 — ProjectService

**Product:** Lakeloom
**Status:** Design — pre-implementation
**Last updated:** 2026-05-06
**Depends on:** AuthService (Module 01) for OAuth bearer tokens; shared HTTP client utilities
**Depended on by:** AppCoordinator (Module 05) for project picker and create flows; Settings UI for project management

---

## 1. Purpose

ProjectService is the iOS app's interface to project metadata, served by the **Databricks App's REST API**. It owns:

- Listing available projects for a workspace (filtered by `archived = false`)
- Creating new projects from the iOS app
- Archiving projects (soft delete; never hard delete)
- Fetching a single project by ID
- Setting and retrieving the user's default project per workspace
- An in-memory cache with TTL to keep the project picker instant
- The HTTP client that talks to the Databricks App's project endpoints

ProjectService does **not** own the underlying storage — the Databricks App does, and per lakeLoom's "Lakebase via App's REST API, never directly from iOS" rule, the App is free to back projects with Lakebase, Delta, or whatever fits best server-side. It does not own user authentication — AuthService does. It does not own session-to-project association — that's done at session start by AppCoordinator embedding the project ID in the `CaptureRequest`.

> **Architectural note.** Earlier drafts of this module had iOS calling the Databricks SQL Statement Execution API directly against a Delta table `main.lakeloom.projects`, with iOS-side schema bootstrap and warehouse resolution. That has been replaced by an HTTP/JSON contract with the Databricks App for three reasons: (1) lakeLoom's single-network-boundary rule — iOS speaks HTTPS to one host (the App), nothing else; (2) decoupling — schema migrations server-side don't require an App Store update; (3) the "Lakebase as the rule of thumb" preference is naturally realized by the App owning the Postgres connection. Warehouse resolution and schema bootstrap are now App-side concerns and are no longer in this module.

---

## 2. Design Principles

1. **Source of truth lives server-side.** The local cache is a UX optimization, never authoritative. Every write goes to the Databricks App first; the cache is updated from the response.
2. **Reads are cached aggressively.** Project lists rarely change during a session. A 5-minute in-memory TTL plus a "stale-while-revalidate" pattern keeps the UI instant.
3. **Writes are immediate and synchronous from the user's perspective.** Project creation must succeed against the App before the new project is selectable. No optimistic UI for v1.
4. **JSON-only over HTTPS.** All requests use `application/json` with the user's OAuth U2M bearer in the `Authorization` header. Validation happens both client-side (cheap fail-fast) and App-side (authoritative).
5. **Soft delete only.** Archiving is a `PATCH /projects/{id}/archive` that sets `archived = true`; nothing is ever physically deleted from the iOS surface. Operators can purge server-side if they want.
6. **Workspace isolation is enforced server-side, trusted client-side.** The App enforces workspace scoping using the user's OAuth identity; iOS includes `workspace_id` in the request as a routing hint, but the App is the security boundary.
7. **Default project is a per-user, per-workspace UserDefaults key.** Storing this server-side would require another endpoint; v1 keeps it local. Users on a new device pick a project at first capture.
8. **No iOS-side schema concerns.** The App owns whether projects live in Lakebase, Delta, or both. iOS sees only `ProjectMetadata`. If the App is unhealthy, iOS shows a clear error and a retry affordance.
9. **Failures are typed.** Project errors propagate as a small enum that callers can pattern-match on.
10. **Listing is paginated but visually flat.** The App returns all non-archived projects up to a 200-row cap; users with more than 200 projects per workspace get a search box (v1) with a server-side `q=` filter.
11. **Single network boundary.** Same rule as Module 03: iOS speaks HTTPS to the Databricks App and nothing else. No direct SQL Statement Execution, no direct Postgres, no direct Unity Catalog REST calls from iOS.

---

## 3. Public Surface

### 3.1 Protocol

```swift
protocol ProjectServicing: Sendable {
    /// Bring the service into a usable state. Lightweight — does not block on
    /// network. Heavy work (initial fetch) is deferred.
    func start() async

    /// List non-archived projects for the given workspace. Honors cache TTL.
    /// `forceRefresh` bypasses cache.
    func list(workspaceID: String, forceRefresh: Bool) async throws -> [ProjectMetadata]

    /// Fetch a single project by ID. Cache-first, then network.
    func fetch(projectID: String, workspaceID: String) async throws -> ProjectMetadata

    /// Create a new project in the given workspace. Returns the created record.
    /// On success, the cache is updated and the project is immediately selectable.
    func create(name: String,
                description: String?,
                workspaceID: String) async throws -> ProjectMetadata

    /// Archive a project (soft delete).
    func archive(projectID: String, workspaceID: String) async throws

    /// Restore an archived project.
    func unarchive(projectID: String, workspaceID: String) async throws

    /// The user's default project for a workspace, if set.
    /// Reads from UserDefaults; cheap; sync.
    func defaultProject(workspaceID: String) async -> ProjectMetadata?

    /// Set the default project for a workspace.
    func setDefault(projectID: String, workspaceID: String) async throws

    /// First available (non-archived, most recently updated) project for a workspace.
    /// Used as a fallback when no default is set.
    func firstAvailableProject(workspaceID: String) async -> ProjectMetadata?

    /// Refresh the cache for a workspace if the cached entry is older than `ttl`.
    /// Non-throwing; logs and gives up on error.
    func refreshIfStale(workspaceID: String) async

    /// Stream of changes to the project list for any workspace.
    /// UI subscribes to keep the picker live.
    var changes: AsyncStream<ProjectChangeEvent> { get }
}
```

### 3.2 Value Types

```swift
struct ProjectMetadata: Sendable, Equatable, Identifiable, Codable {
    let id: String                        // project_id, UUIDv7
    let name: String
    let description: String?
    let workspaceID: String
    let createdByUserID: String
    let createdByUsername: String
    let createdAt: Date
    let updatedAt: Date
    let archived: Bool
}

enum ProjectChangeEvent: Sendable {
    case listRefreshed(workspaceID: String, projects: [ProjectMetadata])
    case projectCreated(ProjectMetadata)
    case projectArchived(projectID: String, workspaceID: String)
    case projectUnarchived(ProjectMetadata)
    case defaultChanged(workspaceID: String, projectID: String?)
}

enum ProjectError: Error, Sendable, Equatable {
    case notSignedIn
    case workspaceMismatch                          // requested workspaceID != active
    case validationFailed(reason: String)            // name empty, too long, etc.
    case duplicateName(existingProjectID: String)
    case notFound(projectID: String)
    case permissionDenied(reason: String)            // HTTP 403
    case rejectedByServer(httpStatus: Int, reason: String)  // 4xx other than 401/403/404/409
    case serverUnavailable(reason: String)           // 5xx from the App
    case rateLimited(retryAfter: Date?)              // HTTP 429
    case networkUnavailable
    case timeout
    case unknown(reason: String)
}

struct ProjectServiceDiagnostics: Sendable {
    let cacheEntries: Int
    let cacheHitRateLastHour: Double?
    let lastListFetchAt: Date?
    let lastCreateAt: Date?
    let totalListCallsLifetime: Int64
    let totalCreateCallsLifetime: Int64
    let lastAppErrorReason: String?               // last non-network error reason from the App
}
```

---

## 4. Internal Architecture

```
┌─────────────────────────────────────────────────────────┐
│                  ProjectService (actor)                 │
└─────────────────────────────────────────────────────────┘
       │                  │                    │
       ▼                  ▼                    ▼
┌──────────────┐  ┌────────────────┐  ┌──────────────────┐
│  Project     │  │  ProjectAPI-   │  │  Defaults Store  │
│  Cache       │  │  Client        │  │  (UserDefaults   │
│  (in-memory, │  │  (URLSession,  │  │   for default    │
│   per-       │  │   OAuth Bearer,│  │   project per    │
│   workspace) │  │   JSON over    │  │   workspace)     │
│              │  │   HTTPS)       │  │                  │
└──────────────┘  └────────┬───────┘  └──────────────────┘
                           │
                           ▼
                ┌──────────────────────────────────────┐
                │  Databricks App (TypeScript)         │
                │  GET    /api/v1/projects             │
                │  GET    /api/v1/projects/{id}        │
                │  POST   /api/v1/projects             │
                │  PATCH  /api/v1/projects/{id}/archive│
                │  PATCH  /api/v1/projects/{id}/restore│
                └──────────────────────────────────────┘
```

### 4.1 Concurrency Model

- `ProjectService` is a Swift `actor`. Public method calls serialize through it.
- The cache lives inside the actor; reads/writes are isolated.
- The ProjectAPIClient is a `Sendable` struct with no mutable state — each call constructs a fresh `URLRequest`.
- `changes` is an `AsyncStream` with a single internal continuation owned by the actor.

### 4.2 The Cache

Per-workspace cache entries:

```swift
private struct CacheEntry: Sendable {
    let projects: [ProjectMetadata]
    let fetchedAt: Date
    var ttl: TimeInterval = 300                 // 5 minutes
    var isStale: Bool { Date().timeIntervalSince(fetchedAt) > ttl }
}

private var cache: [String: CacheEntry] = [:]   // keyed by workspaceID
private var inflightFetches: [String: Task<[ProjectMetadata], Error>] = [:]
```

The `inflightFetches` dictionary deduplicates concurrent fetches: if the project picker view appears twice in quick succession, both subscribers wait on the same network call.

---

## 5. ProjectAPIClient — HTTP Implementation

The client is a thin wrapper around `URLSession` that talks to the Databricks App's project endpoints. All ProjectService calls go through it.

### 5.1 Why HTTP to the App, Not SQL Statement Execution

Earlier drafts had iOS calling Databricks' `/api/2.0/sql/statements` directly. This was rejected for the same reasons we use a REST proxy for ingest:

- **Single network boundary on iOS** (the lakeLoom rule).
- **Decoupling.** A Lakebase migration server-side becomes invisible to the iOS client; with direct SQL the schema and the wire format were the same artifact.
- **Storage flexibility.** The App can decide whether projects live in Lakebase Postgres (the default per lakeLoom's Lakebase rule of thumb), in Delta, or both. iOS doesn't care.
- **Operational simplicity.** No warehouse resolution, no schema bootstrap, no DDL privilege failures on iOS.

iOS owns the JSON contract; the App owns everything below it.

### 5.2 API Surface

```swift
protocol ProjectAPIClienting: Sendable {
    func list(workspaceID: String,
              query: String?,
              token: AccessToken,
              endpoint: AppEndpoint) async throws -> [ProjectMetadata]

    func fetch(projectID: String,
               workspaceID: String,
               token: AccessToken,
               endpoint: AppEndpoint) async throws -> ProjectMetadata

    func create(_ payload: CreateProjectPayload,
                token: AccessToken,
                endpoint: AppEndpoint) async throws -> ProjectMetadata

    func archive(projectID: String,
                 workspaceID: String,
                 token: AccessToken,
                 endpoint: AppEndpoint) async throws

    func unarchive(projectID: String,
                   workspaceID: String,
                   token: AccessToken,
                   endpoint: AppEndpoint) async throws
}

struct CreateProjectPayload: Sendable, Codable {
    let name: String
    let description: String?
    let workspaceID: String
    let clientGeneratedID: String   // UUIDv7 from iOS for idempotent retry
}
```

The `clientGeneratedID` lets a `POST /projects` retry safely: the App treats `(workspace_id, clientGeneratedID)` as the idempotency key and returns the same `ProjectMetadata` on duplicate submits.

### 5.3 Request Construction

```swift
private func makeRequest(method: String, path: String, body: Data?, token: AccessToken, endpoint: AppEndpoint) -> URLRequest {
    let url = endpoint.url.appendingPathComponent(path)
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
    request.setValue(token.workspaceID, forHTTPHeaderField: "X-Databricks-Workspace-Id")
    request.setValue(SchemaVersion.current, forHTTPHeaderField: "X-Lakeloom-Schema-Version")
    request.timeoutInterval = 15
    request.httpBody = body
    return request
}
```

Same headers as Module 03's IngestProxyClient — consistent across the iOS surface.

### 5.4 Response Shapes

**List:**
```http
GET {appBaseURL}/api/v1/projects?workspace_id={ws}&q={query}&limit=200
```
```json
{
  "projects": [
    {
      "project_id": "proj_01975e4f3a7c",
      "project_name": "Customer 360 Lakehouse",
      "description": "...",
      "workspace_id": "1234567890123456",
      "created_by_user_id": "1234567890123456",
      "created_by_username": "jhammond@acme.com",
      "created_at": "2026-04-20T14:00:00.000Z",
      "updated_at": "2026-05-02T18:14:22.331Z",
      "archived": false
    }
  ],
  "truncated": false
}
```

**Fetch single:**
```http
GET {appBaseURL}/api/v1/projects/{project_id}?workspace_id={ws}
```
```json
{
  "project_id": "...",
  ...
}
```

**Create:**
```http
POST {appBaseURL}/api/v1/projects
Content-Type: application/json

{
  "client_generated_id": "01975e4f-...",
  "name": "Customer 360 Lakehouse",
  "description": "...",
  "workspace_id": "1234567890123456"
}
```
Response: full `ProjectMetadata` (HTTP 201 on first submit, 200 on idempotent re-submit).

**Archive / Unarchive:**
```http
PATCH {appBaseURL}/api/v1/projects/{project_id}/archive
PATCH {appBaseURL}/api/v1/projects/{project_id}/restore
```
Body: `{ "workspace_id": "..." }`. Response: 204 No Content on success.

### 5.5 HTTP Error Mapping

| HTTP status | Mapped to | Notes |
|---|---|---|
| 401 | force-refresh + retry once; on second 401 → `AuthError.refreshFailed` propagates | Same pattern as Module 03 |
| 403 | `ProjectError.permissionDenied` | App rejects user's downstream authorization |
| 404 | `ProjectError.notFound` | On `fetch`, `archive`, `unarchive` |
| 400 | `ProjectError.validationFailed(reason:)` | App validates name/description; reason from response body |
| 409 | `ProjectError.duplicateName(existingProjectID:)` | App returns the existing project ID in the body |
| 429 | `ProjectError.rateLimited(retryAfter:)` | Honor `Retry-After` header |
| 408, 504, `URLError.timedOut` | `ProjectError.timeout` | |
| 500, 502, 503 | `ProjectError.serverUnavailable(reason:)` | Retryable from caller's perspective |
| `URLError.notConnectedToInternet` | `ProjectError.networkUnavailable` | |
| anything else | `ProjectError.unknown(reason:)` | |

The App's response body for non-2xx responses follows a small standard:
```json
{
  "error": "project_name_taken",
  "message": "A project named 'Customer 360 Lakehouse' already exists in this workspace.",
  "existing_project_id": "proj_01975e4f3a7c"
}
```
The `error` field is a stable enum value; iOS pattern-matches on it for typed handling.

---

## 6. Endpoint Resolution and Configuration

The Databricks App's base URL is per-workspace and stable across sessions. ProjectService shares the `EndpointResolver` with IngestService (Module 03) — there's exactly one App URL per workspace, and both modules call into it.

### 6.1 Resolver Behavior

```swift
protocol AppEndpointResolving: Sendable {
    func resolve(workspaceID: String) async throws -> AppEndpoint
    func invalidate(workspaceID: String) async
}

struct AppEndpoint: Sendable, Equatable {
    let url: URL                    // base URL up to but not including /api/v1/...
    let resolvedAt: Date
}
```

Resolution: see Module 03 §7.2. Same code path, same cache, same TTL. Both modules call `resolver.resolve(workspaceID:)` before each request and let it manage TTL transparently.

---

## 7. Operations — REST Endpoint Contracts

All operations against the Databricks App. The App owns storage; iOS owns the contract here.

### 7.1 List

```
GET {appBaseURL}/api/v1/projects?workspace_id={ws}&limit=200&include_archived=false
```

Response: `{ "projects": [...], "truncated": false }`. Sorted by `updated_at` descending.

### 7.2 List with Search

```
GET {appBaseURL}/api/v1/projects?workspace_id={ws}&q={user_input}&limit=200
```

`q` is the user's search string — sent as-is, URL-encoded. The App handles escaping and matching strategy (case-insensitive substring match against `name` and `description` is the v1 behavior).

### 7.3 Fetch by ID

```
GET {appBaseURL}/api/v1/projects/{project_id}?workspace_id={ws}
```

`workspace_id` is required as a query parameter so the App can validate the user has access to this project under that workspace.

### 7.4 Create

```
POST {appBaseURL}/api/v1/projects
Content-Type: application/json

{
  "client_generated_id": "{UUIDv7}",
  "name": "Customer 360 Lakehouse",
  "description": "Optional description",
  "workspace_id": "1234567890123456"
}
```

- `client_generated_id` (UUIDv7) is the **idempotency key**. Re-submitting the same `(workspace_id, client_generated_id)` returns the existing project (HTTP 200) instead of creating a duplicate (HTTP 201).
- The App authoritatively sets `created_at`, `updated_at`, `created_by_user_id`, `created_by_username` from the OAuth identity in the bearer token.
- iOS does **not** send a `project_id` — the App returns the canonical one in the response. (For idempotency, the App may use `client_generated_id` as the `project_id` directly, or generate a separate one; iOS reads what's in the response.)

Response (HTTP 201 or 200 on idempotent retry):
```json
{ "project_id": "...", "project_name": "...", ... }
```

### 7.5 Duplicate Name Handling

The App is the authority on uniqueness. If the user submits a name that already exists in the workspace (and is not archived), the App returns:

```
HTTP 409 Conflict
Content-Type: application/json

{
  "error": "project_name_taken",
  "message": "A project named 'Customer 360 Lakehouse' already exists in this workspace.",
  "existing_project_id": "proj_01975e4f3a7c"
}
```

iOS maps this to `ProjectError.duplicateName(existingProjectID: "proj_01975e4f3a7c")`. The UI then offers "Open existing project" or "Choose a different name." No separate iOS-side pre-check round trip — the App does it atomically.

### 7.6 Archive / Unarchive

```
PATCH {appBaseURL}/api/v1/projects/{project_id}/archive
PATCH {appBaseURL}/api/v1/projects/{project_id}/restore
Content-Type: application/json

{ "workspace_id": "1234567890123456" }
```

Response: HTTP 204 No Content on success. HTTP 404 if the project doesn't exist or the user lacks access.

---

## 8. Validation

Project name validation runs client-side before any API call. The Databricks App is the authoritative validator, but failing fast on iOS avoids round trips for obvious mistakes:

```swift
enum ProjectValidator {
    static func validateName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProjectError.validationFailed(reason: "Name cannot be empty.")
        }
        guard trimmed.count <= 200 else {
            throw ProjectError.validationFailed(reason: "Name must be 200 characters or fewer.")
        }
        guard trimmed.unicodeScalars.allSatisfy(\.isAllowedInProjectName) else {
            throw ProjectError.validationFailed(reason: "Name contains invalid characters.")
        }
        return trimmed
    }

    static func validateDescription(_ raw: String?) throws -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 2000 else {
            throw ProjectError.validationFailed(reason: "Description must be 2000 characters or fewer.")
        }
        return trimmed
    }
}
```

Allowed characters in name: alphanumerics, spaces, dashes, underscores, dots, slashes, parentheses, ampersand. Tabs, newlines, control chars rejected. This is conservative; we can loosen in v1.x.

---

## 9. Caching Strategy

### 10.1 Cache Operations

```swift
private func loadList(workspaceID: String, forceRefresh: Bool) async throws -> [ProjectMetadata] {
    if !forceRefresh, let entry = cache[workspaceID], !entry.isStale {
        return entry.projects
    }
    if let inflight = inflightFetches[workspaceID] {
        return try await inflight.value
    }
    let task = Task<[ProjectMetadata], Error> { [weak self] in
        guard let self else { throw ProjectError.unknown(reason: "service deallocated") }
        let projects = try await self.fetchListFromServer(workspaceID: workspaceID)
        await self.cacheProjects(projects, workspaceID: workspaceID)
        return projects
    }
    inflightFetches[workspaceID] = task
    defer { inflightFetches[workspaceID] = nil }
    return try await task.value
}
```

### 10.2 Stale-While-Revalidate

When the project picker opens with a stale-but-present cache, we return the cached list immediately and trigger a background refresh:

```swift
func list(workspaceID: String, forceRefresh: Bool = false) async throws -> [ProjectMetadata] {
    if forceRefresh {
        return try await loadList(workspaceID: workspaceID, forceRefresh: true)
    }
    if let entry = cache[workspaceID], !entry.isStale {
        return entry.projects
    }
    if let entry = cache[workspaceID] {
        // Stale: return immediately, refresh in background.
        Task { try? await self.loadList(workspaceID: workspaceID, forceRefresh: true) }
        return entry.projects
    }
    return try await loadList(workspaceID: workspaceID, forceRefresh: false)
}
```

Background refreshes emit `ProjectChangeEvent.listRefreshed` so the UI updates if the list changed.

### 10.3 Cache Invalidation

The cache is invalidated:
- On `create` — the new project is appended to the cached list immediately
- On `archive` — the archived project is removed from the cached list
- On workspace switch — the previous workspace's cache is retained (cheap; tens of bytes); we just don't read it
- On sign-out of a workspace — all entries for that workspace are cleared
- After 5 minutes of staleness — a fresh fetch is required
- On a `forceRefresh: true` call (pull-to-refresh)

### 10.4 Single-Project Cache

`fetch(projectID:workspaceID:)` first scans the cached list for a match; if not present, it queries the server with the by-id template. We do not maintain a separate single-item cache — the list cache covers the common case.

---

## 10. Default Project

The user's default project per workspace is stored in `UserDefaults`. v1 keeps this client-local for simplicity.

### 11.1 Storage Layout

UserDefaults key: `project.default.<workspaceID>` → `String` (project ID), or absent.

### 11.2 API

```swift
func defaultProject(workspaceID: String) async -> ProjectMetadata? {
    guard let projectID = defaultsStore.defaultProjectID(workspaceID: workspaceID) else {
        return nil
    }
    do {
        return try await fetch(projectID: projectID, workspaceID: workspaceID)
    } catch ProjectError.notFound {
        // The default project was archived or deleted. Clear the default.
        defaultsStore.clearDefault(workspaceID: workspaceID)
        return nil
    } catch {
        // Network error — return nil; AppCoordinator will fall back to
        // firstAvailableProject().
        return nil
    }
}

func setDefault(projectID: String, workspaceID: String) async throws {
    // Verify the project exists before saving.
    _ = try await fetch(projectID: projectID, workspaceID: workspaceID)
    defaultsStore.setDefault(projectID: projectID, workspaceID: workspaceID)
    changesContinuation.yield(.defaultChanged(workspaceID: workspaceID, projectID: projectID))
}
```

### 11.3 Server-Side Default (v1.x)

A future migration moves defaults to a Databricks user-prefs table, so a user's choice on iPhone follows them to iPad / web. Designed-out for v1 to minimize the schema.

---

## 11. Integration Points

### 12.1 With AuthService

ProjectService calls `auth.currentToken()` before every Project API call. The token is included as the `Authorization: Bearer ...` header. On 401, ProjectService calls `auth.currentToken(forceRefresh: true)` and retries once — same pattern as IngestService and StorageService.

If the user signs out the active workspace mid-call, the in-flight call returns whatever it gets (likely 401), and the result propagates as a typed error. ProjectService doesn't need to know about workspace switches — the next call uses the new active workspace's token.

### 12.2 With AppCoordinator

AppCoordinator calls ProjectService at three key moments:

1. **Bootstrap** (`projects.defaultProject(workspaceID:)`) — to decide whether to onboard or land at home
2. **Onboarding project picker** (`projects.list(workspaceID:forceRefresh:)`) — to populate the picker
3. **Onboarding project create** (`projects.create(...)`) — to create a new project mid-onboarding

AppCoordinator also subscribes to `projects.changes` so the active project metadata refreshes if it changes (e.g., name updated from another device).

### 12.3 With Settings UI

Settings → Projects shows all projects (including archived in a collapsible section), with archive/unarchive actions and "Set as default" affordances. It uses the same `list(...)` and `archive(...)` methods.

---

## 12. Threading and Reentrancy

- Public methods are `async` and serialize through the actor
- HTTP calls are concurrent — they don't hold the actor — so multiple list calls for different workspaces can run in parallel
- The cache and inflight maps are actor-isolated; reads/writes are serialized
- `changes` continuation yields under actor isolation, ensuring strict ordering

### 13.1 Reentrancy concern: list during create

If a user taps "Create" and the project picker also kicks off a list refresh, both calls land on the actor. Each holds its own task. The list call may include or exclude the new project depending on whether create completed first. Both outcomes are valid; the cache is updated by whichever finishes last. This is benign because the create call always cache-appends and emits `projectCreated`, ensuring the UI sees the new project regardless of list timing.

---

## 13. Test Strategy

### 13.1 Unit Tests

- **Request builder:** URL composition (query parameters, path encoding), header construction, JSON body shape for each operation
- **Validation:** name and description edge cases (empty, oversize, special characters)
- **Cache:** TTL expiry, stale-while-revalidate behavior, in-flight dedup
- **Error mapping:** every documented HTTP status maps to expected `ProjectError` case; the App's `error` enum values map to the right typed cases (e.g., `project_name_taken` → `.duplicateName`)
- **Default project:** invalid ID gracefully clears; valid ID returns metadata
- **Idempotent create:** submitting the same `client_generated_id` twice returns the same `ProjectMetadata` (mock App returns 200 on the second call)

### 13.2 Integration Tests

- **End-to-end with mock App server:** local HTTP test server scripted to return success / 401 / 403 / 409 / 503; verify the right `ProjectError` propagates and the cache state is correct after each.
- **Real Databricks App (nightly):** end-to-end list/create/archive against a test deployment of the lakeLoom App; gated behind a `LAKELOOM_E2E=1` env var so PR CI doesn't depend on the App.
- **Concurrent creates:** two simulated clients submit the same name with *different* `client_generated_id`s — verify the App returns `409 project_name_taken` for the loser and iOS handles it gracefully.
- **Idempotent retry:** a single client submits the same `client_generated_id` twice — both succeed, second call returns the existing project.

### 13.3 Test Seams

```swift
protocol ProjectAPIClienting: Sendable { /* ... */ }
protocol AppEndpointResolving: Sendable { /* shared with Module 03 */ }
protocol DefaultsStore: Sendable { /* ... */ }
```

Production: `LiveProjectAPIClient`, `LiveAppEndpointResolver`, `LiveDefaultsStore`. Tests: `ScriptedProjectAPIClient`, `StubAppEndpointResolver`, `InMemoryDefaultsStore`.

---

## 14. Observability

- Log every API call at `debug` with operation name (e.g., `projects.list`), HTTP status, duration, response row count
- **Never log request body content or response project names** — they may contain sensitive customer info
- Log cache hits/misses at `trace` for development; off in release
- Counters in `ProjectServiceDiagnostics`:
  - `projects.list.total`, `projects.list.cached`
  - `projects.create.total`, `projects.create.duplicate`
  - `projects.archive.total`
  - `projects.app_errors.total` — non-network 4xx/5xx responses from the App
  - `cache.hit_rate`
- Per-call latency histograms for the diagnostics screen

---

## 15. Out of Scope for v1

- **Server-side default project storage.** Defaults are local to device.
- **Project sharing / permissions.** v1 visibility is "all workspace users see all workspace projects" via UC grants on the table.
- **Project-level tags / metadata.** The `metadata` VARIANT column exists but is unused in v1.
- **Pagination beyond 200 rows.** Search box is the v1 escape hatch. v1.x adds cursor pagination.
- **Optimistic UI for create.** Creates block until server-confirmed.
- **Project rename.** v1 is name-immutable. Need to delete and recreate, which the silver pipeline can stitch via a migration.
- **Real-time updates.** Polling-only via the 5-min cache TTL. No push.

---

## 16. Open Items

| # | Item | Resolution Path |
|---|---|---|
| 1 | Server-side storage: Lakebase Postgres vs Delta vs both — App's call, but iOS open item to confirm contract | Document the chosen backing in `architecture/hi_genie/`; iOS doesn't care which |
| 2 | App's exact error enum values (e.g., `project_name_taken`, `workspace_not_authorized`) | Lock the enum in `architecture/hi_genie/`; add to `ProjectError` mapping table |
| 3 | Whether the App returns the full updated project body on archive/restore (200 + body) or just 204 | v1 default: 204 No Content; iOS updates cache locally. Revisit if we need server-side computed fields. |
| 4 | Whether Settings should expose archived projects by default or as an explicit toggle | v1: collapsible section, hidden by default |
| 5 | Description field max length (2000 proposed) — confirm with users | Low-stakes; tune if it bites |
| 6 | Whether project list should be sorted by name alphabetically (alternative to updated_at desc) | v1: updated_at desc (recent first); offer name-sort toggle in v1.x |
| 7 | Search performance at scale — server-side `q=` filter behavior on >200 projects per workspace | v1: LIMIT 200 caps the impact. v1.x: cursor pagination + full-text search if needed |
| 8 | App authorization model — does the App enforce row-level visibility, or just workspace-level? | v1: workspace-level; all workspace members see all workspace projects. Revisit if customer security teams require per-team filtering. |

---

## 17. File Layout (proposed)

```
App/Projects/
├── ProjectService.swift                    // actor, public surface
├── ProjectServicing.swift                  // protocol + value types + ProjectError
├── ProjectChangeEvent.swift
├── ProjectMetadata.swift                   // shared value type used by AppCoordinator
├── ProjectValidator.swift
├── Cache/
│   ├── ProjectCache.swift
│   └── CacheEntry.swift
├── API/
│   ├── ProjectAPIClient.swift              // protocol
│   ├── LiveProjectAPIClient.swift          // URLSession-backed
│   ├── ScriptedProjectAPIClient.swift      // test impl
│   ├── CreateProjectPayload.swift          // Codable request body
│   ├── ProjectListResponse.swift           // Codable response body
│   ├── ProjectErrorResponse.swift          // App's error envelope
│   └── ProjectErrorMapper.swift            // HTTP status + error enum → ProjectError
└── Defaults/
    ├── DefaultsStore.swift                 // protocol
    ├── LiveDefaultsStore.swift             // UserDefaults-backed
    └── InMemoryDefaultsStore.swift
```

Tests mirror this layout under `AppTests/Projects/`.
