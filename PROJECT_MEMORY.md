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
│   ├── package.json                # Node.js dependencies (AppKit 0.24.0, React 19, Zod, ZeroBus SDK)
│   ├── server/                     # Express API (TypeScript)
│   │   ├── server.ts              # Entry: secrets → migrations → routes → serve
│   │   ├── lib/                   # crypto.ts, errors.ts (RFC 9457)
│   │   ├── middleware/            # ios-auth.ts, browser-auth.ts + dualAuth()
│   │   ├── migrations/            # 001–004 (paired_sessions → projects)
│   │   ├── services/              # secrets, sse, zerobus stream pool
│   │   └── routes/                # pairing, captures, uploads, events, projects
│   ├── client/                     # React frontend (Vite + Tailwind v4)
│   │   ├── src/                   # App.tsx, pages/ (pairing, projects, stubs)
│   │   └── public/                # Favicons, manifest
│   ├── shared/appkit-types/        # Shared TypeScript types
│   ├── patches/zerobus-ingest-sdk/ # SDK patch (index.js, index.d.ts)
│   ├── scripts/                    # patch-zerobus-sdk.mjs
│   ├── tests/smoke.spec.ts         # Playwright smoke test
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
## hi_genie Findings That Change Infra Planning

### QR-pair auth is now the primary auth model

* The iOS app is pivoting away from OAuth U2M entirely.
* Pairing now starts in the Databricks App browser session and finishes on iPhone by scanning a QR code.
* The QR payload carries the **Xcode SPN** credentials (for App sidecar M2M auth) plus a per-user 7-day session token (for App control-plane access). ZeroBus SPN credentials stay server-side.
* iOS generates a Secure Enclave P-256 keypair and signs every iOS → App request after pairing.
* This is described as the long-term auth model, not a temporary workaround.

### Two-layer auth model (REFINED 2026-05-12)

* Layer 1: iOS uses **Xcode SPN** `client_credentials` against `<workspace>/oidc/v1/token` to obtain M2M Bearer tokens. These tokens satisfy the Databricks App's auth sidecar (which rejects unauthenticated requests with 302).
* Layer 1 scope: App sidecar authentication ONLY. iOS does NOT call UC APIs, ZeroBus, or SCIM directly.
* Layer 2: iOS sends a per-user session token plus ECDSA P-256 request signature on every App API call. The App verifies the token against `paired_sessions` in Lakebase and the signature against the bound `device_pubkey`.
* The App, not the workspace, is responsible for per-user authorization and paired-device lifecycle.
* **All data-plane operations are App-proxied:** audio uploads, screenshot uploads, document uploads, ZeroBus event forwarding, and project/session CRUD flow through the App's API. iOS never touches UC Volume Files API or ZeroBus directly.
* ZeroBus SPN credentials **never leave the server** — the App reads them from the secret scope and uses them server-side.

### App-side data model and APIs now expected

* The App design expects a Lakebase `paired_sessions` table with indexed lookup by `token_hash` and soft revocation via `revoked_at`.
* The App also expects pairing-oriented endpoints such as `GET /api/pairing/qr`, `POST /api/pairing/confirm`, `GET /api/pairing/devices`, and `DELETE /api/pairing/devices/:id`.
* QR payload contents include `workspace.url`, `workspace.id`, `workspace.cloud`, user identity fields, Xcode SPN credentials, session token metadata, and App base URL.
* Current working assumption: the App can safely self-migrate the Lakebase schema it needs before pairing traffic depends on it.

## Architecture Decisions

### ADR-001: App-Proxied Data Plane (2026-05-12)

**Context:** Isaac's original QR-pair design had iOS calling UC Volume Files API directly using a shared SPN's M2M token (Layer 1). This created an exception to the single-network-boundary principle and required SPN credentials (ZeroBus SPN) in the QR payload.

**Decision:** All data-plane operations route through the Databricks App:
* Audio upload: iOS → App endpoint → App SPN writes to UC Volume (`session_audio`)
* Screenshot upload: iOS → App endpoint → App SPN writes to UC Volume (`screenshots`)
* Document upload: iOS → App endpoint → App SPN writes to UC Volume (`documents`)
* Transcript events: iOS → App endpoint → App forwards via ZeroBus TS SDK (already designed this way)
* SCIM identity: User identity supplied in QR payload from browser session (no iOS-side SCIM call)

**Consequences:**
* QR payload carries **Xcode SPN** credentials only (for App sidecar M2M auth). No ZeroBus SPN credentials on the wire.
* iOS auth surface simplified: M2MTokenClient uses Xcode SPN → App sidecar. No separate token flow for data-plane.
* WRITE_VOLUME on all three volumes granted to **App's auto-provisioned SPN** (App-bundle scope, not infra).
* Single-network-boundary principle is absolute: iOS → App (HTTPS) is the ONLY network call.
* ZeroBus SPN stays single-responsibility: streams to bronze table, credentials never exposed to clients.
* Infra bundle grants ZeroBus SPN READ_VOLUME + WRITE_VOLUME for server-side data operations.

**QR Payload (revised):**
```json
{
  "v": 1,
  "workspace": { "url": "...", "id": "...", "name": "...", "cloud": "..." },
  "user": { "scim_id": "...", "user_name": "...", "display_name": "..." },
  "xcode_spn": { "client_id": "...", "client_secret": "..." },
  "session": { "token": "...", "expires_at": "..." },
  "app": { "base_url": "..." }
}
```

**Auth Flow (per iOS → App request):**
1. iOS mints M2M token: `POST <workspace>/oidc/v1/token` with Xcode SPN `client_credentials`
2. iOS sends request: `Authorization: Bearer <M2M>` + `X-Lakeloom-Session: <token>` + `X-Lakeloom-Timestamp` + `X-Lakeloom-Signature`
3. App sidecar validates Bearer (Layer 1) → passes to App backend
4. App backend validates session token + ECDSA signature (Layer 2) → routes to handler

**Ownership clarification:**

| Responsibility | Owner |
| --- | --- |
| Xcode SPN provisioning + client_id in scope | Infra bundle (DONE) |
| Xcode SPN client_secret in scope | Admin manual step (DONE per env) |
| CAN_USE on App for Xcode SPN | App bundle |
| READ_VOLUME + WRITE_VOLUME for ZeroBus SPN | Infra bundle (DONE — forEach task) |
| WRITE_VOLUME on volumes for App SPN | App bundle (App's own SPN) |
| ZeroBus SPN credentials in scope | Infra bundle (DONE) |
| Audio upload endpoint + Volume write | App bundle |
| Screenshot upload endpoint + Volume write | App bundle |
| Document upload endpoint + Volume write | App bundle |
| Lakebase paired_sessions migration | App bundle |

**Isaac notification:** Sent 2026-05-12 via `lakeLoom/architecture/hey_isaac/2026-05-12_new-upload-volumes.md`. Covers volume paths, proposed endpoint contracts, WRITE_VOLUME grant expectations, and filename convention questions.

## Infra Bundle Plan Status

| Phase | Status | Notes |
| --- | --- | --- |
| 1. Finalize bootstrap scope | **DONE** | Infra owns SPNs, secrets, UC grants, volumes. App owns Lakebase migrations. |
| 2. Define secret/identity contract | **DONE** | Schema-qualified keys, two SPNs, scope ACL design decided. |
| 3. Author the bootstrap job | **DONE** | 4-task job deployed and running on dev. |
| 4. Verify permissions and runtime | **DONE** | M2M verification implemented. ACL design: SPNs don't need scope READ. |
| 5. Validate deployment readiness | **DONE** | Dev deployed, job succeeds. Manual steps: provision client_secrets. |
| 6. Notify Isaac of new volumes | **DONE** | 2026-05-12 — screenshots + documents volumes, App endpoint expectations. |
| 7. Volume grants + forEach task | **DONE** | 2026-05-12 — grant-volume-access notebook, forEach in job, validate-platform assertions. |

## Remaining Manual Steps (per environment)

1. Generate OAuth secret for ZeroBus SPN → store as `{client_secret_dbs_key}` in `lakeloom_credentials`.
2. Generate OAuth secret for Xcode SPN → store as `{xcode_client_secret_dbs_key}` in `lakeloom_credentials`.
3. ~~After App bundle deploys: grant App SPN READ on `lakeloom_credentials` scope.~~ **DONE — automated via `configure_app_spn` Task 1 (`update_secrets_acls`).**
4. Deploy to `hls_fde` target when ready for production.

## Next Steps (post-infra)

* ~~Author the companion `lakeLoom_app` bundle (Databricks App with AppKit).~~ **DONE — `lakeloom-ai` bundle.**
* ~~App bootstrap: self-migrate Lakebase tables (`paired_sessions`, etc.) before serving endpoints.~~ **DONE — auto-migration in `server/migrations/`.**
* ~~App bundle grants its own SPN READ on `lakeloom_credentials` and CAN_USE to the Xcode SPN.~~ **DONE — `configure_app_spn` job task 1.**
* ~~QR-pair endpoint implementation depends on both SPNs having valid `client_secret` values.~~ **DONE — all endpoints implemented.**
* ~~Inform Isaac (via `hey_isaac/`) about `screenshots` and `documents` volumes and the corresponding App upload endpoints iOS will need to call.~~ **DONE 2026-05-12**
* ~~App SPN needs WRITE_VOLUME on `session_audio`, `screenshots`, and `documents` for proxied uploads from iOS.~~ **DONE 2026-05-14 — forEach task in `configure_app_spn` job (Task 3).**
* ~~Await Isaac's response on filename conventions (timestamps vs UUIDs) before finalizing App upload handlers.~~ **DONE — UUIDv7 filenames, MIME-derived extensions. Deployed 2026-05-14.**
* ~~**Next feature branch:** Orphan-byte sweeper — scheduled job to scan UC Volumes for files without a matching `app.uploads` row.~~ **DONE 2026-05-14 — `orphan_byte_sweeper` job, weekly Sunday 2am UTC, report-only v1.**
* ~~Await Isaac's confirmation: (1) HEIC vs JPEG/PNG from iOS, (2) base64url vs standard base64 for `device_pubkey`.~~ **DONE 2026-05-14 — iOS sends JPEG only (no HEIC), base64url no-padding confirmed.**
* ~~End-to-end QR pairing on physical iPhone.~~ **DONE 2026-05-15 — Module 01 validated, PR #18 merged.**
* **Next: Browser UI Phase 2** — Capture Session Browser (see `fixtures/databricks-app-ui-plan.md`).
* **Next: iOS Module 02** — CaptureEngine. Will exercise audio + screenshot + photo upload endpoints.
* **Non-blocking follow-up:** Isaac investigating `GET /api/v1/projects` list failure during onboarding (likely iOS `LiveProjectAPIClient` not routing through full header injector).

## App Bundle (lakeloom-ai) — Implementation Status

### QR-Pair Auth (server-side): COMPLETE
All server components implemented: crypto lib, migration runner, `paired_sessions` table, iOS auth middleware (ECDSA P-256 verification), pairing routes (QR generate, confirm, device list, revoke, SSE), upload routes (audio/screenshots/photos/documents → UC Volumes), event routes (→ ZeroBus).

### QR-Pair Auth (client-side): COMPLETE
* `PairingPage.tsx` state machine implemented (loading → qr → paired → gated → error)
* `qrcode.react` rendering correctly (confirmed 2026-05-13)
* API test notebook validates: Xcode SPN token acquired, sidecar pass-through works, Layer 2 rejection correct



### QR-Pair E2E on Device: VALIDATED (2026-05-15)
* Physical iPhone scanned QR, paired, persisted credential to Keychain, created a project, landed on home screen.
* First time full auth chain worked on device since pivot to QR pairing (2026-05-09).
* Three server-side bug fixes enabled this: `sha256(Buffer)` token-hash (PR #21), `x-forwarded-host` (PR #20), OTel trace investigation.

### Upload Traceability & Capture Sessions: COMPLETE (2026-05-14)
* **Migrations:** `002_capture_sessions.ts` (state machine table, 4 partial indexes, REPLICA IDENTITY FULL), `003_uploads.ts` (UUIDv7 PK, 6 partial indexes incl. sha256, REPLICA IDENTITY FULL)
* **Capture lifecycle routes:** POST/PATCH/GET `/api/captures/`, GET `/api/projects/:id/captures` — iosAuth middleware, state enforcement
* **Upload routes rewritten:** multipart (busboy), SHA-256 streaming integrity, UUIDv7 filenames, MIME allowlist (415 for unknowns), `app.uploads` INSERT, orphan cleanup on failure
* **Route renames:** `/api/sessions/` → `/api/captures/` (zero clients deployed, zero migration cost)
* **Pairing confirm response:** `device_id` → `paired_session_id`
* **Timestamp canonical form locked:** `METHOD\nPATH\nUNIX_SECONDS\nBODY_SHA256_HEX` (in `ios-auth.ts` comment)
* **Dependencies added:** `busboy ^1.6.0`, `uuid ^11.1.0`, `@types/busboy ^1.5.4`

### Photos Endpoint & Per-Endpoint MIME Filtering: COMPLETE (2026-05-14)
* **New endpoint:** `POST /api/captures/:capture_session_id/photos` — camera photos (whiteboards, physical artifacts)
* **MIME filtering:** Each upload endpoint now declares its own `allowedMimes` list (previously one global map):
  * Audio: `audio/wav`, `audio/m4a`, `audio/mp4`
  * Screenshots: `image/png`, `image/jpeg`
  * Photos: `image/jpeg` only
  * Documents: `application/pdf`, `application/vnd.openxmlformats-officedocument.wordprocessingml.document`
* **HEIC dropped:** Removed `image/heic` from global MIME map. iOS captures JPEG natively via `AVCapturePhotoOutput`.
* **`app.uploads.kind`:** New value `'photo'` — no migration needed (no CHECK constraint by design).
* **`screenshots` UC Volume semantic widening:** This volume now holds "session images" — both screenshots (`kind='screenshot'`, PNG primary) and camera photos (`kind='photo'`, JPEG only). Differentiated by `kind` column in `app.uploads`, not by filesystem layout.
* **base64url encoding confirmed:** `device_pubkey` on wire uses RFC 4648 §5 base64url with stripped padding. Node decoder `Buffer.from(x, 'base64url')` handles this natively. No code change needed.

### Post-Deploy Validation: COMPLETE (2026-05-14)
* **Job:** `post_deploy_validation` in `resources/post_deploy_validation.job.yml`
* **Notebook:** `src/tests/pairing-api-test.ipynb` — 10 endpoint tests (including full E2E pairing with ECDSA keygen), CI/CD gate cell raises AssertionError on failure
* **deploy.sh Step 7:** `run_post_deploy_validation()` — runs after source deploy, non-fatal (warns but doesn't block)
* **Flag:** `--skip-validation` skips Step 7 for rapid iteration
* **Tests cover:** healthz, browser-auth pairing (expected 401), SPN token acquisition, Layer 1 pass-through, capture lifecycle, upload routes

### Lakebase Schema Permissions: COMPLETE
* `configure_app_spn` job succeeded (2026-05-13) — both tasks passed
* App migrations run successfully on startup (schema `app` + all 4 tables created)
* ~~Note: `src/admin/grant-lakebase-schema-access` notebook cell 5 had `endpoint.hostname` bug~~ **FIXED — uses REST API dict path `ep["status"]["hosts"]["host"]` (correct).**

### configure_app_spn Job (two-job pattern)
* **Orchestrator:** `configure_app_spn` (in `resources/configure_app_spn.job.yml`)
  * Task 1: `run_job_task` → calls `update_secrets_acls` helper job
  * Task 2: `setup_lakebase_schema` — `../src/admin/grant-lakebase-schema-access.ipynb` (relative, bundle-resolved)
* **Helper:** `update_secrets_acls` (in `resources/update_secrets_acls.job.yml`) — git-sourced, runs GitHub notebook
* **Why split:** `git_source` at job level applies to ALL tasks; can't mix git + workspace notebooks in one job
* **Environment:** Both use `environment_version: ${var.serverless_environment_version}` (default: "5")
* **Status:** Both tasks SUCCEEDED (2026-05-13)
* **deploy.sh:** `run_configure_app_spn()` triggers after app registration, before compute startup

### App SPN
* **Client ID:** `686d32bf-a6a4-461b-a18b-82489eecdc15`
* **Variable:** `${var.app_spn_id}` in `databricks.yml`
* **Secrets:** All 8 env vars confirmed present at runtime via `valueFrom` bindings in `app.yaml`

### Project Management (Phase 1): COMPLETE (2026-05-14)
* **Migration 004:** `app.projects` table — UUIDv7 PK, `client_generated_id` idempotency key, `workspace_id` + `archived` + `updated_at DESC` composite indexes, GIN trigram index on `name` (pg_trgm extension confirmed working on Lakebase), REPLICA IDENTITY FULL.
* **Routes:** 6 CRUD endpoints at `/api/v1/projects/*` — List (cursor-based pagination), Get, Create (idempotent), Edit, Archive, Restore. All use `dualAuth()` middleware (iOS Layer 2 OR browser on-behalf-of-user).
* **Pagination:** Cursor-based using composite `(updated_at DESC, id DESC)`. Opaque base64url-encoded JSON cursor. Default page size 25, max 100. Server returns `next_cursor` + `has_more`.
* **Browser auth middleware:** `browser-auth.ts` — extracts identity from `X-Forwarded-Email` / `X-Forwarded-User` headers (injected by platform sidecar). `dualAuth()` detects iOS vs browser and delegates accordingly.
* **Client UI:** `ProjectsPage.tsx` — card grid with create/edit modals, search (debounced 300ms), archive/restore, "Load more" button for pagination. Databricks brand tokens (DM Sans, semantic colors, motion).
* **Test 9:** Added to `pairing-api-test` notebook — validates all 6 routes are registered and dualAuth active.
* **Lakebase extension support confirmed:** `CREATE EXTENSION IF NOT EXISTS pg_trgm` succeeded. Positive signal for future `pgvector` use.

### QR Pairing Host Fix: COMPLETE (2026-05-14)
* **Bug:** `app.base_url` in QR payload encoded `https://localhost:8000` because Express reads the container's loopback address from `req.headers.host`. iPhone tried to connect to its own loopback → ECONNREFUSED.
* **Fix:** Read `x-forwarded-host` (public hostname from platform reverse proxy) and `x-forwarded-proto` (scheme). Falls back to `req.headers.host` for local-dev/Simulator.
* **Verified:** QR now returns `https://lakeloom-ai-dev-7474657291520070.aws.databricksapps.com`.
* **Isaac notified:** `hey_isaac/2026-05-14_pairing-qr-host-fix-ack.md` — no iOS-side change needed.

### Orphan Byte Sweeper: DEPLOYED (2026-05-14)
* **Job:** `orphan_byte_sweeper` in `resources/orphan_byte_sweeper.job.yml`
* **Schedule:** Weekly Sunday 2am UTC (paused in dev via preset)
* **Mode:** Report-only v1 — logs orphan files but does not delete. Threshold: 24h age.


## iOS Auth Implementation Notes (Resolved 2026-05-14)

### Token Hash Contract

`generateSessionToken()` produces `{ token, hash }`:
- `token` = `randomBytes(32).toString('base64url')` — sent to iOS via QR
- `hash` = `sha256(raw_32_bytes)` — stored in `app.paired_sessions.token_hash`

**iosAuth lookup:** Must decode token back to raw bytes before hashing:
```typescript
const tokenHash = sha256(Buffer.from(sessionToken, 'base64url'));
```

### Canonical Message Body Hash

Per spec (locked 2026-05-13):
- Body present: `sha256Hex(JSON.stringify(parsed_body))` (compact JSON)
- Empty body: constant `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
- **WARNING:** Express json() middleware sets `req.body = {}` on GET/DELETE. Use `Object.keys(req.body).length > 0` to detect actual body presence.

### Public Key Format

- **Server expects:** SPKI DER (SubjectPublicKeyInfo, 91 bytes, starts `0x30`)
- **iOS sends:** `privateKey.publicKey.derRepresentation` (CryptoKit P256)
- **NOT:** Raw X9.62 uncompressed point (65 bytes, starts `0x04`)
- Server verification: `createPublicKey({ key: buffer, format: 'der', type: 'spki' })`

### Post-Deploy Validation

Test suite expanded to 10 tests. Test 10 performs full E2E pairing:
QR → ECDSA keygen → signed confirm → authenticated GET with bound device key.
CI/CD gate asserts all 10 pass.

### IP Access List

- Workspace IP access lists also apply to `*.databricksapps.com` (via auth sidecar token validation)
- Current home network allowlist: `98.10.37.0/24` (ID: `f4dc1a12-f273-48a3-9732-70ed837b419e`, label: `lakeLoomZeroBus`)
- Propagation: up to 10 minutes after modification
- Symptom: 403 from sidecar even with valid M2M token
