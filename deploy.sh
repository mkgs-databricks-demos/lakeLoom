#!/usr/bin/env bash
# deploy.sh — Shared deployment script for the lakeLoom solution.
#
# Deploys Databricks Asset Bundles in dependency order:
#   1. lakeloom-infra       (secret scopes, UC schemas/volumes, SQL warehouse, Lakebase)
#   2. Platform bootstrap   (SPN creation, secret provisioning, table DDL, volume grants)
#   3. Readiness checks     (secret scope keys + bronze table + volumes + Lakebase status)
#   4. Readiness checks     (secret scope keys + bronze table + volumes + Lakebase)
#   5. lakeloom-ai          (AppKit app resource: permissions, env vars, volume/warehouse bindings)
#   6. App source deploy    (start compute if stopped, push source code to container)
#
# Usage:
#   ./deploy.sh --target dev                          # deploy all bundles (with readiness checks)
#   ./deploy.sh --target dev --run-setup              # deploy infra + run platform bootstrap + app
#   ./deploy.sh --target dev --infra                  # deploy only the infra bundle
#   ./deploy.sh --target dev --infra --run-setup      # deploy infra + run platform bootstrap
#   ./deploy.sh --target dev --app                    # deploy only the app bundle (with checks)
#   ./deploy.sh --target dev --app --skip-checks      # deploy app without readiness checks
#   ./deploy.sh --target dev --validate               # validate only, no deploy
#   ./deploy.sh --target dev --destroy                # destroy deployed resources
#
# Infrastructure Readiness Checks (gate before app bundle deploy):
#   Secret scope keys — all required keys must be present:
#     Auto-provisioned:  {client_id_dbs_key}, {xcode_client_id_dbs_key},
#                        workspace_url, zerobus_endpoint, target_table_name,
#                        zerobus_stream_pool_size
#     Admin-provisioned: {client_secret_dbs_key}, {xcode_client_secret_dbs_key}
#   Key names are schema-qualified per target (e.g. client_id_dev_matthew_giglia_lakeloom).
#   Bronze table — transcript_events_raw must exist in the target catalog.schema
#   Volumes — session_audio, screenshots, documents must exist as MANAGED volumes
#   Lakebase project — informational; verifies project exists and endpoint is active
#
# App bundle variable passthrough:
#   After readiness checks, deploy.sh passes only RUNTIME-DISCOVERED values
#   as --var overrides to the app bundle deploy:
#     xcode_spn_id (Xcode SPN application_id from secret scope)
#   All other infra values (catalog, schema, warehouse ID, Lakebase IDs,
#   SPN key names) are hardcoded as target defaults in the app bundle's
#   databricks.yml. The readiness checks verify these match deployed infra.
#
# Requirements:
#   - Databricks CLI installed and authenticated (databricks auth login)
#   - python3 (for JSON parsing of CLI output)

set -euo pipefail

# --------------------------------------------------------------------------- #
# Self-relocation — avoid FUSE filesystem staleness on long-running operations
#
# The Databricks web terminal mounts /Workspace via FUSE. After long-running
# CLI commands (e.g. bundle run polling for 2+ minutes), the FUSE mount can
# become stale, causing "error reading input file: Operation not permitted"
# as bash tries to read subsequent lines of this script.
#
# Fix: if running from /Workspace, copy to /tmp and re-exec from local disk.
# --------------------------------------------------------------------------- #
if [[ "${BASH_SOURCE[0]}" == /Workspace/* ]] && [[ "${__DEPLOY_RELOCATED:-}" != "1" ]]; then
  _tmp_script="/tmp/lakeloom_deploy_$$.sh"
  cp "${BASH_SOURCE[0]}" "${_tmp_script}"
  chmod +x "${_tmp_script}"
  export __DEPLOY_RELOCATED=1
  export __DEPLOY_ORIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  exec "${_tmp_script}" "$@"
fi
# Clean up temp script on exit (if relocated)
if [[ "${__DEPLOY_RELOCATED:-}" == "1" ]]; then
  trap 'rm -f "${BASH_SOURCE[0]}"' EXIT
fi

# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #
# When relocated to /tmp, SCRIPT_DIR must still point to the original bundle root.
if [[ -n "${__DEPLOY_ORIG_DIR:-}" ]]; then
  SCRIPT_DIR="${__DEPLOY_ORIG_DIR}"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
INFRA_BUNDLE="lakeloom-infra"
APP_BUNDLE="lakeloom-ai"

# Infrastructure readiness — expected secret scope keys.
# The client_id and client_secret key names are schema-qualified and resolved
# at runtime by resolve_infra_vars() from the bundle summary variables.
# The arrays below are populated after resolution; see build_key_arrays().
REQUIRED_SCOPE_KEYS=()
AUTO_PROVISIONED_KEYS=()
ADMIN_PROVISIONED_KEYS=()
BRONZE_TABLE="transcript_events_raw"
PLATFORM_BOOTSTRAP_JOB="platform_bootstrap"
VOLUMES=("session_audio" "screenshots" "documents")

# Resolved at runtime by resolve_infra_vars()
SCOPE_NAME=""
CATALOG=""
SCHEMA=""
CLIENT_ID_DBS_KEY=""
CLIENT_SECRET_DBS_KEY=""
XCODE_CLIENT_ID_DBS_KEY=""
XCODE_CLIENT_SECRET_DBS_KEY=""
LAKEBASE_PROJECT_ID=""
SQL_WAREHOUSE_ID=""
LAKEBASE_DATABASE_ID=""
WORKSPACE_HOST=""

# Resolved at runtime after readiness checks — Xcode SPN application_id
# for the app bundle's permissions block (passed via --var override).
XCODE_SPN_ID=""

# Resolved at runtime from the app bundle summary — platform app name
# and source code workspace path for `databricks apps deploy`.
APP_NAME=""
APP_SOURCE_PATH=""
APP_SPN_CLIENT_ID=""
CONFIGURE_APP_SPN_JOB="configure_app_spn"
POST_DEPLOY_VALIDATION_JOB="post_deploy_validation"

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
TARGET=""
DEPLOY_INFRA=true
DEPLOY_APP=true
VALIDATE_ONLY=false
DESTROY=false
RUN_SETUP=false
SKIP_CHECKS=false
SKIP_VALIDATION=false

# --------------------------------------------------------------------------- #
# Usage
# --------------------------------------------------------------------------- #
usage() {
  cat <<EOF
Usage: $(basename "$0") --target <target> [OPTIONS]

Options:
  --target <name>    Required. Bundle target (dev, hls_fde, prod).
  --infra            Deploy only the infrastructure bundle.
  --app              Deploy only the application bundle (skip infra).
  --run-setup        Run the platform bootstrap job after deploying infra.
  --skip-checks      Skip infrastructure readiness checks before app deploy.
  --skip-validation   Skip post-deploy validation (endpoint tests).
  --validate         Validate bundles without deploying.
  --destroy          Destroy deployed resources for the target.
  -h, --help         Show this help message.

Deployment order:
  1. ${INFRA_BUNDLE}        — shared infrastructure (schema, scope, warehouse, Lakebase)
  2. Platform bootstrap      — SPN creation, secret provisioning, DDL, volume grants
  3. Readiness checks        — verifies secret keys + table + volumes + Lakebase
  4. ${APP_BUNDLE}           — application (AppKit app, API routes, frontend)

First deployment:
  ./deploy.sh --target dev --run-setup
  # Then: admin provisions client_secret + xcode_client_secret (see README)
  ./deploy.sh --target dev --app

Subsequent deploys (infra unchanged):
  ./deploy.sh --target dev --app
EOF
  exit 0
}

# --------------------------------------------------------------------------- #
# Parse arguments
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)       TARGET="$2"; shift 2 ;;
    --infra)        DEPLOY_INFRA=true;  DEPLOY_APP=false; shift ;;
    --app)          DEPLOY_INFRA=false; DEPLOY_APP=true;  shift ;;
    --run-setup)    RUN_SETUP=true; shift ;;
    --skip-checks)  SKIP_CHECKS=true; shift ;;
    --skip-validation) SKIP_VALIDATION=true; shift ;;
    --validate)     VALIDATE_ONLY=true; shift ;;
    --destroy)      DESTROY=true; shift ;;
    -h|--help)      usage ;;
    *)              echo "Error: Unknown option '$1'"; usage ;;
  esac
done

if [[ -z "${TARGET}" ]]; then
  echo "Error: --target is required."
  usage
fi

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
log()  { echo -e "\n\033[1;34m==>\033[0m \033[1m$1\033[0m"; }
warn() { echo -e "\033[1;33m  ⚠  $1\033[0m"; }
ok()   { echo -e "\033[1;32m  ✓  $1\033[0m"; }
fail() { echo -e "\033[1;31m  ✗  $1\033[0m"; exit 1; }

# safe() — sanitise a value for shell  interpolation (strips unsafe chars)
safe() { echo "$1" | sed 's/[^a-zA-Z0-9_.\-]//g'; }

# safe_url() — like safe() but preserves :// for workspace URLs
safe_url() { echo "$1" | sed 's/[^a-zA-Z0-9_.\-:\/]//g'; }

# get_app_status() — extract compute readiness from `databricks apps get` JSON.
# The API returns separate fields for compute vs app status. For deploy purposes,
# we need COMPUTE readiness (ACTIVE) — the app status stays UNAVAILABLE until
# source is pushed. Checks: compute_status > status > app_status.
# Returns uppercase state string: ACTIVE, STARTING, STOPPED, UNKNOWN, etc.
get_app_status() {
  python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    print('UNKNOWN')
    sys.exit(0)

def extract_state(field):
    if isinstance(field, dict):
        return field.get('state', '')
    if isinstance(field, str):
        return field
    return ''

# Priority: compute_status (compute readiness) > status > app_status
for key in ('compute_status', 'status', 'app_status'):
    val = data.get(key)
    if val is not None:
        state = extract_state(val)
        if state:
            print(state.upper())
            sys.exit(0)

print('UNKNOWN')
" 2>/dev/null
}

# is_compute_ready() — check if a status value indicates compute is ready
# for source deployment. Accepts ACTIVE (compute up) and RUNNING (app serving).
is_compute_ready() {
  local status="$1"
  [[ "${status}" == "ACTIVE" ]] || [[ "${status}" == "RUNNING" ]]
}

# cd_bundle() — cd into a /Workspace directory with FUSE refresh and retry.
# After long-running operations (bundle run ~2 min), the FUSE mount for
# /Workspace directories can become stale and reject cd with "Operation not
# permitted". This function pokes the directory via `ls` to force the kernel
# to re-validate the mount, then retries cd up to 3 times.
cd_bundle() {
  local dir="$1"
  local i
  for ((i=1; i<=3; i++)); do
    # Poke FUSE to refresh stale directory handles
    ls "${dir}" >/dev/null 2>&1 || true
    sleep 0.5
    if cd "${dir}" 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  # Final attempt — let error propagate
  cd "${dir}"
}

# --------------------------------------------------------------------------- #
# Prerequisites
# --------------------------------------------------------------------------- #
command -v databricks &>/dev/null || fail "Databricks CLI not found. Install: https://docs.databricks.com/dev-tools/cli/install.html"
command -v python3    &>/dev/null || fail "python3 not found (required for JSON parsing)."

# --------------------------------------------------------------------------- #
# deploy_bundle — validate and deploy (or destroy) a single bundle
#
# Usage: deploy_bundle <bundle_name> [extra_deploy_args...]
#   Extra args (e.g. --var key=value) are passed to `bundle deploy` only.
# --------------------------------------------------------------------------- #
deploy_bundle() {
  local bundle_name="$1"
  shift
  local extra_args=("$@")
  local bundle_dir="${SCRIPT_DIR}/${bundle_name}"

  if [[ ! -d "${bundle_dir}" ]]; then
    warn "Bundle directory '${bundle_name}' does not exist yet — skipping."
    return 0
  fi

  if [[ ! -f "${bundle_dir}/databricks.yml" ]]; then
    warn "No databricks.yml found in '${bundle_name}' — skipping."
    return 0
  fi

  log "Validating ${bundle_name} (target: ${TARGET})"
  (cd_bundle "${bundle_dir}" && databricks bundle validate --target "${TARGET}")
  ok "Validation passed: ${bundle_name}"

  if [[ "${VALIDATE_ONLY}" == true ]]; then
    return 0
  fi

  if [[ "${DESTROY}" == true ]]; then
    log "Destroying ${bundle_name} (target: ${TARGET})"
    (cd_bundle "${bundle_dir}" && databricks bundle destroy --target "${TARGET}" --auto-approve)
    ok "Destroyed: ${bundle_name}"
  else
    log "Deploying ${bundle_name} (target: ${TARGET})"
    if [[ ${#extra_args[@]} -gt 0 ]]; then
      (cd_bundle "${bundle_dir}" && databricks bundle deploy --target "${TARGET}" "${extra_args[@]}")
    else
      (cd_bundle "${bundle_dir}" && databricks bundle deploy --target "${TARGET}")
    fi
    ok "Deployed: ${bundle_name}"
  fi
}

# --------------------------------------------------------------------------- #
# resolve_infra_vars — extract scope name, catalog, schema, secret key names,
#                      SQL warehouse ID, Lakebase project ID from infra summary
# --------------------------------------------------------------------------- #
resolve_infra_vars() {
  local bundle_dir="${SCRIPT_DIR}/${INFRA_BUNDLE}"

  log "Resolving infrastructure variables (target: ${TARGET})"

  local summary_json
  summary_json=$(cd_bundle "${bundle_dir}" && databricks bundle summary --target "${TARGET}" --output json 2>/dev/null) || {
    fail "Could not read bundle summary for ${INFRA_BUNDLE}.\n" \
         "  Deploy the infra bundle first:\n" \
         "    cd ${bundle_dir} && databricks bundle deploy --target ${TARGET}"
  }

  # Parse resolved values with python3.
  # Tries schema/warehouse resources first (authoritative), falls back to variables.
  eval "$(echo "${summary_json}" | python3 -c "
import sys, json, re

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError as e:
    print(f'RESOLVE_ERROR=\"JSON parse error: {e}\"', flush=True)
    sys.exit(0)

vars_block = data.get('variables', {})

def get_var(name, default=''):
    v = vars_block.get(name, {})
    if isinstance(v, dict):
        return v.get('value', default)
    return str(v) if v else default

# --- secret_scope_name ---
scope = get_var('secret_scope_name', 'lakeloom_credentials')

# --- client_id/secret key names (ZeroBus SPN) ---
client_id_key     = get_var('client_id_dbs_key', 'client_id')
client_secret_key = get_var('client_secret_dbs_key', 'client_secret')

# --- xcode SPN key names ---
xcode_client_id_key     = get_var('xcode_client_id_dbs_key', 'xcode_client_id')
xcode_client_secret_key = get_var('xcode_client_secret_dbs_key', 'xcode_client_secret')

# --- catalog and schema (prefer resource, fall back to variable) ---
catalog = ''
schema  = ''
resources = data.get('resources', {})
schemas_block = resources.get('schemas', {})
for schema_name, ws in schemas_block.items():
    if isinstance(ws, dict):
        catalog = ws.get('catalog_name', '')
        schema  = ws.get('name', '')

# Fallback to variables if resources didn't resolve
if not catalog:
    catalog = get_var('catalog')
if not schema:
    schema = get_var('schema')

# --- sql_warehouse_id (from sql_warehouses resource) ---
warehouse_id = ''
wh_block = resources.get('sql_warehouses', {})
for wh_name, wh in wh_block.items():
    if isinstance(wh, dict):
        warehouse_id = wh.get('id', '')
        if warehouse_id:
            break

# --- lakebase_project_id (from postgres_projects resource) ---
project_id = ''
pg_projects = resources.get('postgres_projects', {})
for proj_name, proj in pg_projects.items():
    if isinstance(proj, dict):
        project_id = proj.get('project_id', '')
        if project_id:
            break

# Fallback to variable
if not project_id:
    project_id = get_var('lakebase_project_id')

# --- workspace host (from workspace config) ---
workspace_host = ''
workspace_block = data.get('workspace', {})
if isinstance(workspace_block, dict):
    workspace_host = workspace_block.get('host', '')

def safe(v):
    return re.sub(r'[^a-zA-Z0-9_.\-]', '', str(v))

def safe_url(v):
    return re.sub(r'[^a-zA-Z0-9_.\-:/]', '', str(v))

print(f'SCOPE_NAME=\"{safe(scope)}\"')
print(f'CATALOG=\"{safe(catalog)}\"')
print(f'SCHEMA=\"{safe(schema)}\"')
print(f'CLIENT_ID_DBS_KEY=\"{safe(client_id_key)}\"')
print(f'CLIENT_SECRET_DBS_KEY=\"{safe(client_secret_key)}\"')
print(f'XCODE_CLIENT_ID_DBS_KEY=\"{safe(xcode_client_id_key)}\"')
print(f'XCODE_CLIENT_SECRET_DBS_KEY=\"{safe(xcode_client_secret_key)}\"')
print(f'SQL_WAREHOUSE_ID=\"{safe(warehouse_id)}\"')
print(f'LAKEBASE_PROJECT_ID=\"{safe(project_id)}\"')
print(f'WORKSPACE_HOST=\"{safe_url(workspace_host)}\"')
" 2>/dev/null)" || fail "Could not parse bundle summary JSON."

  # Check for parse error forwarded from python
  if [[ -n "${RESOLVE_ERROR:-}" ]]; then
    fail "Bundle summary parse error: ${RESOLVE_ERROR}"
  fi

  [[ -n "${SCOPE_NAME}" ]]                || fail "Could not resolve secret_scope_name from bundle summary."
  [[ -n "${CATALOG}" ]]                   || fail "Could not resolve catalog from bundle summary."
  [[ -n "${SCHEMA}" ]]                    || fail "Could not resolve schema from bundle summary."
  [[ -n "${CLIENT_ID_DBS_KEY}" ]]         || fail "Could not resolve client_id_dbs_key from bundle summary."
  [[ -n "${CLIENT_SECRET_DBS_KEY}" ]]     || fail "Could not resolve client_secret_dbs_key from bundle summary."
  [[ -n "${XCODE_CLIENT_ID_DBS_KEY}" ]]   || fail "Could not resolve xcode_client_id_dbs_key from bundle summary."
  [[ -n "${XCODE_CLIENT_SECRET_DBS_KEY}" ]] || fail "Could not resolve xcode_client_secret_dbs_key from bundle summary."

  ok "Secret scope:             ${SCOPE_NAME}"
  ok "Catalog:                  ${CATALOG}"
  ok "Schema:                   ${SCHEMA}"
  ok "ZeroBus client ID key:    ${CLIENT_ID_DBS_KEY}"
  ok "ZeroBus client secret key: ${CLIENT_SECRET_DBS_KEY}"
  ok "Xcode client ID key:      ${XCODE_CLIENT_ID_DBS_KEY}"
  ok "Xcode client secret key:  ${XCODE_CLIENT_SECRET_DBS_KEY}"

  if [[ -n "${SQL_WAREHOUSE_ID}" ]]; then
    ok "SQL Warehouse ID:         ${SQL_WAREHOUSE_ID}"
  else
    warn "Could not resolve SQL warehouse ID from infra bundle resources."
    warn "App bundle will use its target default."
  fi

  if [[ -n "${LAKEBASE_PROJECT_ID}" ]]; then
    ok "Lakebase project:         ${LAKEBASE_PROJECT_ID}"
  else
    warn "No Lakebase project found in bundle resources (may not be deployed yet)."
  fi

  if [[ -n "${WORKSPACE_HOST}" ]]; then
    ok "Workspace host:           ${WORKSPACE_HOST}"
  fi

  # Build the key arrays now that we have the resolved names
  build_key_arrays
}

# --------------------------------------------------------------------------- #
# resolve_lakebase_database — discover the Lakebase database ID for the
#                             production branch. Requires lakebase_project_id.
#
# Sets LAKEBASE_DATABASE_ID global variable. Non-fatal — warns on failure.
# --------------------------------------------------------------------------- #
resolve_lakebase_database() {
  local project_id="${LAKEBASE_PROJECT_ID:-}"
  if [[ -z "${project_id}" ]]; then
    warn "No Lakebase project ID available — cannot resolve database ID."
    return 0
  fi

  log "Resolving Lakebase database ID (project: ${project_id})"

  local db_json
  db_json=$(databricks postgres list-databases "projects/${project_id}/branches/production" --output json 2>/dev/null) || {
    warn "Could not list databases for project '${project_id}'."
    warn "The project or branch may still be initializing."
    return 0
  }

  # Extract the first database's resource ID from the response.
  # The database resource name is: projects/{id}/branches/production/databases/{db_id}
  # We need just the {db_id} portion.
  LAKEBASE_DATABASE_ID=$(echo "${db_json}" | python3 -c "
import sys, json

try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    sys.exit(0)

databases = data.get('databases', data.get('items', []))
if isinstance(data, list):
    databases = data

for db in databases:
    if not isinstance(db, dict):
        continue
    # Try 'name' field (full resource path) first
    name = db.get('name', '')
    if '/databases/' in name:
        db_id = name.split('/databases/')[-1]
        print(db_id)
        sys.exit(0)
    # Try 'database_id' field
    db_id = db.get('database_id', '')
    if db_id:
        print(db_id)
        sys.exit(0)
" 2>/dev/null) || LAKEBASE_DATABASE_ID=""

  if [[ -n "${LAKEBASE_DATABASE_ID}" ]]; then
    ok "Lakebase database ID:     ${LAKEBASE_DATABASE_ID}"
  else
    warn "Could not resolve Lakebase database ID."
    warn "App bundle will use its target default for lakebase_database_id."
  fi
}

# --------------------------------------------------------------------------- #
# build_key_arrays — populate REQUIRED / AUTO / ADMIN key arrays from the
#                    resolved key names. lakeLoom has two SPNs (ZeroBus + Xcode)
#                    and additional infrastructure keys.
# --------------------------------------------------------------------------- #
build_key_arrays() {
  AUTO_PROVISIONED_KEYS=(
    "${CLIENT_ID_DBS_KEY}"
    "${XCODE_CLIENT_ID_DBS_KEY}"
    workspace_url
    zerobus_endpoint
    target_table_name
    zerobus_stream_pool_size
  )
  ADMIN_PROVISIONED_KEYS=(
    "${CLIENT_SECRET_DBS_KEY}"
    "${XCODE_CLIENT_SECRET_DBS_KEY}"
  )
  REQUIRED_SCOPE_KEYS=("${AUTO_PROVISIONED_KEYS[@]}" "${ADMIN_PROVISIONED_KEYS[@]}")
}

# --------------------------------------------------------------------------- #
# run_platform_bootstrap — run the platform bootstrap job via the bundle CLI
# --------------------------------------------------------------------------- #
run_platform_bootstrap() {
  local bundle_dir="${SCRIPT_DIR}/${INFRA_BUNDLE}"

  log "Running platform bootstrap job: ${PLATFORM_BOOTSTRAP_JOB} (target: ${TARGET})"
  (cd_bundle "${bundle_dir}" && databricks bundle run "${PLATFORM_BOOTSTRAP_JOB}" --target "${TARGET}") || \
    fail "Platform bootstrap job failed. Check the Databricks Jobs UI for details."
  ok "Platform bootstrap job completed successfully"
}

# --------------------------------------------------------------------------- #
# check_lakebase_status — informational check for Lakebase project health
#                         and endpoint status
#
# AppKit's Lakebase plugin connects via direct Postgres wire protocol
# (port 5432) using OAuth token rotation — NOT the Data API.
#
# This function:
#   1. Verifies the Lakebase project exists and is accessible
#   2. Lists endpoints on the production branch to confirm compute is active
#   3. Reports status informatively (does not block deployment)
#
# This is an INFORMATIONAL check — it never fails the deployment.
# --------------------------------------------------------------------------- #
check_lakebase_status() {
  local project_id="${LAKEBASE_PROJECT_ID:-}"
  if [[ -z "${project_id}" ]]; then
    return 0  # No Lakebase project in this bundle — nothing to check
  fi

  log "Checking Lakebase project status (project: ${project_id})"

  # Verify the project is accessible
  local project_json
  project_json=$(databricks postgres get-project "projects/${project_id}" --output json 2>/dev/null) || {
    warn "Lakebase project '${project_id}' not found or not accessible."
    warn "If the project was just created, it may still be initializing."
    return 0
  }
  ok "Lakebase project exists: ${project_id}"

  # List endpoints on the production branch
  local endpoints_json
  endpoints_json=$(databricks postgres list-endpoints "projects/${project_id}/branches/production" --output json 2>/dev/null) || {
    warn "Could not list endpoints for project '${project_id}' branch 'production'."
    warn "The branch or endpoint may still be initializing."
    return 0
  }

  # Check endpoint count and status
  local endpoint_count
  endpoint_count=$(echo "${endpoints_json}" | python3 -c "
import sys, json

try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    print('0')
    sys.exit(0)

endpoints = data.get('endpoints', data.get('items', []))
if isinstance(data, list):
    endpoints = data

print(len(endpoints))
" 2>/dev/null) || endpoint_count="0"

  if [[ "${endpoint_count}" -gt 0 ]]; then
    ok "Lakebase compute endpoint is running (${endpoint_count} endpoint(s))"
  else
    warn "No active endpoints found for Lakebase project '${project_id}'."
    warn "The endpoint may still be initializing after first deploy."
  fi

  echo "  Note: AppKit connects via direct Postgres wire protocol, not the Data API."
  echo "  To enable the Data API for external REST access (optional):"
  echo "    Lakebase App → project '${project_id}' → Data API → 'Enable Data API'"
}

# --------------------------------------------------------------------------- #
# check_volumes — verify all expected UC volumes exist and are MANAGED
# --------------------------------------------------------------------------- #
check_volumes() {
  local all_present=true

  for vol_name in "${VOLUMES[@]}"; do
    local full_volume="${CATALOG}.${SCHEMA}.${vol_name}"
    if databricks volumes read "${full_volume}" &>/dev/null; then
      ok "Volume exists: ${full_volume}"
    else
      warn "Volume MISSING: ${full_volume}"
      all_present=false
    fi
  done

  if [[ "${all_present}" != true ]]; then
    return 1
  fi
  return 0
}

# --------------------------------------------------------------------------- #
# read_xcode_spn_id — read the Xcode SPN application_id from the secret scope.
#                     Used as --var override for the app bundle's Xcode SPN
#                     CAN_USE grant (post-deploy or future YAML integration).
#
# Sets XCODE_SPN_ID global variable. Non-fatal — warns on failure.
# --------------------------------------------------------------------------- #
read_xcode_spn_id() {
  log "Reading Xcode SPN application_id from secret scope"

  XCODE_SPN_ID=$(databricks secrets get-secret "${SCOPE_NAME}" "${XCODE_CLIENT_ID_DBS_KEY}" --output json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('value',''))" 2>/dev/null) || XCODE_SPN_ID=""

  if [[ -n "${XCODE_SPN_ID}" ]]; then
    ok "Xcode SPN ID: ${XCODE_SPN_ID:0:8}..."
  else
    warn "Could not read Xcode SPN application_id from scope."
    warn "App bundle will not receive xcode_spn_id override."
  fi
}

# --------------------------------------------------------------------------- #
# verify_infra_readiness — gate check before app bundle deployment
#
# Checks:
#   1. Secret scope exists and contains all required keys
#      (key names are schema-qualified, resolved from bundle variables)
#   2. Bronze table transcript_events_raw exists in catalog.schema
#   3. All 3 managed volumes exist (session_audio, screenshots, documents)
#   4. Lakebase project status (informational — does not block deploy)
#
# Exit behaviour:
#   - Missing auto-provisioned keys or table → fail with "run setup" message
#   - Missing admin-provisioned keys only    → fail with admin instructions
#   - Lakebase status unknown                → info note (non-blocking)
#   - All present                            → return 0
# --------------------------------------------------------------------------- #
verify_infra_readiness() {
  log "Verifying infrastructure readiness"

  # ---- 1. Secret scope keys -----------------------------------------------
  # NOTE: CLI uses positional arg for scope, not --scope flag
  local secrets_json
  secrets_json=$(databricks secrets list-secrets "${SCOPE_NAME}" --output json 2>/dev/null) || {
    echo ""
    echo "  Secret scope '${SCOPE_NAME}' not found or not accessible."
    echo "  The platform bootstrap job must run first to create SPNs and populate secrets:"
    echo ""
    echo "    databricks bundle run ${PLATFORM_BOOTSTRAP_JOB} --target ${TARGET}"
    echo "    # or: ./deploy.sh --target ${TARGET} --run-setup"
    echo ""
    fail "Secret scope '${SCOPE_NAME}' does not exist."
  }

  # Extract the list of key names present in the scope
  local present_keys
  present_keys=$(echo "${secrets_json}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
# Handle both {\"secrets\": [...]} (old CLI) and direct array [...] (new CLI)
items = data.get('secrets', data) if isinstance(data, dict) else data
for s in items:
    if isinstance(s, dict):
        print(s.get('key', ''))
" 2>/dev/null) || fail "Could not parse secrets list from scope '${SCOPE_NAME}'."

  local missing_auto=()
  local missing_admin=()

  for key in "${REQUIRED_SCOPE_KEYS[@]}"; do
    if echo "${present_keys}" | grep -qx "${key}"; then
      ok "Secret key present: ${key}"
    else
      # Classify as auto-provisioned or admin-provisioned
      local is_admin=false
      for admin_key in "${ADMIN_PROVISIONED_KEYS[@]}"; do
        [[ "${key}" == "${admin_key}" ]] && is_admin=true
      done

      if [[ "${is_admin}" == true ]]; then
        missing_admin+=("${key}")
      else
        missing_auto+=("${key}")
      fi
      warn "Secret key MISSING: ${key}"
    fi
  done

  # ---- 2. Bronze table existence ------------------------------------------
  local full_table="${CATALOG}.${SCHEMA}.${BRONZE_TABLE}"
  local table_missing=false

  if databricks tables get "${full_table}" &>/dev/null; then
    ok "Table exists: ${full_table}"
  else
    warn "Table MISSING: ${full_table}"
    table_missing=true
  fi

  # ---- 3. Volume existence ------------------------------------------------
  local volumes_missing=false
  check_volumes || volumes_missing=true

  # ---- 4. Lakebase project status (informational) -------------------------
  check_lakebase_status

  # ---- 5. Evaluate results ------------------------------------------------

  # Auto-provisioned resources missing → platform bootstrap job hasn't been run
  if [[ ${#missing_auto[@]} -gt 0 ]] || [[ "${table_missing}" == true ]] || [[ "${volumes_missing}" == true ]]; then
    echo ""
    echo "  ============================================================="
    echo "  Auto-provisioned resources are missing."
    echo "  The platform bootstrap job must run before deploying the app."
    echo "  ============================================================="
    echo ""
    [[ ${#missing_auto[@]} -gt 0 ]] && echo "  Missing secret keys: ${missing_auto[*]}"
    [[ "${table_missing}" == true ]] && echo "  Missing table:       ${full_table}"
    [[ "${volumes_missing}" == true ]] && echo "  Missing volumes:     one or more of ${VOLUMES[*]}"
    echo ""
    echo "  Run the platform bootstrap job:"
    echo "    databricks bundle run ${PLATFORM_BOOTSTRAP_JOB} --target ${TARGET}"
    echo "    # or: ./deploy.sh --target ${TARGET} --run-setup"
    echo ""
    fail "Infrastructure readiness check failed (auto-provisioned resources missing)."
  fi

  # Admin-provisioned keys missing → admin action required
  if [[ ${#missing_admin[@]} -gt 0 ]]; then
    echo ""
    echo "  ============================================================="
    echo "  ACTION REQUIRED: Admin must provision OAuth client secrets."
    echo "  ============================================================="
    echo ""
    echo "  All auto-provisioned resources are present, but one or more"
    echo "  OAuth client secrets have not been stored in the secret scope."
    echo ""
    echo "  Missing keys: ${missing_admin[*]}"
    echo ""
    echo "  For the ZeroBus SPN (${CLIENT_SECRET_DBS_KEY}):"
    echo "    1. Generate OAuth secret: Workspace UI → Settings → Service principals"
    echo "       → select ZeroBus SPN → Secrets → Generate secret"
    echo "    2. Store it:"
    echo "       databricks secrets put-secret ${SCOPE_NAME} ${CLIENT_SECRET_DBS_KEY} \\"
    echo '         --string-value "<secret>"'
    echo ""
    echo "  For the Xcode SPN (${XCODE_CLIENT_SECRET_DBS_KEY}):"
    echo "    1. Generate OAuth secret: same flow for the Xcode SPN"
    echo "    2. Store it:"
    echo "       databricks secrets put-secret ${SCOPE_NAME} ${XCODE_CLIENT_SECRET_DBS_KEY} \\"
    echo '         --string-value "<secret>"'
    echo ""
    echo "  Use --skip-checks to deploy the app bundle without these keys."
    echo ""
    fail "Infrastructure readiness check failed (admin-provisioned secrets missing)."
  fi

  echo ""
  ok "All infrastructure readiness checks passed"
}

# --------------------------------------------------------------------------- #
# build_app_deploy_args — assemble --var overrides for the app bundle deploy
#                         from all resolved infrastructure values.
#
# Returns an array of arguments via the APP_DEPLOY_ARGS global variable.
# Only includes --var flags for non-empty resolved values.
# --------------------------------------------------------------------------- #
APP_DEPLOY_ARGS=()

build_app_deploy_args() {
  APP_DEPLOY_ARGS=()

  # Only pass --var for values that are TRULY DYNAMIC — discovered at runtime
  # and not known at YAML-write time. All other infra-derived values (catalog,
  # schema, warehouse ID, Lakebase IDs, SPN key names) are hardcoded as target
  # defaults in the app bundle's databricks.yml. The readiness checks above
  # already verified these match the deployed infra.
  #
  # This follows the dbxWearables pattern: the app bundle's target defaults
  # are the source of truth for static per-environment values. Only runtime-
  # discovered values (like SPN application_ids read from the secret scope)
  # are passed via --var.

  # Xcode SPN application_id — discovered from secret scope at deploy time.
  # Used for CAN_USE grant on the App (once wired into permissions block).
  [[ -n "${XCODE_SPN_ID}" ]] && APP_DEPLOY_ARGS+=(--var "xcode_spn_id=${XCODE_SPN_ID}")

  if [[ ${#APP_DEPLOY_ARGS[@]} -gt 0 ]]; then
    log "App bundle --var overrides:"
    for arg in "${APP_DEPLOY_ARGS[@]}"; do
      echo "    ${arg}"
    done
  else
    log "No --var overrides needed (all values from target defaults)"
  fi
}

# --------------------------------------------------------------------------- #
# resolve_app_name — extract the platform app name and source path from the
#                    app bundle summary. Called before deploy_app_source().
# --------------------------------------------------------------------------- #
resolve_app_name() {
  local bundle_dir="${SCRIPT_DIR}/${APP_BUNDLE}"

  log "Resolving app name from bundle summary"

  local summary_json
  summary_json=$(cd_bundle "${bundle_dir}" && databricks bundle summary --target "${TARGET}" --output json 2>/dev/null) || {
    fail "Could not read bundle summary for ${APP_BUNDLE}."
  }

  # Extract app name from resources.apps.app.name and workspace file path
  eval "$(echo "${summary_json}" | python3 -c "
import sys, json, re

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError as e:
    print(f'RESOLVE_ERROR=\"JSON parse error: {e}\"', flush=True)
    sys.exit(0)

def safe(v):
    return re.sub(r'[^a-zA-Z0-9_.\-]', '', str(v))

# App name from resources
app_name = ''
resources = data.get('resources', {})
apps_block = resources.get('apps', {})
for key, app in apps_block.items():
    if isinstance(app, dict) and app.get('name'):
        app_name = app['name']
        break

# Source code path: workspace file_path from bundle summary
# The bundle uploads source to {workspace.file_path} which is the
# root_path + /files directory.
workspace = data.get('workspace', {})
file_path = workspace.get('file_path', '')

print(f'APP_NAME=\"{safe(app_name)}\"')
# file_path contains the workspace files path (preserves slashes for path)
# Use safe_url-like approach for path
path_safe = re.sub(r'[^a-zA-Z0-9_.\-/@]', '', str(file_path))
print(f'APP_SOURCE_PATH=\"{path_safe}\"')
")" || fail "Could not parse app bundle summary."

  if [[ -n "${RESOLVE_ERROR:-}" ]]; then
    fail "App bundle summary parse error: ${RESOLVE_ERROR}"
  fi

  [[ -n "${APP_NAME}" ]] || fail "Could not resolve app name from app bundle summary."
  [[ -n "${APP_SOURCE_PATH}" ]] || fail "Could not resolve app source path from app bundle summary."

  ok "App name:        ${APP_NAME}"
  ok "Source path:     ${APP_SOURCE_PATH}"
}

# --------------------------------------------------------------------------- #
# deploy_app_source — ensure app compute is running, then deploy source code.
#
# Flow:
#   1. Check app status via `databricks apps get`
#   2. If STOPPED → start compute and wait for RUNNING
#   3. Deploy source from the bundle's workspace files path
#
# This step is separate from `bundle deploy` which only provisions the app
# resource (permissions, env vars, resources) but does NOT push source code
# to the container or start compute.
# --------------------------------------------------------------------------- #
deploy_app_source() {
  log "Deploying source code to app: ${APP_NAME}"

  # 1. Check current app status
  # NOTE: CLI uses positional arg for app name (not --name flag)
  local app_status
  app_status=$(databricks apps get "${APP_NAME}" --output json 2>/dev/null \
    | get_app_status) || app_status="UNKNOWN"

  echo "  Current app status: ${app_status}"

  # 2. If compute not ready, start it first
  if ! is_compute_ready "${app_status}"; then
    log "Starting app compute (status: ${app_status})"
    databricks apps start "${APP_NAME}" --no-wait 2>/dev/null || true

    # Poll for RUNNING state (max 5 minutes)
    local max_wait=300
    local elapsed=0
    local interval=10
    while [[ ${elapsed} -lt ${max_wait} ]]; do
      sleep ${interval}
      elapsed=$((elapsed + interval))
      app_status=$(databricks apps get "${APP_NAME}" --output json 2>/dev/null \
        | get_app_status) || app_status="UNKNOWN"
      echo "  [${elapsed}s] App status: ${app_status}"
      if is_compute_ready "${app_status}"; then
        break
      fi
      if [[ "${app_status}" == "FAILED" ]] || [[ "${app_status}" == "CRASHED" ]] || [[ "${app_status}" == "DELETING" ]]; then
        fail "App entered ${app_status} state. Check the Apps UI for details."
      fi
    done

    if ! is_compute_ready "${app_status}"; then
      fail "App compute did not reach ACTIVE state within ${max_wait}s (current: ${app_status})."
    fi
    ok "App compute is ready"
  else
    ok "App compute already ready"
  fi

  # 3. Deploy source code from bundle's workspace files path
  log "Pushing source to container (source: ${APP_SOURCE_PATH})"
  databricks apps deploy "${APP_NAME}" \
    --source-code-path "${APP_SOURCE_PATH}" \
    --no-wait || \
    fail "Source code deployment failed. Check the Apps UI for details."

  ok "Source deployment initiated for ${APP_NAME}"
  echo "  Monitor: databricks apps get ${APP_NAME}"
}

# --------------------------------------------------------------------------- #
# resolve_app_spn_id — discover the app's auto-provisioned SPN client_id
#                      from the Apps API after the app resource is registered.
#
# Sets APP_SPN_CLIENT_ID global variable. Non-fatal — warns on failure.
# --------------------------------------------------------------------------- #
resolve_app_spn_id() {
  if [[ -z "${APP_NAME}" ]]; then
    warn "APP_NAME not resolved — cannot look up app SPN."
    return 0
  fi

  log "Resolving app SPN client_id (app: ${APP_NAME})"

  local app_json
  app_json=$(databricks apps get "${APP_NAME}" --output json 2>/dev/null) || {
    warn "Could not retrieve app info for '${APP_NAME}'."
    warn "The app may not be registered yet."
    return 0
  }

  APP_SPN_CLIENT_ID=$(echo "${app_json}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('service_principal_client_id', ''))
except (json.JSONDecodeError, ValueError, KeyError):
    pass
" 2>/dev/null) || APP_SPN_CLIENT_ID=""

  if [[ -n "${APP_SPN_CLIENT_ID}" ]]; then
    ok "App SPN client_id: ${APP_SPN_CLIENT_ID:0:8}..."
  else
    warn "Could not resolve app SPN client_id."
    warn "Secret scope ACL step will be skipped."
  fi
}

# --------------------------------------------------------------------------- #
# run_configure_app_spn — run the configure_app_spn bundle job to ensure the
#                         app SPN has READ on the secret scope.
#
# Passes the resolved APP_SPN_CLIENT_ID as the "principal" notebook param.
# Idempotent — safe to run on every deploy (put_acl is an upsert).
# --------------------------------------------------------------------------- #
run_configure_app_spn() {
  if [[ -z "${APP_SPN_CLIENT_ID}" ]]; then
    warn "No app SPN client_id available — skipping secrets ACL step."
    return 0
  fi

  log "Ensuring app SPN has scope access (job: ${CONFIGURE_APP_SPN_JOB})"

  local bundle_dir="${SCRIPT_DIR}/${APP_BUNDLE}"
  (cd_bundle "${bundle_dir}" && databricks bundle run "${CONFIGURE_APP_SPN_JOB}" \
    --target "${TARGET}" \
    --params "principal=${APP_SPN_CLIENT_ID}") || {
    warn "Secrets ACL job failed. The app may not be able to read secrets."
    warn "You can re-run manually: databricks bundle run ${CONFIGURE_APP_SPN_JOB} --target ${TARGET} --params \"principal=${APP_SPN_CLIENT_ID}\""
    return 0  # Non-fatal — don't block deployment
  }
  ok "App SPN scope access configured"
}

# --------------------------------------------------------------------------- #
# run_post_deploy_validation — run the post-deploy validation job to verify
#                              all API endpoints are reachable and responding.
#
# Runs the notebook-based test suite via the bundle CLI. The notebook:
#   - Discovers app URL via SDK
#   - Tests all endpoints (health, pairing, captures, uploads)
#   - Raises AssertionError on any failure (job run shows as FAILED)
#
# Non-fatal — warns on failure but does not block deploy.sh exit.
# --------------------------------------------------------------------------- #
run_post_deploy_validation() {
  log "Running post-deploy validation (job: ${POST_DEPLOY_VALIDATION_JOB})"

  local bundle_dir="${SCRIPT_DIR}/${APP_BUNDLE}"
  (cd_bundle "${bundle_dir}" && databricks bundle run "${POST_DEPLOY_VALIDATION_JOB}" --target "${TARGET}") || {
    warn "Post-deploy validation FAILED. Check the job run for details."
    warn "Re-run manually: databricks bundle run ${POST_DEPLOY_VALIDATION_JOB} --target ${TARGET}"
    return 1
  }
  ok "Post-deploy validation passed — all endpoints responding"
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
log "lakeLoom — Bundle Deployment"
echo "  Target:        ${TARGET}"
echo "  Infra bundle:  ${DEPLOY_INFRA}"
echo "  App bundle:    ${DEPLOY_APP}"
echo "  Run setup:     ${RUN_SETUP}"
echo "  Skip checks:   ${SKIP_CHECKS}"
echo "  Skip validation: ${SKIP_VALIDATION}"
echo "  Validate only: ${VALIDATE_ONLY}"
echo "  Destroy:       ${DESTROY}"

# Step 1: Deploy infra bundle
if [[ "${DEPLOY_INFRA}" == true ]]; then
  deploy_bundle "${INFRA_BUNDLE}"
fi

# Step 2: Resolve infrastructure variables from infra bundle summary.
# MUST run immediately after infra deploy (FUSE still fresh). After bundle run
# (~2 min wait), FUSE directory handles go stale and cd fails with
# "Operation not permitted". The summary doesn't depend on the bootstrap job.
if [[ "${DEPLOY_APP}" == true ]] && [[ "${VALIDATE_ONLY}" != true ]] && [[ "${DESTROY}" != true ]]; then
  resolve_infra_vars
fi

# Step 3: Run platform bootstrap job (optional — creates SPNs, stores secrets,
#          creates table, grants volume access, validates platform)
if [[ "${RUN_SETUP}" == true ]] && [[ "${VALIDATE_ONLY}" != true ]] && [[ "${DESTROY}" != true ]]; then
  run_platform_bootstrap
fi

# Step 4: Verify infrastructure readiness (gate before app bundle deploy)
if [[ "${DEPLOY_APP}" == true ]] && [[ "${SKIP_CHECKS}" != true ]] && [[ "${VALIDATE_ONLY}" != true ]] && [[ "${DESTROY}" != true ]]; then
  verify_infra_readiness
  # Resolve Lakebase database ID (requires project to be deployed)
  resolve_lakebase_database
  # Read Xcode SPN application_id for app bundle
  read_xcode_spn_id
fi

# Step 5: Deploy app bundle
# Only xcode_spn_id is passed as --var (runtime-discovered).
# All other values use target defaults in the app bundle's databricks.yml.
if [[ "${DEPLOY_APP}" == true ]]; then
  build_app_deploy_args
  if [[ ${#APP_DEPLOY_ARGS[@]} -gt 0 ]]; then
    deploy_bundle "${APP_BUNDLE}" "${APP_DEPLOY_ARGS[@]}"
  else
    deploy_bundle "${APP_BUNDLE}"
  fi
fi

# Step 6: Configure app SPN and deploy source code
# After bundle deploy registers the app resource (permissions, env vars,
# resources), this step:
#   a) Resolves the app name + SPN client_id from the platform
#   b) Runs the configure_app_spn job to ensure scope READ access
#   c) Starts compute and triggers the source deployment
if [[ "${DEPLOY_APP}" == true ]] && [[ "${VALIDATE_ONLY}" != true ]] && [[ "${DESTROY}" != true ]]; then
  resolve_app_name
  resolve_app_spn_id
  run_configure_app_spn
  deploy_app_source
fi

# Step 7: Post-deploy validation — verify API endpoints are reachable
# Runs the test notebook as a job to confirm the app is serving correctly
# after source deployment. Non-fatal — warns but does not roll back.
if [[ "${DEPLOY_APP}" == true ]] && [[ "${VALIDATE_ONLY}" != true ]] && [[ "${DESTROY}" != true ]] && [[ "${SKIP_VALIDATION}" != true ]]; then
  run_post_deploy_validation
fi

log "Done."
