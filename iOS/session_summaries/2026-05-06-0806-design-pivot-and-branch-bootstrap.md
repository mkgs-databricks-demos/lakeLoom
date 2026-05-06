# Session Summary — 2026-05-06 — Design pivot and branch bootstrap

**Branch:** `feature/ios-bootstrap`
**Author:** Matthew Giglia (with Claude Code / Isaac)
**Scope:** First working session on the lakeLoom iOS app. No iOS code yet — this session aligned the architecture docs with newly-locked-in design rules and established the working conventions for everything that follows.

---

## Context

The repo (`mkgs-databricks-demos/lakeLoom`) opened with a substantial design corpus already in place: an `ios-app-architecture.md` overview plus 10 module specs covering Auth, Capture, Ingest, Storage, AppCoordinator, Projects, Persistence, UI, Telemetry, and Build/Test. A `lakeLoom_infra/` Declarative Automation Bundle skeleton was also present, owned by Genie Code (the Databricks built-in coding assistant) for the Databricks-side build.

Goal of this session: confirm scope, settle a handful of architectural decisions that hadn't been committed yet, and get the docs to reflect those decisions so the iOS implementation can begin against accurate specs.

---

## Decisions locked in

### 1. Division of labor — Claude Code vs Genie Code

- **Claude Code** owns the **iOS app and its integration glue** (Swift/SwiftUI build, on-device STT, network calls to the Databricks App, UC Volume audio upload, reading App-mediated Lakebase data into iOS views).
- **Genie Code** owns the **Databricks workspace side** — the Databricks App agent itself, the Spark Declarative Pipeline, Agent Bricks for the requirements/architecture/Genie-Code-session-plan generation, and the Declarative Automation Bundle that ties it all together.
- Cross-agent communication is via two markdown drop folders inside `architecture/`:
  - `architecture/hi_genie/` — Claude Code → Genie Code (write-allowed for Claude Code)
  - `architecture/hey_isaac/` — Genie Code → Claude Code (read-only for Claude Code)

**Why:** clean separation by which tool has the better grasp of each layer. Genie Code is more native to Databricks; Claude Code is better suited to iOS/Swift work. Treat the boundary as a contract — design clear shapes (Zerobus protos, Lakebase tables, REST endpoints), stop at the wire, let each tool implement its own side.

### 2. Transport for ingest — gRPC → REST proxy

The earlier Module 03 design called for `grpc-swift` posting directly to Zerobus from iOS. Pivoted to: iOS POSTs JSON to a REST endpoint exposed by the Databricks App, and the App owns the Zerobus TS SDK call server-side.

**Why:**
- Single network boundary on iOS — HTTPS to one host instead of HTTPS + gRPC + TLS-pinned-Zerobus.
- Decoupling — Zerobus IDL changes server-side without iOS App Store updates.
- Tooling cost — no `grpc-swift` + `swift-protobuf` dependency, no codegen, smaller binary, faster builds.
- Operational consistency with the audio-upload and project-metadata paths.
- Precedent: dbxWearables already runs the Zerobus TS SDK on the Databricks App side and accepts HTTP POSTs from iOS for HealthKit data.

### 3. STT engine — keep Module 02's existing design

Earlier in conversation I proposed WhisperKit-small for live STT. After reading the existing Module 02 spec, recommended **keeping the existing design**:
- **Live STT:** Apple's iOS 26 `SpeechAnalyzer` / `SpeechTranscriber` — free, on-device, no model bundle hit, native API.
- **Post-upload re-transcription:** WhisperKit-small (or larger) on the Databricks side, run against the uploaded audio file for higher fidelity on technical jargon. v1.x feature.

**Why:** Best of both worlds. SpeechAnalyzer is the right hammer for the live case (low latency, free, no 250 MB CoreML model in the bundle). WhisperKit gives us a quality re-pass on the audio that's already being uploaded for archival anyway. The existing Module 02 design already plans this path; our verbal direction was overridden by the existing-doc design after re-reading it.

### 4. Lakebase access rule — via App REST API only

**Locked rule:** "Lakebase, accessed via the Databricks App's REST API, never directly from iOS."

The user's directional preference is "Lakebase as the rule of thumb" for storage. Confirmed Swift has a viable Postgres client (`PostgresNIO`), but recommended against direct iOS-to-Postgres for four reasons:
1. Lakebase OAuth credential generation is naturally server-side (`generate_lakebase_credential`) — doing it from iOS adds credential rotation surface.
2. Schema coupling — a Lakebase column rename shouldn't require an App Store update.
3. Mobile network reality — `URLSession` handles drops/suspends/interface switches that stateful Postgres TCP doesn't.
4. Security blast radius — easier to scope an HTTP endpoint than per-user DB credentials.

The "Lakebase rule of thumb" is preserved; iOS just reaches Lakebase *through* the App's TS API rather than directly. iOS has exactly one network boundary: HTTPS to the Databricks App.

### 5. New scope — Module 11 (App Sync) for Brickster→iOS edits

The original Module 01–10 design covered iOS-as-producer only. New scope captured: when a Databricks employee opens the lakeLoom App in a browser after a session and edits annotations, project metadata, or generated artifacts, those changes need to surface back to iOS. Captured as Module 11 — `AppSyncService`, cursor-based polling against `GET /api/v1/sync/changes?since=...` in v1, with APNs nudges + WebSocket as the v1.x upgrade path that doesn't change the consumer contract.

### 6. Authentication model

OAuth 2.0 U2M with PKCE via `ASWebAuthenticationSession`. Refresh tokens in Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). Automatic refresh on 401. **Never service principals on iOS.** Each user is a member of the target Databricks workspace and authenticates as themselves.

### 7. Working agreements (durable, not just this session)

- **Feature branches**, never direct to `main`. This session: `feature/ios-bootstrap`.
- **Commit + push often** with thoughtful messages explaining the *why*, not just the *what*.
- **Edit scope:** only `architecture/hi_genie/` and `iOS/`. `architecture/LakeLoomMarkdowns/` and `lakeLoom_infra/` are user/Genie territory and require explicit per-change approval.
- **Session summary** (this document) before every PR, in `iOS/session_summaries/YYYY-MM-DD-HHMM-short-title.md`.
- **Polish + best practice as the default.** "MVP" means a vertical slice with full quality (Swift 6 strict concurrency, accessibility, Dynamic Type, snapshot tests, design-system tokens), not a horizontal scaffold with TODOs.

---

## Work performed

All commits on `feature/ios-bootstrap`, branched from `main`:

| Commit | Subject | Notes |
|---|---|---|
| `7ac5ba9` | docs(module-03): pivot Zerobus client from gRPC to REST proxy | Largest doc change. `ZeroBusClient` → `IngestProxyClient`; full Section 7 rewrite as URLSession + JSON. Outbox / drainer / retry / recovery design preserved. |
| `3debbbb` | docs(module-06): pivot from SQL Statement Execution to App REST API | Drops Warehouse Resolution + Schema Bootstrap entirely (App-side concerns now). Public `ProjectServicing` protocol unchanged. Idempotent create via `client_generated_id`. |
| `f5c4546` | docs(module-11): add App Sync module for Brickster→iOS edits | New 540-line module. Cursor-based polling, change-event model, v1.x push upgrade path. Reuses `BackoffPolicy` and `Reachability` from Module 03. |
| `ffb58bc` | docs(ios-arch): reflect REST-proxy + Lakebase + single-boundary rules | Overview doc updates: Project Overview prelude, Section 9 (Ingest Client), Section 7 (Project Management), Key Design Decisions table additions (rows 14–17). |
| `cbfeb74` | docs(module-10): drop grpc-swift / swift-protobuf SPM dependencies | Follow-up cleanup after the Module 03 transport pivot. Also added `PostgresNIO` to "what we are NOT using." |
| `c54e899` | chore: establish iOS/ directory with .gitkeep | Reserves the iOS folder root for the Xcode project that lands next session. |

Six commits, six pushes. Branch is up to date with origin and ready for review.

---

## Memory updates (Claude Code's persistent memory)

Saved or updated to keep the working context coherent across future sessions:
- Project memory `project_lakeloom.md` — repo + scope + 12-markdown corpus.
- Feedback `feedback_lakeloom_scope.md` — scope split between Claude Code and Genie Code.
- Feedback `feedback_lakeloom_auth.md` — OAuth 2.0 U2M only on iOS, never SPNs.
- Feedback `feedback_lakeloom_lakebase_rule.md` — Lakebase via App REST API, never direct.
- Feedback `feedback_lakeloom_workflow.md` — feature branch / commit cadence / edit scope / session-summary discipline.
- Feedback `feedback_polish_default.md` — best-practice + polish out of the gate.
- User memory `user_role.md` — updated to reflect FDE Core Team role and the rapid-MVP engagement model that lakeLoom serves.

---

## Open items / followups

Owed to Genie Code (will land in `architecture/hi_genie/` next session):

1. **HTTP/JSON contract for ingest** — `POST /api/v1/ingest/snippets` request body shape, `IngestBatchAck` response shape, exact `rejected[].reason` enum values, partial-accept semantics (HTTP 207).
2. **HTTP/JSON contract for projects** — `GET/POST/PATCH /api/v1/projects` shapes; the App's error envelope (`error`, `message`, `existing_project_id`); idempotency-key handling for `client_generated_id`.
3. **HTTP/JSON contract for sync** — `GET /api/v1/sync/changes?since=...` request/response, the cursor format (opaque), the `change_kind` enum vocabulary for v1.
4. **Lakebase tables iOS expects to read (via the App)** — annotations, project_updates, session_status, generated artifacts. iOS doesn't see the schema, but the contract documents what the App must surface.
5. **App endpoint URL convention** — `/serving-endpoints/<name>/invocations` vs Databricks Apps URL (`https://<app>-<workspace>.databricksapps.com`). iOS-side `EndpointResolver` needs this to be deterministic.

Owed by iOS (next sessions):

- Scaffold the Xcode project under `iOS/` per Module 10's layout: `LakeloomApp.xcodeproj`, `App/` (with module folders mirroring the design), `AppTests/`, `AppUITests/`, `BuildScripts/`, SwiftPM dependencies (no gRPC), `Package.resolved`, `.swiftlint.yml`, `.swift-format`, `Makefile`, `README.md`.
- Module 01 (AuthService) implementation — actor + protocols + OAuth flow + Keychain layer + tests.
- Wire the existing `feature/ios-bootstrap` branch into a draft PR once the Xcode project + Module 01 are in place.

---

## What's not in this session

- No iOS source code — only design alignment.
- No edits to `architecture/LakeLoomMarkdowns/` other than the four approved updates (Modules 03, 06, 10, 11, plus the iOS architecture overview).
- No edits to `lakeLoom_infra/` — that's Genie Code's territory.
- No PR opened yet — branch is pushed and ready, but holding for the iOS scaffold to land before requesting review, per the session-summary-before-PR rule.
