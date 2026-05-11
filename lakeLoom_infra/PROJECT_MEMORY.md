# lakeLoom Project Memory

## Purpose

Project-local durable context for `lakeLoom_infra` when global instructions are unavailable from this editing scope.

## Collaboration Conventions

### Isaac collaboration folders

* `hi_genie/` is read-only context from Isaac.
* Always read `hi_genie/` for relevant project context before substantive work.
* Never write to `hi_genie/`, any subfolder inside it, or any file within it.
* Reply to Isaac, share progress, or record decisions in a sibling `hey_isaac/` folder at the same project root if present.
* Genie is the source of truth for Databricks-related decisions; Isaac is useful for non-Databricks domains such as Xcode and Apple-platform development.

## Project Structure

* Major roots reviewed: `iOS/`, `architecture/LakeLoomMarkdowns/`, and `lakeLoom_infra/`.
* `architecture/hi_genie/` contains read-only design and implementation context from Isaac.
* Current `hi_genie/` inventory contains one file: `architecture/hi_genie/qr-pair-auth-model.md`.
* Recent merged app-side changes center on QR-pair onboarding, session management, auth flows, and coordinator-based navigation.

## Current Infra Status

* Bundle project name: `lakeLoom_infra`.
* Bundle root: `/Workspace/Users/matthew.giglia@databricks.com/lakeLoom/lakeLoom_infra`.
* `bundle validate --strict --target dev` passed previously.
* Bundle summary showed resources tracked but not yet deployed at the time of review.
* `resources/uc_setup.job.yml` is still empty and remains the primary blocker to operational deployment.
* Existing bundle resources already include a UC schema, session audio volume, secret scope, SQL warehouse, and Lakebase project.

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

## Recommended Job Naming

* `uc_setup` is now too narrow for the job's expected responsibilities.
* Recommended new name: `platform_bootstrap`.
* Reason: the job now needs to cover Unity Catalog setup, shared SPN bootstrap, secret initialization, permission wiring, and platform readiness for QR pairing.
* Recommended file name if renamed: `resources/platform_bootstrap.job.yml`.
* Keep `uc_setup` only for notebook names or task names that are strictly limited to schema / grants work.

## Infra Bundle Plan

### Phase 1 — Finalize bootstrap scope

* Decide what belongs in the infra bundle bootstrap job versus a separate App bootstrap step.
* Strong default split: infra bundle owns shared SPN creation, secret scope initialization, UC grants, volume readiness, and environment metadata; App bootstrap owns application tables and API-level migrations.
* Current decision: `paired_sessions` should be created by the App startup/migration path, not by infra bootstrap, unless later testing proves the App cannot reliably enforce schema readiness before serving pairing endpoints.

### Phase 2 — Define the secret and identity contract

* Finalize the exact secret keys the App and iOS flow will depend on.
* Confirm naming for SPN `client_id`, `client_secret`, `workspace_url`, `zerobus_endpoint`, `target_table_name`, and any App base URL or workspace metadata values needed for QR payload generation.
* Document which values are auto-provisioned by bootstrap versus still manual admin inputs.

### Phase 3 — Author the bootstrap job

* Create the job resource currently stubbed in `resources/uc_setup.job.yml`, ideally renamed to `platform_bootstrap.job.yml`.
* Expected task groups: ensure shared SPN, write/update secret-scope values, apply UC grants, verify session audio volume access, and validate ZeroBus / transcript destination configuration.
* Exclude `paired_sessions` DDL from infra bootstrap unless App migration ownership is revisited.

### Phase 4 — Verify permissions and runtime assumptions

* Verify the shared SPN can mint M2M tokens and has the minimum permissions for UC Volume uploads, ZeroBus publishing, and SCIM `/Me` lookup.
* Confirm the bootstrap job grants secret-scope read access only where required.
* Confirm the job can safely be rerun without duplicating principals, grants, or schema objects.

### Phase 5 — Validate deployment readiness

* Validate the bundle after each resource change.
* Deploy to `dev`, run the bootstrap job, and capture the exact manual follow-ups that remain, especially generation and storage of the SPN `client_secret` if that cannot be automated.
* Treat QR-pair readiness as the acceptance bar, not just successful UC resource creation.

## Recent Repository State

* Feature branch `mg-start-infra` was merged with `main` cleanly during review.
* Notable newer project context after sync was concentrated in `iOS/` and `architecture/hi_genie/`.
* Key app themes observed: QR pairing auth, onboarding expansion, `AppCoordinator`, `QRScannerView`, `LoopbackCallbackListener`, Secure Enclave signing, and related tests.

## Recommended Next Steps

* Rename the job conceptually to `platform_bootstrap` and update the file/resource names when ready to edit bundle resources.
* Confirm the exact secret keys and naming that the Databricks App will read when building QR payloads.
* Verify the SPN permissions needed for UC Volume uploads, ZeroBus publishing, and SCIM `/Me` before finalizing bootstrap notebooks.
* Draft the bootstrap job around the new QR-pair auth model, not the older OAuth U2M assumptions.
* Keep App-managed Lakebase migrations as the default for `paired_sessions` unless deployment testing shows a readiness race.
* Keep app/infra sequencing aligned with QR-pair onboarding requirements, since App endpoints now block iOS implementation.
* When possible, copy any still-relevant items here into the global `.assistant_instructions.md` file as well.
