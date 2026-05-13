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
│   ├── app.yml                     # AppKit app manifest
│   ├── src/                        # App source (Node.js + React)
│   ├── resources/                  # App resource definitions
│   └── fixtures/
│       ├── sessions/               # App session summaries
│       └── Genie Code Starter Session
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

## Resolved Target Variables (dev)

| Variable | Resolved Value |
| --- | --- |
| `catalog` | `hls_fde_dev` |
| `schema` | `lakeloom` |
| `secret_scope_name` | `lakeloom_credentials` (default) |
| `client_id_dbs_key` | `client_id_dev_matthew_giglia_lakeloom` |
| `client_secret_dbs_key` | `client_secret_dev_matthew_giglia_lakeloom` |
| `xcode_client_id_dbs_key` | `xcode_client_id_dev_matthew_giglia_lakeloom` |
| `xcode_client_secret_dbs_key` | `xcode_client_secret_dev_matthew_giglia_lakeloom` |
| `lakebase_project_id` | `dev-matthew-giglia-lakeloom` |
| `zerobus_stream_pool_size` | `16` |
| `run_as_user` | `matthew.giglia@databricks.com` |

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
3. After App bundle deploys: grant App SPN READ on `lakeloom_credentials` scope.
4. Deploy to `hls_fde` target when ready for production.

## Next Steps (post-infra)

* Author the companion `lakeLoom_app` bundle (Databricks App with AppKit).
* App bootstrap: self-migrate Lakebase tables (`paired_sessions`, etc.) before serving endpoints.
* App bundle grants its own SPN READ on `lakeloom_credentials` and CAN_USE to the Xcode SPN.
* App SPN needs WRITE_VOLUME on `session_audio`, `screenshots`, and `documents` for proxied uploads from iOS.
* QR-pair endpoint implementation depends on both SPNs having valid `client_secret` values.
* ~~Inform Isaac (via `hey_isaac/`) about `screenshots` and `documents` volumes and the corresponding App upload endpoints iOS will need to call.~~ **DONE 2026-05-12**
* Await Isaac's response on filename conventions (timestamps vs UUIDs) before finalizing App upload handlers.
