# lakeLoom Project Memory

## Purpose

Project-local durable context for `lakeLoom_infra` when global instructions are unavailable from this editing scope.

## Collaboration Conventions

### Isaac collaboration folders

* `hi_genie/` is read-only context from Isaac.
* Always read `hi_genie/` for relevant project context before substantive work.
* Never write to `hi_genie/`, any subfolder inside it, or any file within it.
* Reply to Isaac, share progress, or record decisions in a sibling `hey_isaac/` folder at the same project root if present.
* Genie is the source of truth for Databricks-related decisions; Isaac = non-Databricks domains (Xcode, Apple platforms).

## Project Structure

```
lakeLoom_infra/
├── databricks.yml              # Bundle config, variables, targets
├── PROJECT_MEMORY.md           # This file
├── README.md
├── .gitignore
├── resources/
│   ├── lakeloom.schema.yml
│   ├── session_audio.volume.yml
│   ├── lakeloom.secret_scope.yml
│   ├── infra_warehouse.sql_warehouse.yml
│   ├── lakeloom.lakebase.yml
│   └── platform_bootstrap.job.yml
├── src/
│   ├── lib/                        # Reusable Python modules
│   │   ├── __init__.py
│   │   ├── workspace_metadata.py   # get_workspace_id(), get_region(), get_zerobus_endpoint()
│   │   ├── service_principal.py    # get_or_create_service_principal(), verify_client_credentials()
│   │   └── secret_scope.py         # put_secret(), list_secret_keys(), try_get_secret_value()
│   ├── platform_bootstrap/         # NOTEBOOK objects (no raw .sql/.py files)
│   │   ├── ensure-service-principal # Python default, 12 cells
│   │   ├── stt-0bus-target-table-ddl # SQL default, 14 cells
│   │   └── validate-platform       # SQL default, 7 cells
│   └── admin_actions/              # Manual admin notebooks
│       ├── set-databricks-secrets  # Generic secret provisioning
│       └── update-secrets-acls     # Secret scope ACL management
└── fixtures/
    ├── sessions/                   # Session summaries (YYYY-MM-DD_desc.md)
    └── Genie Session Starter       # Notebook fixture
```

## Current Infra Status

* Bundle fully deployed to **dev** target and `platform_bootstrap` job runs successfully (all 3 tasks pass).
* `resources/uc_setup.job.yml` was **deleted** (empty legacy file, superseded by `platform_bootstrap.job.yml`).
* Source code reorganized: all task logic lives in NOTEBOOK objects; reusable functions in `src/lib/`.
* **No plain `.sql` files** outside of SDP. SQL logic lives in SQL-default NOTEBOOK objects.
* NOTEBOOK objects are always referenced as `.ipynb` in job YAML. The `warehouse_id` field determines SQL compute routing, not the file extension.
* `src/lib/secret_scope.py` — named to avoid collision with Python stdlib `secrets` module.

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
* **Permissions:** USE CATALOG, USE SCHEMA, MODIFY + SELECT on `transcript_events_raw` (granted by DDL task).
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

## Platform Bootstrap Job (3 tasks)

1. **ensure_service_principal** (Python, serverless) — Creates/finds both SPNs, provisions secrets, verifies M2M token flow if `client_secret` is available.
2. **create_transcript_events_raw_table** (SQL, warehouse) — Idempotent DDL for the bronze table + dynamic GRANTs (USE CATALOG, USE SCHEMA, MODIFY+SELECT) to the ZeroBus SPN.
3. **validate_platform** (SQL, warehouse) — Assertion-based checks: schema exists, `session_audio` volume is MANAGED, `transcript_events_raw` table exists.

Job is idempotent and safe to re-run.

## hi_genie Findings That Change Infra Planning

### QR-pair auth is now the primary auth model

* The iOS app is pivoting away from OAuth U2M entirely.
* Pairing now starts in the Databricks App browser session and finishes on iPhone by scanning a QR code.
* The QR payload carries a shared workspace SPN for data-plane access plus a per-user 7-day session token for App control-plane access.
* iOS generates a Secure Enclave P-256 keypair and signs every iOS → App request after pairing.
* This is described as the long-term auth model, not a temporary workaround.

### Two-layer auth model

* Layer 1: iOS uses SPN `client_credentials` against `<workspace>/oidc/v1/token` for workspace data-plane actions.
* Expected Layer 1 use cases include UC Volume audio uploads, ZeroBus events, and a one-time SCIM `/Me` identity verification call.
* Layer 2: iOS uses an App-issued session token plus ECDSA request signing for Lakebase-backed App APIs.
* The App, not the workspace, is responsible for per-user authorization and paired-device lifecycle.

### App-side data model and APIs now expected

* The App design expects a Lakebase `paired_sessions` table with indexed lookup by `token_hash` and soft revocation via `revoked_at`.
* The App also expects pairing-oriented endpoints such as `GET /api/pairing/qr`, `POST /api/pairing/confirm`, `GET /api/pairing/devices`, and `DELETE /api/pairing/devices/:id`.
* QR payload contents include `workspace.url`, `workspace.id`, `workspace.cloud`, user identity fields, SPN credentials, session token metadata, and App base URL.
* Current working assumption: the App can safely self-migrate the Lakebase schema it needs before pairing traffic depends on it.

## Infra Bundle Plan Status

| Phase | Status | Notes |
| --- | --- | --- |
| 1. Finalize bootstrap scope | **DONE** | Infra owns SPNs, secrets, UC grants, volumes. App owns Lakebase migrations. |
| 2. Define secret/identity contract | **DONE** | Schema-qualified keys, two SPNs, scope ACL design decided. |
| 3. Author the bootstrap job | **DONE** | 3-task job deployed and running on dev. |
| 4. Verify permissions and runtime | **DONE** | M2M verification implemented. ACL design: SPNs don't need scope READ. |
| 5. Validate deployment readiness | **DONE** | Dev deployed, job succeeds. Manual steps: provision client_secrets. |

## Remaining Manual Steps (per environment)

1. Generate OAuth secret for ZeroBus SPN → store as `{client_secret_dbs_key}` in `lakeloom_credentials`.
2. Generate OAuth secret for Xcode SPN → store as `{xcode_client_secret_dbs_key}` in `lakeloom_credentials`.
3. After App bundle deploys: grant App SPN READ on `lakeloom_credentials` scope.
4. Deploy to `hls_fde` target when ready for production.

## Next Steps (post-infra)

* Author the companion `lakeLoom_app` bundle (Databricks App with AppKit).
* App bootstrap: self-migrate Lakebase tables (`paired_sessions`, etc.) before serving endpoints.
* App bundle grants its own SPN READ on `lakeloom_credentials` and CAN_USE to the Xcode SPN.
* QR-pair endpoint implementation depends on both SPNs having valid `client_secret` values.
