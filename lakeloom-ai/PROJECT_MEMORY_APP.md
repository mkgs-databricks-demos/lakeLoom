# lakeLoom Project Memory

## Purpose

Shared durable context for the **lakeLoom** solution — spans both `lakeloom-infra` and `lakeloom-ai` bundles.
Used when global `.assistant_instructions.md` is unavailable from a particular editing scope.

## Collaboration Conventions

### Isaac collaboration folders

* `hi_genie/` is read-only context from Isaac — lives at `lakeLoom/architecture/hi_genie/`.
* Always read `hi_genie/` for relevant project context before substantive work.
* Never write to `hi_genie/`, any subfolder inside it, or any file within it.
* Reply to Isaac, share progress, or record decisions in `lakeLoom/architecture/hey_isaac/` (sibling to `hi_genie/`).
* Both folders live under `lakeLoom/architecture/`, NOT inside individual bundle directories.
* Genie is the source of truth for Databricks-related decisions; Isaac = non-Databricks domains (Xcode, Apple platforms).

## Project Structure

```
lakeLoom/
├── PROJECT_MEMORY.md               # This file (shared between bundles)
├── deploy.sh                       # Unified deployment script
├── architecture/
│   ├── hi_genie/                   # Read-only context from Isaac
│   └── hey_isaac/                  # Outbound messages to Isaac
│   └── LakeLoomMarkdowns/          # Module design specs (01–11)
├── lakeloom-infra/
│   ├── databricks.yml              # Bundle config, variables, targets
│   ├── README.md
│   ├── resources/
│   │   ├── lakeloom.schema.yml
│   │   ├── session_audio.volume.yml
│   │   ├── screenshots.volume.yml
│   │   ├── documents.volume.yml
│   │   ├── lakeloom.secret_scope.yml
│   │   ├── infra_warehouse.sql_warehouse.yml
│   │   ├── lakeloom.lakebase.yml
│   │   └── platform_bootstrap.job.yml
│   ├── src/
│   │   ├── lib/                    # Reusable Python modules
│   │   │   ├── __init__.py
│   │   │   ├── workspace_metadata.py
│   │   │   ├── service_principal.py
│   │   │   └── secret_scope.py
│   │   ├── platform_bootstrap/     # NOTEBOOK task implementations
│   │   │   ├── ensure-service-principal
│   │   │   ├── stt-0bus-target-table-ddl
│   │   │   ├── grant-volume-access
│   │   │   └── validate-platform
│   │   └── admin_actions/          # Manual admin notebooks
│   │       ├── set-databricks-secrets
│   │       └── update-secrets-acls
│   └── fixtures/
│       └── sessions/               # Infra session summaries
├── lakeloom-ai/
│   ├── databricks.yml              # App bundle config
│   ├── app.yaml                    # Databricks App runtime manifest (command, env vars)
│   ├── package.json                # Node.js dependencies (AppKit 0.36.0, React 19, Zod, ZeroBus SDK)
│   ├── server/                     # Express API (TypeScript)
│   │   ├── server.ts              # Entry: secrets → migrations → routes → serve
│   │   ├── lib/                   # crypto.ts, errors.ts (RFC 9457)
│   │   ├── middleware/            # ios-auth.ts, browser-auth.ts + dualAuth()
│   │   ├── migrations/            # 001–019 (paired_sessions → sweeper_runs)
│   │   ├── services/              # secrets, sse, zerobus stream pool
│   │   └── routes/                # pairing, captures, uploads, events, projects, media, zerobus
│   ├── client/                     # React frontend (Vite + Tailwind v4)
│   │   ├── src/                   # App.tsx, pages/, components/media/
│   │   └── public/                # Favicons, manifest
│   ├── shared/appkit-types/        # Shared TypeScript types
│   ├── patches/zerobus-ingest-sdk/ # SDK patch (index.js, index.d.ts)
│   ├── scripts/                    # patch-zerobus-sdk.mjs
│   ├── tests/smoke.spec.ts         # Playwright smoke test
│   ├── src/tests/lib/              # Shared test utilities (PairingTestClient)
│   ├── resources/                  # App resource definitions
│   │   ├── lakeloom_ai.app.yml
│   │   ├── configure_app_spn.job.yml
│   │   ├── post_deploy_validation.job.yml
│   │   ├── update_secrets_acls.job.yml
│   │   └── orphan_byte_sweeper.job.yml
│   └── fixtures/
│       ├── sessions/               # App session summaries
│       └── databricks-app-ui-plan.md  # Browser UI feature plan
├── iOS/                            # Native iOS client (Xcode, Swift)
│   ├── project.yml, Makefile, Brewfile
│   ├── App/                        # Swift sources (Auth, Coordinator, Projects, Persistence, Telemetry, Views)
│   ├── AppTests/                   # Unit tests
│   └── session_summaries/
```
## App Bundle (lakeloom-ai)

* **Purpose:** Databricks AppKit application — requirements capture, architecture design, and Genie Code session planning for rapid Databricks MVPs.
* **App name (dev):** `lakeloom-ai-dev`
* **Compute:** Medium AppKit container
* **Source path:** `/Workspace/Users/matthew.giglia@databricks.com/.bundle/lakeloom-ai/dev/files`
* **SDK version:** `@databricks/sdk-experimental` 0.17.0 (upgraded from 0.14.2 on 2026-05-20)
* **deploy.sh** handles end-to-end: infra validation → readiness checks → bundle deploy → app source push.
* **Runtime variables passed via `--var`:** `xcode_spn_id` (discovered from secret scope at deploy time).
* All other values (catalog, schema, warehouse ID, Lakebase IDs) use target defaults in `databricks.yml`.

## Current Infra Status

* Both bundles fully deployed to **dev** target. `platform_bootstrap` job runs successfully (all **4 tasks** pass).
* `deploy.sh --target dev --app` deploys app bundle end-to-end (validated 2026-05-13).
* Latest successful run: **2026-05-12** — validates schema, all 3 managed volumes, volume grants (via `information_schema.volume_privileges`), and bronze table.
* Job now uses a **forEach task** to apply volume grants across all 3 volumes in parallel (concurrency: 3).
* `resources/uc_setup.job.yml` was **deleted** (empty legacy file, superseded by `platform_bootstrap.job.yml`).
* Source code reorganized: all task logic lives in NOTEBOOK objects; reusable functions in `src/lib/`.
* **No plain `.sql` files** outside of SDP. SQL logic lives in SQL-default NOTEBOOK objects.
* NOTEBOOK objects are always referenced as `.ipynb` in job YAML. The `warehouse_id` field determines SQL compute routing, not the file extension.
* `src/lib/secret_scope.py` — named to avoid collision with Python stdlib `secrets` module.
* **Isaac notified** (2026-05-12) about `screenshots` and `documents` volumes via `lakeLoom/architecture/hey_isaac/2026-05-12_new-upload-volumes.md`.
* **Isaac notified** (2026-05-13) about pairing endpoint contract via `lakeLoom/architecture/hey_isaac/2026-05-13_pairing-auth-endpoints-live.md`. Covers: Layer 1/2 auth headers, POST /confirm contract, QR payload structure, error format, open questions (device_label, pubkey encoding, filename convention).
* **2026-05-15: QR pairing validated end-to-end on physical iPhone.** Full chain: QR scan → M2M → confirm → device-key binding → project create → home screen. iOS Module 01 merged (PR #18). Collaboration model (hi_genie/hey_isaac) proven effective for cross-domain debugging.
* **2026-05-20: First successful upload (audio).** Both blocking bugs fixed (iosAuth invocation + SDK 0.17 signatures). Upload confirmed in `lb_uploads_history`. Isaac notified via `hey_isaac/2026-05-20_audio-uploads-working.md`.
* **2026-05-23: Migrations 009/010 deployed.** `client_type` on uploads (server-determined), `username` on paired_sessions (from `x-forwarded-email` at QR gen). Shared `PairingTestClient` module replaces duplicated test boilerplate. Lakehouse Sync schema mismatch fixed via Delta `ALTER TABLE ADD COLUMN`.
* **2026-05-24: iOS auth hardening + device assignment backfill.** Migration 012 remediates 55 projects misattributed to SPN (→ human SCIM ID). Migration 013 backfills `project_device_assignments` from `capture_sessions` (5 rows). `browserAuth()` hardened to reject bare SPN requests (requires `X-Forwarded-Email`). `project-routes.ts` auto-assigns device on iOS project creation (when `req.user.sessionId` present). Phase 2 UI fully COMPLETE (sort toggle, inline label editing, empty state CTA shipped same day).
* **2026-05-24: Phase 3 — Media Viewer & Audio Playback COMPLETE on branch `gc-phase3-browser-ui`.**
* **2026-05-25: Phase 4 — Browser Uploads COMPLETE on branch `mg-phase3-cleanup`.** Server streaming (5 GB), client DragDropZone + progress pool, expanded MIME types (PDF/DOCX/PPTX/Markdown/PNG/JPEG), delete, markdown viewing/editing, MIME-aware icons, original filename capture from browser FormData, backfill migration 015, CDF pipeline prep (migration 016: `updated_at`, PUT handler sha256). 14 commits, zero conflicts with main (iOS-only PRs #62–#67 merged since branch point).
  * Server: `server/routes/media/media-routes.ts` adds 3 endpoints — `GET /api/media/:upload_id` (stream with Range support + strict 206 handling), `GET /api/media/:upload_id/metadata`, `GET /api/media/session/:capture_session_id`.
  * Client media components: `AudioPlayer` (HTML5 audio, static waveform, speed control), `ImageViewer` (thumbnail + lightbox zoom), `DocumentViewer` (PDF iframe inline, DOCX download fallback), `MediaPanel` (dispatch by MIME type), `MediaModal` (shared `<dialog>` modal wrapper).
  * `CaptureDetailPage.tsx`: upload clicks open `MediaModal` instead of inline preview; no auto-select on load.
  * `ProjectDetailPage.tsx`: project-level documents open in the same `MediaModal` instead of new tabs.
  * `ConfirmDialog.tsx`: fixed native dialog positioning/visibility via `hidden open:grid`; centered reliably with `showModal()`.
  * `client/src/index.css`: added missing `fadeIn` / `scaleIn` keyframes and motion CSS variables.
  * Capture session list cards now show media-type icons (audio, photo, document).
  * **Critical audio lesson:** never wrap a 200 upstream media response as synthetic 206. Strictly proxy 206 only when upstream is actually 206, or browsers reject playback.
  * **Critical dialog lesson:** native `<dialog>` + Tailwind `grid` requires `hidden open:grid` or the element becomes always visible because `display: grid` overrides UA `display:none`.
  * Branch is clean to merge to `main`; no overlapping files with Isaac's PR #60 (all iOS-side).

* **2026-05-25: CDF enabled on ALL Lakebase sync tables.** `lb_capture_sessions_history`, `lb_paired_sessions_history`, `lb_projects_history` now join `lb_uploads_history` and `transcript_events_raw`. Enables streaming pipeline triggers for Phase 5 AI processing.
* **2026-05-25: Offline capture contract DEPLOYED.** Migration 018 (`client_generated_id` UUID + partial unique index), handler idempotency (200 re-submit / 201 new), Option A (client ID = primary key). Both migrations 017+018 verified in OTel. Reply sent to Isaac. Branch: `mg-isaac-genie-interaction`.
* **2026-05-25: Capture-completion pipeline designed.** CDF on `lb_capture_sessions_history` triggers bronze→silver→gold SDP pipeline. Gold produces 4 AI deliverables per capture: Whisper transcript, requirements doc, architecture diagram, Genie Code session plan. Latency budget: ~3–7 min. Design doc: `fixtures/phase5-document-edit-cdf-pipeline.md`.
* **2026-05-26: Phase 5 — Device & Admin Panel IMPLEMENTED on branch `mg-phase5-device-admin-panel`.** New routes: `GET /api/admin/health` (structured health dashboard). New pages: `/devices` (paired device grid with status badges, revoke, revoked history), `/admin` (system health with auto-refresh). Migration 019: `app.sweeper_runs`. Nav updated: Devices, Pair Device (renamed), Admin. `pairing-routes.ts`: `?include_revoked=true` query param support.

## Resolved Target Variables (dev)

| Variable | Resolved Value |
| --- | --- |
| `catalog` | `hls_fde_dev` |
| `schema` | `dev_matthew_giglia_lakeloom` |
| `secret_scope_name` | `lakeloom_credentials` (default) |
| `client_id_dbs_key` | `client_id_dev_matthew_giglia_lakeloom` |
| `client_secret_dbs_key` | `client_secret_dev_matthew_giglia_lakeloom` |
| `xcode_client_id_dbs_key` | `xcode_client_id_dev_matthew_giglia_lakeloom` |
| `xcode_client_secret_dbs_key` | `xcode_client_secret_dev_matthew_giglia_lakeloom` |
| `lakebase_project_id` | `dev-matthew-giglia-lakeloom` |
| `lakebase_database_id` | `db-16c3-p7ob6z9dbv` |
| `zerobus_stream_pool_size` | `16` |
| `run_as_user` | `matthew.giglia@databricks.com` |
| `app_name` | `lakeloom-ai-dev` |
| `app_spn_id` | `686d32bf-a6a4-461b-a18b-82489eecdc15` |

## Resolved Target Variables (hls_fde)

| Variable | Resolved Value |
| --- | --- |
| `catalog` | `hls_fde` |
| `schema` | `lakeloom` |
| `secret_scope_name` | `lakeloom_credentials` (default) |
| `client_id_dbs_key` | `client_id_lakeloom` |
| `client_secret_dbs_key` | `client_secret_lakeloom` |
| `xcode_client_id_dbs_key` | `xcode_client_id_lakeloom` |
| `xcode_client_secret_dbs_key` | `xcode_client_secret_lakeloom` |
| `lakebase_project_id` | `lakeloom-hls-fde` |
| `run_as_user` | `acf021b4-87c6-44ff-b3d7-45c59d63fe4d` (higher-level SPN) |

## Service Principals

### ZeroBus SPN (`lakeloom-{schema}`)

* **Purpose:** Streams data from the AppKit server to the bronze `transcript_events_raw` table via ZeroBus SDK.
* **Permissions:**
  * USE CATALOG, USE SCHEMA, MODIFY + SELECT on `transcript_events_raw` (granted by DDL task)
  * READ_VOLUME + WRITE_VOLUME on `session_audio`, `screenshots`, `documents` (granted by forEach task)
* **Secret scope:** Does NOT have READ on the scope. Its `client_id` is stored BY the bootstrap job; `client_secret` is admin-provisioned.
* **Dev display name:** `lakeloom-dev_matthew_giglia_lakeloom`

### Xcode SPN (`lakeloom-xcode-{schema}`)

* **Purpose:** Authenticates iOS/iPadOS/macOS app to the Databricks App API endpoints before QR-pair onboarding completes.
* **Permissions:** CAN_USE on the Databricks App resource only (granted by App bundle). NO data-plane permissions.
* **Secret scope:** Does NOT have READ on the scope. Its `client_id` is stored BY the bootstrap job; `client_secret` is admin-provisioned.
* **Dev display name:** `lakeloom-xcode-dev_matthew_giglia_lakeloom`

### App SPN (auto-provisioned)

* **Purpose:** The Databricks App's runtime identity. Reads secrets at startup to configure ZeroBus SDK and build QR payloads.
* **Permissions:** READ on `lakeloom_credentials` secret scope (granted via `admin_actions/update-secrets-acls` or App bundle bootstrap).
* **Provisioned by:** Databricks App deployment (auto-created, not managed by this infra bundle).

## Secret Scope Contract (`lakeloom_credentials`)

### Auto-provisioned by platform bootstrap job:

| Key | Value Source |
| --- | --- |
| `{client_id_dbs_key}` | ZeroBus SPN `application_id` |
| `{xcode_client_id_dbs_key}` | Xcode SPN `application_id` |
| `workspace_url` | Workspace host URL |
| `zerobus_endpoint` | `https://{workspace_id}.zerobus.{region}.cloud.databricks.com` |
| `target_table_name` | `{catalog}.{schema}.transcript_events_raw` |
| `zerobus_stream_pool_size` | Job parameter (default: 16) |

### Admin-provisioned (manual after first deploy):

| Key | How to provision |
| --- | --- |
| `{client_secret_dbs_key}` | Generate secret for ZeroBus SPN in workspace UI, store via `admin_actions/set-databricks-secrets` |
| `{xcode_client_secret_dbs_key}` | Generate secret for Xcode SPN in workspace UI, store via `admin_actions/set-databricks-secrets` |

### Secret Scope ACL Design Decision

* **Neither** the ZeroBus SPN nor the Xcode SPN gets READ on the scope.
* The **App's auto-provisioned SPN** gets READ — it reads all values at runtime.
* This is managed by the companion `lakeLoom_app` bundle or via `admin_actions/update-secrets-acls`.

## Platform Bootstrap Job (4 tasks)

1. **ensure_service_principal** (Python, serverless) — Creates/finds both SPNs, provisions secrets, verifies M2M token flow if `client_secret` is available.
2. **create_transcript_events_raw_table** (SQL, warehouse) — Idempotent DDL for the bronze table + dynamic GRANTs (USE CATALOG, USE SCHEMA, MODIFY+SELECT) to the ZeroBus SPN.
3. **grant_volume_access** (SQL, warehouse, **forEach**) — Iterates over `["session_audio", "screenshots", "documents"]` at concurrency 3. Each iteration grants READ_VOLUME + WRITE_VOLUME to the ZeroBus SPN on the named volume. Uses `EXECUTE IMMEDIATE` for dynamic grant statements.
4. **validate_platform** (SQL, warehouse) — Assertion-based checks: schema exists, all three managed volumes exist and are MANAGED, ZeroBus SPN has READ_VOLUME + WRITE_VOLUME on each volume (via `information_schema.volume_privileges`), `transcript_events_raw` table exists.

Task DAG: `ensure_service_principal` → (`create_transcript_events_raw_table` + `grant_volume_access` in parallel) → `validate_platform`.

Job is idempotent and safe to re-run.

## Technical Notes

### Volume Grant Validation Pattern

`SHOW GRANTS ON VOLUME` cannot be used as a table source in Databricks SQL (not valid in subqueries, CREATE VIEW, or CREATE TABLE AS). Use `information_schema.volume_privileges` instead:

```sql
WITH vol_grants AS (
  SELECT *
  FROM information_schema.volume_privileges
  WHERE volume_schema = schema_use
    AND volume_name = 'session_audio'
    AND grantee LIKE '%' || spn_application_id || '%'
)
SELECT
  assert_true(
    (SELECT COUNT(*) FROM vol_grants WHERE privilege_type = 'READ_VOLUME') >= 1,
    'Missing READ_VOLUME...'
  ) ...
```

Available since DBR 13.3 LTS / Unity Catalog.


### Lakebase Endpoint Host Discovery

REST API: `GET /api/2.0/postgres/projects/{project_id}/branches/production/endpoints`

Host field path: `endpoint['status']['hosts']['host']`  
Pooled host: `endpoint['status']['hosts']['read_write_pooled_host']`

The SDK's `Endpoint` object does NOT have a `hostname` attribute. Use the REST API directly.

### SDK 0.17 Files API Signatures

As of `@databricks/sdk-experimental` 0.17.0, the `FilesService` uses object-signature methods:

```typescript
filesApi.createDirectory({ directory_path: string }): Promise<EmptyResponse>
filesApi.upload({ file_path: string, contents?: ReadableStream, overwrite?: boolean }): Promise<EmptyResponse>
filesApi.delete({ file_path: string }): Promise<EmptyResponse>
```

**Key notes:**
* `contents` must be a Web Streams API `ReadableStream`, not a Node `Readable`.
* Pattern for buffer → ReadableStream: `new ReadableStream({ start(c) { c.enqueue(buffer); c.close(); } })`
* `createDirectory` is still needed for nested UC Volume paths (volumes don't auto-create parent dirs).
* Previous positional-arg patterns (`filesApi.upload(path, stream, opts)`) no longer work.

## hi_genie Findings That Change Infra Planning

### QR-pair auth is now the primary auth model

* The iOS app is pivoting away from OAuth U2M entirely.
* Pairing now starts in the Databricks App browser UI, which generates a QR.
* Native app scans QR, obtains M2M token, calls pairing endpoints, then receives a long-lived device identity.
* This means the App bundle is now a **runtime dependency** for mobile onboarding, not just an admin/Genie UI.
