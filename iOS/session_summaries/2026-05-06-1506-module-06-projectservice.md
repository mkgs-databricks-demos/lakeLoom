# Session Summary — 2026-05-06 — Module 06 (ProjectService)

**Branch:** `feature/ios-module-06-projects` (off `main` at `7e4f653`)
**Author:** Matthew Giglia (with Claude Code / Isaac)
**Scope:** Implements Module 06 (`architecture/LakeLoomMarkdowns/module-06-project-service.md`) — the iOS REST client for the Databricks App's `/api/v1/projects` endpoints. Includes shared networking primitives (`UUIDv7`, `AppEndpoint`, `AppEndpointResolver`) under `App/Common/` that Modules 03 (IngestService) and 11 (AppSyncService) will reuse, the full `ProjectService` actor with cache + idempotent create + force-refresh-on-401, and 25 new tests.

This advances the visible-progress arc — together with Module 01 (Auth, already merged), Module 06 supplies the data the project-picker UI will consume once Module 05 (AppCoordinator + Onboarding) lands.

---

## Decisions made

### 1. Shared networking primitives belong in `App/Common/`

`UUIDv7`, `AppEndpoint`, and `AppEndpointResolver` are first-used here but consumed by Modules 03 and 11 too. Placing them under `App/Common/` instead of `App/Projects/` avoids the awkward "Module 03 imports from a Module 06 subfolder" arrangement. The single shared `AppEndpointResolver` actor also gives all three modules one cache to maintain (per-workspace, 7-day TTL) instead of each maintaining its own.

### 2. `LiveAppEndpointResolver` derives a structurally-correct placeholder URL

The Databricks App URL convention isn't settled yet — Genie Code will land on either `{workspaceURL}/serving-endpoints/<app>/invocations` or `https://<app>-<workspace>.databricksapps.com`. Until that decision lands in `architecture/hi_genie/`, the default `derive` closure returns `https://<host>/` (root URL) so the rest of the stack composes paths correctly. When Genie Code settles the convention, only the default closure changes — one line. The `derive: DeriveURL? = nil` init parameter lets tests inject any URL pattern they want without subclassing.

### 3. Idempotency keys are UUIDv7, generated client-side

Module 06 §7.4's `client_generated_id` is the App's idempotency key for `POST /api/v1/projects`. Using UUIDv7 (vs. random UUIDv4) gives us a time-ordered prefix the App can also use as a sort key on its Lakebase / Delta side. The fallback path in `UUIDv7.generate(now:)` (when `SecRandomCopyBytes` fails) drops to non-CSPRNG randomness but still preserves the time prefix — uniqueness is preserved by the timestamp + random combination.

### 4. `ProjectAPIClient` is stateless; `ProjectService` owns auth + endpoint context

Per Module 06 §4.1. The client takes `(token: AccessToken, endpoint: AppEndpoint)` on every call rather than holding them as state. ProjectService threads them through. This keeps the client trivially testable (no captured state to manage in mocks) and lets ProjectService compose the auth force-refresh-on-401 path cleanly.

### 5. Force-refresh-on-401 is implemented as a per-method retry

The protocol's `unauthorized` case bubbles up; ProjectService catches it in `list`, `fetch`, `create`, `archive`, and `unarchive`, calls `auth.currentToken(forceRefresh: true)`, and retries the same operation once with the rotated token. A second 401 propagates as `AuthError.refreshFailed` → `ProjectError.authFailed` (the user must sign in again).

The two refresh helpers (`retryAfterForceRefresh` for return-bearing operations; `retryArchiveAfterForceRefresh` for `Void` archive/unarchive) duplicate logic minimally because Swift's generic method limitations make sharing them awkward. Worth revisiting if a third return shape lands.

### 6. Stale-while-revalidate for the list cache

Module 06 §10.2. When `list(workspaceID:forceRefresh: false)` finds a stale-but-present cache entry, it returns the cached value immediately and kicks off a background refresh. The picker is instant; the data is at most 5 minutes old (the default TTL). Background refreshes emit `.listRefreshed` so subscribed view-models see the update.

`forceRefresh: true` skips the cache entirely. Pull-to-refresh in the picker should use this.

### 7. In-flight task dedup at the cache level

Concurrent `list(workspaceID:)` calls during a fetch share one network call via `ProjectCache.inFlightTask`. The first caller registers the task; subsequent callers `await` its `.value`. When the task completes (success or failure), it's cleared. This is the same pattern AuthService uses for token refresh dedup — load-bearing for race-free behavior under concurrent picker presentations.

### 8. `LiveDefaultsStore` is an actor, not a struct

Apple documents `UserDefaults` as thread-safe, but the type is non-Sendable in Swift 6 strict concurrency. Wrapping it in an actor satisfies the protocol without `@unchecked Sendable`. Reads and writes are sub-millisecond (UserDefaults is just a plist + cache), so the actor hop is invisible.

### 9. `ProjectMetadata` Codable maps camelCase ↔ snake_case via `CodingKeys`

The wire format the App emits uses snake_case (`project_id`, `workspace_id`, `created_by_user_id`, …). iOS uses camelCase. Rather than configuring a global `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase` (which would inadvertently apply to every other Codable type in the project), we declare explicit `CodingKeys` on `ProjectMetadata` and `CreateProjectPayload` / `ArchiveProjectPayload` / `ProjectErrorResponse`. Local discipline; no cross-module surprise.

### 10. Sequential event collection via a `Task<[Event], Never>` barrier

Swift 6 strict concurrency rejects sending an `AsyncIterator` across `async let` boundaries because the iterator is non-Sendable. The test that asserts on broadcast events spawns a `Task` that owns the iterator and collects the first N events; the test then awaits the task's value. Tasks are `Sendable` themselves, so this satisfies the checker. Pattern lives in `AppTests/Projects/ProjectServiceTests.swift` and will likely repeat in Modules 03 / 11.

---

## Work performed

7 commits on `feature/ios-module-06-projects`:

| Commit | Subject | Files |
|---|---|---|
| `754634f` | feat(common): UUIDv7, AppEndpoint, AppEndpointResolver | App/Common (4 files, +219) |
| `2e9d9c1` | feat(projects): public ProjectServicing protocol and value types | App/Projects core types (6 files, +251) |
| `f212719` | feat(projects): API contract types and ProjectAPIClient protocol | App/Projects/API (5 files, +253) |
| `7193d18` | feat(projects): LiveProjectAPIClient (URLSession + JSON) | LiveProjectAPIClient.swift (1 file, +222) |
| `37b9390` | feat(projects): DefaultsStore + ProjectValidator + ProjectCache | Defaults / Cache / Validator (6 files, +288) |
| `0d50768` | feat(projects): ProjectService actor (orchestrator) | ProjectService.swift (1 file, +443) |
| `fb964f0` | test(projects): unit tests for ProjectValidator, UUIDv7, ProjectService | AppTests/Projects (5 files, +806) |
| (this commit) | docs(session-summary): record 2026-05-06 Module 06 session | session_summaries/2026-05-06-1506-module-06-projectservice.md |

### Verification

```sh
$ xcodegen generate
Created project at .../iOS/LakeloomApp.xcodeproj

$ xcodebuild test -project LakeloomApp.xcodeproj -scheme LakeloomApp \
    -destination 'platform=iOS Simulator,name=iPhone 17'
…
✔ Test run with 117 tests in 31 suites passed after 0.260 seconds.
** TEST SUCCEEDED **
```

117 tests across 31 suites:
- 45 from Module 01 (auth) — still green
- 32 from Module 09 (telemetry) — still green
- 15 from Module 07 (persistence) — still green
- 25 new (projects):
  - ProjectValidator (9): name + description rules
  - UUIDv7 (5): format, version/variant bits, randomness, time ordering
  - ProjectService list (4): cache hit/miss, forceRefresh, 401 retry, 403 mapping
  - ProjectService create (4): validation gate, happy path with UUIDv7 payload, 409 mapping, cache update + event broadcast
  - ProjectService default (3): nil-when-unset, setDefault verifies first, clears stale on notFound

Plus the 1 LaunchTests UI test.

---

## Open items / followups

- **App URL convention**: `LiveAppEndpointResolver`'s default `derive` closure produces `https://<host>/` as a placeholder. Update once Genie Code settles the App URL pattern in `architecture/hi_genie/`.
- **Live REST end-to-end test** against a real Databricks App deployment — only useful once Genie Code has the App stood up. Gated behind a `LAKELOOM_E2E=1` env var when Module 10 §8 CI lands.
- **MetricsRegistry hookup**: ProjectService's local `diagnosticsState` counters duplicate what `MetricsCatalog` could capture via the registry. Mechanical refactor — defer until the diagnostics screen lands (Module 08).
- **Cache hit-rate computation**: `ProjectServiceDiagnostics.cacheHitRateLastHour` is declared but not computed (always `nil`). Trivial sliding-window count once a meaningful UI consumes it.
- **`firstAvailableProject` ordering**: returns the first non-archived project in the cached list, which is updated_at-desc per the App's response. Document explicitly in the protocol if AppCoordinator's bootstrap relies on a specific tie-break.
- **List pagination**: v1 caps at 200 rows + a search box (`q` parameter). Cursor pagination lands when a user has >200 projects in one workspace, per Module 06 §16.

---

## What's next

**Module 05 (AppCoordinator + Onboarding flow)** — the first runnable end-to-end demo. With Auth (01) and Projects (06) in place, AppCoordinator can sequence: cold start → recovery → consent → workspace URL → real OAuth → identity confirmation → project picker → home (with current project + workspace chips). It's a large module by surface area (Module 05 is 16 sections) but glues already-implemented pieces together, so the per-component cost is modest.

Alternative: **Module 02 (CaptureEngine)** — the hero feature. Big module though (audio engine + transcriber + Opus recorder + chunk assembler), so it makes sense after AppCoordinator has the permission-prompt + active-context plumbing it needs.

---

## What's not in this session

- No iOS source under any of the other module folders — they remain `.gitkeep` placeholders.
- No `ProjectService` hookup from `AppCoordinator` — that lands with Module 05.
- No SwiftUI views — Module 08 territory.
- No live REST test against a real Databricks App — only scripted-mock tests.
- No edits to `architecture/LakeLoomMarkdowns/`, `lakeLoom_infra/`, or anything outside `iOS/`.
