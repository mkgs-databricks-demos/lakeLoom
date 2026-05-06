# Module 06 — ProjectService

**Product:** Lakeloom
**Status:** Design — pre-implementation
**Last updated:** 2026-05-02
**Depends on:** AuthService (Module 01) for OAuth bearer tokens; shared HTTP client utilities
**Depended on by:** AppCoordinator (Module 05) for project picker and create flows; Settings UI for project management

---

## 1. Purpose

ProjectService is the iOS app's interface to the project metadata stored in Databricks. It owns:

- Listing available projects for a workspace (filtered by `archived = false`)
- Creating new projects from the iOS app
- Archiving projects (soft delete; never hard delete)
- Fetching a single project by ID
- Setting and retrieving the user's default project per workspace
- An in-memory cache with TTL to keep the project picker instant
- Bootstrapping the underlying Databricks table on first use (best-effort)
- The SQL Statement Execution API client used to talk to Databricks

ProjectService does **not** own the Unity Catalog table itself — Databricks does. It does not own user authentication — AuthService does. It does not own session-to-project association — that's done at session start by AppCoordinator embedding the project ID in the `CaptureRequest`.

The design tension here is that we have a row-level CRUD problem and Databricks gives us a SQL interface, not a REST/OData one. The SQL Statement Execution API is well-suited for this if we structure calls carefully — parameterized statements, small result sets, fast warehouses.

---

## 2. Design Principles

1. **Source of truth lives in Databricks.** The local cache is a UX optimization, never authoritative. Every write goes to Databricks first; the cache is updated from the response.
2. **Reads are cached aggressively.** Project lists rarely change during a session. A 5-minute in-memory TTL plus a "stale-while-revalidate" pattern keeps the UI instant.
3. **Writes are immediate and synchronous from the user's perspective.** Project creation must succeed against Databricks before the new project is selectable. No optimistic UI for v1.
4. **Parameterized SQL only.** All user-supplied values (project name, description) are passed as parameters to the SQL Statement Execution API, never interpolated into SQL strings.
5. **Soft delete only.** Archiving sets `archived = true`; nothing is ever physically deleted by the app. Operators can purge via Databricks if they want.
6. **Workspace isolation is enforced server-side, trusted client-side.** Unity Catalog grants determine what the user can see; the app filters by `workspace_id` for UX clarity, but a malicious app couldn't bypass UC to peek at another workspace's projects.
7. **Default project is a per-user, per-workspace UserDefaults key.** Storing this server-side would require another table; v1 keeps it local. Users on a new device pick a project at first capture.
8. **Schema bootstrap is best-effort.** The app attempts to create `main.lakeloom.projects` if missing on first use. If it fails (lack of CREATE TABLE permission), the app surfaces a clear error and points to admin-onboarding docs.
9. **Failures are typed.** Project errors propagate as a small enum that callers can pattern-match on.
10. **Listing is paginated but visually flat.** SQL returns all non-archived projects up to a 200-row cap; users with more than 200 projects per workspace get a search box (v1) and a server-side LIKE filter.

---

## 3. Public Surface

### 3.1 Protocol

```swift
protocol ProjectServicing: Sendable {
    /// Bring the service into a usable state. Lightweight — does not block on
    /// network. Heavy work (schema bootstrap, initial fetch) is deferred.
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
    case permissionDenied(reason: String)
    case schemaBootstrapFailed(reason: String)       // can't create the underlying table
    case sqlFailed(httpStatus: Int, reason: String)
    case warehouseUnavailable                        // user has no SQL warehouse
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
│  Project     │  │  SQL Statement │  │  Defaults Store  │
│  Cache       │  │  Execution     │  │  (UserDefaults   │
│  (in-memory, │  │  Client        │  │   for default    │
│   per-       │  │  (HTTP, OAuth, │  │   project per    │
│   workspace) │  │   parameter-   │  │   workspace)     │
│              │  │   ized)        │  │                  │
└──────────────┘  └────────────────┘  └──────────────────┘
                          │
                          ▼
                 ┌─────────────────┐
                 │ Schema Boot-    │
                 │ strapper        │
                 │ (CREATE TABLE   │
                 │  IF NOT EXISTS) │
                 └─────────────────┘
```

### 4.1 Concurrency Model

- `ProjectService` is a Swift `actor`. Public method calls serialize through it.
- The cache lives inside the actor; reads/writes are isolated.
- The SQL Statement Execution Client is a `Sendable` struct with no mutable state.
- The schema bootstrapper runs lazily, the first time any list or create call is made for a workspace, and only once per workspace per app launch.
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

## 5. SQL Statement Execution API Client

The client is a small HTTP wrapper around Databricks' `/api/2.0/sql/statements` endpoint. All ProjectService calls go through it.

### 5.1 Why Not the Tables API?

Databricks has REST endpoints for table management (`/api/2.1/unity-catalog/tables/...`) but no row-level CRUD endpoint. Row-level access is via:

1. **SQL Statement Execution API** — synchronous or async SQL via a SQL warehouse
2. **Statement Execution API with Serverless SQL** — same shape, faster cold starts
3. **REST/Delta Sharing** — read-only

For our use case, SQL Statement Execution against the user's serverless or pro SQL warehouse is the right tool.

### 5.2 API Surface

```swift
struct SQLStatementClient: Sendable {
    let auth: AuthServicing
    let httpClient: HTTPClient
    let warehouseResolver: WarehouseResolver

    func execute(
        statement: String,
        parameters: [SQLParameter] = [],
        workspaceID: String,
        timeout: Duration = .seconds(30)
    ) async throws -> SQLResult
}

struct SQLParameter: Sendable {
    let name: String
    let value: SQLValue
    let type: SQLType
}

enum SQLValue: Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case int(Int64)
    case timestamp(Date)
    case null
}

enum SQLType: String, Sendable {
    case string = "STRING"
    case boolean = "BOOLEAN"
    case bigint = "BIGINT"
    case timestamp = "TIMESTAMP"
}

struct SQLResult: Sendable {
    let columns: [SQLColumn]
    let rows: [[SQLValue]]
    let truncated: Bool
    let totalRowCount: Int64?
    let executionTimeMs: Int64
}

struct SQLColumn: Sendable {
    let name: String
    let typeName: String
    let typeText: String
}
```

### 5.3 Request Construction

```http
POST {workspaceURL}/api/2.0/sql/statements
Authorization: Bearer {accessToken}
Content-Type: application/json

{
  "statement": "SELECT project_id, project_name, description, workspace_id, created_by_user_id, created_by_username, created_at, updated_at, archived FROM main.lakeloom.projects WHERE workspace_id = :ws AND archived = false ORDER BY updated_at DESC LIMIT 200",
  "warehouse_id": "abc123",
  "parameters": [
    { "name": "ws", "value": "1234567890123456", "type": "STRING" }
  ],
  "wait_timeout": "30s",
  "on_wait_timeout": "CANCEL",
  "format": "JSON_ARRAY",
  "disposition": "INLINE"
}
```

Notes:

- **`wait_timeout: 30s` + `on_wait_timeout: CANCEL`** — synchronous mode. If the statement doesn't complete in 30s (warehouse cold start can be slow), we cancel and surface a "warehouse starting up, try again" error. v1 doesn't do async polling — too much complexity for project metadata.
- **`format: JSON_ARRAY`** — compact, easy to decode.
- **`disposition: INLINE`** — results in the response body, not external URLs. Project metadata is small (KB-scale); INLINE is appropriate.
- **`parameters`** — all user-supplied values use named parameters with explicit types. SQL injection is structurally impossible here.

### 5.4 Response Shape

```json
{
  "statement_id": "01abcdef-...",
  "status": { "state": "SUCCEEDED" },
  "manifest": {
    "format": "JSON_ARRAY",
    "schema": {
      "column_count": 9,
      "columns": [
        { "name": "project_id", "type_name": "STRING", "type_text": "STRING", "position": 0 },
        ...
      ]
    },
    "total_row_count": 23
  },
  "result": {
    "data_array": [
      ["proj_01975e4f...", "Customer 360 Lakehouse", "...", ...],
      ...
    ]
  }
}
```

### 5.5 Error States

The client maps Databricks error responses to typed errors:

| HTTP / SQL state | Mapped error |
|---|---|
| 401 | `AuthError.refreshFailed` (force-refresh, retry once) |
| 403 / `PERMISSION_DENIED` | `ProjectError.permissionDenied` |
| 404 (warehouse not found) | `ProjectError.warehouseUnavailable` |
| 400 / `INVALID_PARAMETER_VALUE` | `ProjectError.validationFailed` |
| 400 / SQL error mentioning UNIQUE / PRIMARY KEY | `ProjectError.duplicateName` (if creating; otherwise `sqlFailed`) |
| 408, 504, request cancelled | `ProjectError.timeout` |
| 500–503 | `ProjectError.sqlFailed(httpStatus:..., reason:...)` |
| Network error | `ProjectError.networkUnavailable` |

The SQL state field (`status.state`) is checked alongside HTTP status. If `state == "FAILED"`, the error message in `status.error.message` is parsed for known prefixes (`SCHEMA_NOT_FOUND`, `TABLE_OR_VIEW_NOT_FOUND`, etc.) to drive specific recovery paths.

---

## 6. Warehouse Resolution

Every SQL statement requires a `warehouse_id`. The user's app needs to know which warehouse to use.

### 6.1 Strategy

```swift
actor WarehouseResolver {
    private let auth: AuthServicing
    private let httpClient: HTTPClient
    private var cache: [String: ResolvedWarehouse] = [:]   // workspaceID → warehouse

    func resolve(workspaceID: String) async throws -> ResolvedWarehouse {
        if let cached = cache[workspaceID], !cached.isStale {
            return cached
        }
        let resolved = try await fetch(workspaceID: workspaceID)
        cache[workspaceID] = resolved
        return resolved
    }
}

struct ResolvedWarehouse: Sendable {
    let id: String
    let name: String
    let isServerless: Bool
    let resolvedAt: Date
    var isStale: Bool { Date().timeIntervalSince(resolvedAt) > 3600 }
}
```

### 6.2 Resolution Logic

The resolver tries, in order:

1. **User-pinned warehouse from Settings** — if the user has chosen one in app settings, use it
2. **The user's default warehouse** — fetch via `GET /api/2.0/sql/warehouses` and look at the user's `default_warehouse_id` in the response (if exposed) or pick by SCIM preference
3. **First running serverless warehouse** in the workspace
4. **First running pro warehouse** in the workspace
5. **First warehouse with `state = STOPPED`** — using this triggers a cold start; we surface "warehouse starting up" UI to the user

If no warehouses exist or the user lacks `CAN_USE` on any, throw `ProjectError.warehouseUnavailable` and surface admin-onboarding docs.

### 6.3 The Settings Path

Settings → Advanced → "SQL Warehouse" lets the user override the resolver. This is escape-hatch UX — most users never see it. Default is "Auto-select".

---

## 7. Schema Bootstrap

On first project list or create call against a workspace, ProjectService attempts to ensure the `main.lakeloom.projects` table exists.

### 7.1 The Bootstrap Statements

```sql
-- 1. Create the schema if missing.
CREATE SCHEMA IF NOT EXISTS main.lakeloom;

-- 2. Create the projects table if missing.
CREATE TABLE IF NOT EXISTS main.lakeloom.projects (
  project_id           STRING   NOT NULL,
  project_name         STRING   NOT NULL,
  description          STRING,
  workspace_id         STRING   NOT NULL,
  created_by_user_id   STRING   NOT NULL,
  created_by_username  STRING   NOT NULL,
  created_at           TIMESTAMP NOT NULL,
  updated_at           TIMESTAMP NOT NULL,
  archived             BOOLEAN  NOT NULL DEFAULT false,
  metadata             VARIANT,
  CONSTRAINT projects_pk PRIMARY KEY (project_id) RELY
)
USING DELTA
TBLPROPERTIES (
  'delta.feature.allowColumnDefaults' = 'supported',
  'delta.columnMapping.mode' = 'name'
);

-- 3. Ensure index on workspace_id for our LIST queries.
--    Delta uses Z-order rather than B-tree indexes; we add a stats hint.
ALTER TABLE main.lakeloom.projects
  SET TBLPROPERTIES ('delta.dataSkippingNumIndexedCols' = '4');
```

### 7.2 Bootstrap Lifecycle

```swift
private var bootstrappedWorkspaces: Set<String> = []
private var bootstrapTasks: [String: Task<Void, Error>] = [:]

private func ensureBootstrapped(workspaceID: String) async throws {
    if bootstrappedWorkspaces.contains(workspaceID) { return }
    if let task = bootstrapTasks[workspaceID] {
        try await task.value
        return
    }
    let task = Task<Void, Error> { [weak self] in
        try await self?.runBootstrap(workspaceID: workspaceID)
    }
    bootstrapTasks[workspaceID] = task
    do {
        try await task.value
        bootstrappedWorkspaces.insert(workspaceID)
        bootstrapTasks[workspaceID] = nil
    } catch {
        bootstrapTasks[workspaceID] = nil
        throw error
    }
}
```

The schema bootstrap is a one-shot per app launch. If the user's principal lacks `CREATE SCHEMA` or `CREATE TABLE` privileges, the bootstrap fails and we throw `ProjectError.schemaBootstrapFailed` with a helpful message pointing to admin docs.

### 7.3 Permission Failure Path

```
SQL error: PERMISSION_DENIED: User does not have CREATE TABLE on schema main.lakeloom
```

The app surfaces a one-time onboarding error explaining:

- The app needs a Databricks workspace admin to run the schema setup script once
- A link to a hosted setup script (markdown doc + SQL file)
- An "I'll handle this later" option that defers and shows an empty project picker (with a prominent "Setup required" banner)

This is the path most enterprise customers will hit — workspace admins control DDL permissions tightly. The setup script can be run by an admin in the Databricks SQL editor in 30 seconds.

> **Open item:** consider whether the schema and table should live in `main.lakeloom.*` (shared across all users in the workspace, requiring admin DDL) or in `users.<user>.lakeloom.*` (per-user schema, only requires the user's own privileges). v1 uses the shared schema; flagged for revisit if admin-friction is high.

---

## 8. Operations — SQL Templates

All operations use parameterized SQL.

### 8.1 List

```sql
SELECT
  project_id,
  project_name,
  description,
  workspace_id,
  created_by_user_id,
  created_by_username,
  created_at,
  updated_at,
  archived
FROM main.lakeloom.projects
WHERE workspace_id = :ws
  AND archived = false
ORDER BY updated_at DESC
LIMIT 200
```

### 8.2 List With Search

```sql
SELECT ...
FROM main.lakeloom.projects
WHERE workspace_id = :ws
  AND archived = false
  AND (
    LOWER(project_name) LIKE LOWER(:query)
    OR LOWER(COALESCE(description, '')) LIKE LOWER(:query)
  )
ORDER BY updated_at DESC
LIMIT 200
```

`:query` is bound as `%user-input%`. The wildcards are added client-side, after escaping any `%` or `_` in the user input.

### 8.3 Fetch by ID

```sql
SELECT ...
FROM main.lakeloom.projects
WHERE project_id = :id AND workspace_id = :ws
LIMIT 1
```

### 8.4 Create

```sql
INSERT INTO main.lakeloom.projects (
  project_id,
  project_name,
  description,
  workspace_id,
  created_by_user_id,
  created_by_username,
  created_at,
  updated_at,
  archived
) VALUES (
  :id,
  :name,
  :description,
  :ws,
  :uid,
  :username,
  :now,
  :now,
  false
)
```

The `:id` is generated client-side (UUIDv7 from the shared utility). All timestamp values use `:now` (a `TIMESTAMP` parameter) — using server time is harder via the Statement Execution API, and client time is good enough given drift expectations.

After insert, the client returns the input values as the canonical `ProjectMetadata`. We do not re-`SELECT` to verify — the parameter values are authoritative since insertion succeeded with them.

### 8.5 Pre-insert Duplicate Check

A separate `SELECT` runs before the `INSERT` to catch duplicate names:

```sql
SELECT project_id
FROM main.lakeloom.projects
WHERE workspace_id = :ws
  AND LOWER(TRIM(project_name)) = LOWER(TRIM(:name))
  AND archived = false
LIMIT 1
```

If a row is returned, throw `ProjectError.duplicateName(existingProjectID:)`. The check + insert is two round trips — there's a tiny race window where two devices could both pass the check and both insert. v1 accepts this; collision is rare and the silver pipeline / Agent can ignore one of the duplicates if needed.

### 8.6 Archive / Unarchive

```sql
UPDATE main.lakeloom.projects
SET archived = :archived, updated_at = :now
WHERE project_id = :id AND workspace_id = :ws
```

We do not check pre-update existence; if no rows are updated (e.g., wrong workspace), we throw `notFound`.

---

## 9. Validation

Project name validation runs client-side before any SQL call:

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

## 10. Caching Strategy

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
        try await self.ensureBootstrapped(workspaceID: workspaceID)
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

## 11. Default Project

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

## 12. Integration Points

### 12.1 With AuthService

ProjectService calls `auth.currentToken()` before every SQL Statement Execution API call. The token is included as the `Authorization: Bearer ...` header. On 401, ProjectService calls `auth.currentToken(forceRefresh: true)` and retries once — same pattern as IngestService and StorageService.

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

## 13. Threading and Reentrancy

- Public methods are `async` and serialize through the actor
- HTTP calls are concurrent — they don't hold the actor — so multiple list calls for different workspaces can run in parallel
- The cache and inflight maps are actor-isolated; reads/writes are serialized
- The schema bootstrap dedupes via the `bootstrapTasks` map, similar to AuthService's refresh dedup
- `changes` continuation yields under actor isolation, ensuring strict ordering

### 13.1 Reentrancy concern: list during create

If a user taps "Create" and the project picker also kicks off a list refresh, both calls land on the actor. Each holds its own task. The list call may include or exclude the new project depending on whether create completed first. Both outcomes are valid; the cache is updated by whichever finishes last. This is benign because the create call always cache-appends and emits `projectCreated`, ensuring the UI sees the new project regardless of list timing.

---

## 14. Test Strategy

### 14.1 Unit Tests

- **SQL builder:** parameter binding, escaping, type coercion for each query
- **Validation:** name and description edge cases (empty, oversize, special characters)
- **Cache:** TTL expiry, stale-while-revalidate behavior, in-flight dedup
- **Schema bootstrapper:** dedup across concurrent calls; permission denial maps to typed error
- **Error mapping:** every documented HTTP/SQL error case maps to expected `ProjectError`
- **Default project:** invalid ID gracefully clears; valid ID returns metadata

### 14.2 Integration Tests

- **Real Databricks workspace:** end-to-end list/create/archive against a test workspace
- **Cold warehouse:** verify "warehouse starting up" UX
- **Concurrent creates:** two simulated devices creating the same name within the race window — both succeed; document this behavior
- **Schema setup:** install in a fresh schema; verify table and constraints

### 14.3 Test Seams

```swift
protocol SQLStatementExecuting: Sendable { /* ... */ }
protocol HTTPClient: Sendable { /* ... */ }
protocol DefaultsStore: Sendable { /* ... */ }
```

Production: `LiveSQLStatementClient`, `LiveHTTPClient`, `LiveDefaultsStore`. Tests: `ScriptedSQLClient`, `MockHTTPClient`, `InMemoryDefaultsStore`.

---

## 15. Observability

- Log every SQL call at `debug` with statement template name (not the raw SQL), parameter count, duration, row count
- **Never log parameter values** — project names may contain sensitive customer info
- Log cache hits/misses at `trace` for development; off in release
- Counters in `ProjectServiceDiagnostics`:
  - `sql.list.total`, `sql.list.cached`
  - `sql.create.total`, `sql.create.duplicate`
  - `sql.archive.total`
  - `bootstrap.attempted`, `bootstrap.failed`
  - `cache.hit_rate`
- Per-call latency histograms for the diagnostics screen

---

## 16. Out of Scope for v1

- **Server-side default project storage.** Defaults are local to device.
- **Project sharing / permissions.** v1 visibility is "all workspace users see all workspace projects" via UC grants on the table.
- **Project-level tags / metadata.** The `metadata` VARIANT column exists but is unused in v1.
- **Pagination beyond 200 rows.** Search box is the v1 escape hatch. v1.x adds cursor pagination.
- **Optimistic UI for create.** Creates block until server-confirmed.
- **Project rename.** v1 is name-immutable. Need to delete and recreate, which the silver pipeline can stitch via a migration.
- **Real-time updates.** Polling-only via the 5-min cache TTL. No push.

---

## 17. Open Items

| # | Item | Resolution Path |
|---|---|---|
| 1 | Schema location: shared `main.lakeloom.*` (admin DDL) vs per-user `users.<user>.lakeloom.*` (less friction) | Spike: how often will admins balk? Default to shared for v1; revisit |
| 2 | Whether to use serverless SQL warehouse exclusively (faster cold start) or fall back to user's pro warehouse | Default to user's preference; document admin guidance |
| 3 | Default warehouse_id source — user's SCIM preference vs first-running vs explicit setting | Likely a small precedence ladder; document and test |
| 4 | Two-step create (check + insert) race window — accept or address with MERGE | v1: accept. v1.x: consider `MERGE ... WHEN NOT MATCHED THEN INSERT` if Delta supports it for our pattern |
| 5 | Whether Settings should expose archived projects by default or as an explicit toggle | v1: collapsible section, hidden by default |
| 6 | Description field max length (2000 proposed) — confirm with users | Low-stakes; tune if it bites |
| 7 | Whether project list should be sorted by name alphabetically (alternative to updated_at desc) | v1: updated_at desc (recent first); offer name-sort toggle in v1.x |
| 8 | Search performance at scale — LIKE on string columns is slow at very high row counts | v1: LIMIT 200 caps the impact. v1.x: full-text search if needed |
| 9 | Permission check before showing "Create" button — does the user have INSERT on the table? | v1: try and surface error. v1.x: pre-check via `SHOW GRANTS` |

---

## 18. File Layout (proposed)

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
├── SQL/
│   ├── SQLStatementClient.swift            // protocol
│   ├── LiveSQLStatementClient.swift
│   ├── ScriptedSQLClient.swift             // test impl
│   ├── SQLStatement.swift                  // value types
│   ├── SQLStatements.swift                 // Catalog of SQL templates
│   ├── SQLResultDecoder.swift
│   ├── SQLErrorMapper.swift
│   └── ProjectMetadataMapper.swift         // SQLResult → [ProjectMetadata]
├── Warehouse/
│   ├── WarehouseResolver.swift
│   ├── ResolvedWarehouse.swift
│   └── WarehouseListResponse.swift
├── Bootstrap/
│   ├── SchemaBootstrapper.swift
│   └── BootstrapStatements.swift
└── Defaults/
    ├── DefaultsStore.swift                 // protocol
    ├── LiveDefaultsStore.swift             // UserDefaults-backed
    └── InMemoryDefaultsStore.swift
```

Tests mirror this layout under `AppTests/Projects/`.
