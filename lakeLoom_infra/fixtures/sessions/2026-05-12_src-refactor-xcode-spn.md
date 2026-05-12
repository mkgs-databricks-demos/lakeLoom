# 2026-05-12 — Source Refactor & Xcode SPN

## Summary

Complete reorganization of `src/platform_bootstrap/` from ad-hoc scripts to a clean NOTEBOOK + shared-library architecture, addition of the Xcode SPN for iOS app authentication, and resolution of the secret scope ACL design question.

## Problems Encountered

1. **Naming collision**: `src/lib/secrets.py` shadowed Python stdlib `secrets` module at runtime → `ImportError` on first job run.
2. **NOTEBOOK vs FILE resolution**: `.sql` extension in job YAML only resolves FILE objects (literally named `*.sql`), not NOTEBOOK objects. Bundle validation failed until all paths changed to `.ipynb`.
3. **Workspace move API disabled**: Could not rename notebooks via REST API; used export/delete/re-import pattern instead.
4. **Wrong cell matched during programmatic edit**: `ensure_scope_read_acl` string appeared in both the import cell and the ACL cell; first match was the imports cell. Required a second pass to fix both correctly.

## Root Causes

1. Python module naming: `secrets` is a stdlib module in Python 3.6+.
2. Databricks workspace API resolves NOTEBOOK objects by name (without extension); `.sql` extension only matches FILE objects with that literal filename.
3. Workspace move endpoint not enabled on this workspace.
4. Naive string search matched the first occurrence rather than the semantic target.

## Changes Made

### Deleted
* `resources/uc_setup.job.yml` (empty legacy file)
* `src/platform_bootstrap/ensure-service-principal.py` (standalone script)
* `src/platform_bootstrap/ensure-service-principal` (thin .ipynb wrapper, FILE type)
* `src/platform_bootstrap/ensure_service_principal_lib.py` (empty)
* `src/platform_bootstrap/transcript-events-raw-ddl.sql` (superseded)
* `src/platform_bootstrap/transcript-events-raw-ddl-notebook` (NOTEBOOK, replaced)
* `src/platform_bootstrap/validate-platform.sql` (FILE, replaced)

### Created
* `src/lib/__init__.py`
* `src/lib/workspace_metadata.py` — get_workspace_id(), get_region(), get_zerobus_endpoint()
* `src/lib/service_principal.py` — get_or_create_service_principal(), verify_client_credentials()
* `src/lib/secret_scope.py` — put_secret(), list_secret_keys(), ensure_scope_read_acl(), try_get_secret_value()
* `src/platform_bootstrap/ensure-service-principal` — NOTEBOOK (Python), 12 cells
* `src/platform_bootstrap/stt-0bus-target-table-ddl` — NOTEBOOK (SQL), 14 cells
* `src/platform_bootstrap/validate-platform` — NOTEBOOK (SQL), 7 cells
* `src/admin_actions/set-databricks-secrets` — cloned from helper-notebooks
* `src/admin_actions/update-secrets-acls` — cloned from helper-notebooks
* `fixtures/sessions/` directory

### Modified
* `resources/platform_bootstrap.job.yml` — new notebook paths (.ipynb for all), added xcode params, convention comments
* `databricks.yml` — added `xcode_client_id_dbs_key`, `xcode_client_secret_dbs_key` variables + per-target overrides
* `PROJECT_MEMORY.md` — full rewrite reflecting current state

## Decisions

1. **No plain .sql files outside SDP** — all SQL logic in SQL-default NOTEBOOK objects.
2. **All notebook_path refs use .ipynb** — `warehouse_id` alone determines SQL compute routing.
3. **src/lib/ for reusable functions** — notebooks import via `sys.path.insert(0, lib_path)`.
4. **Two SPNs**: ZeroBus (data-plane) + Xcode (App API). Neither gets READ on the secret scope.
5. **App SPN gets scope READ** — managed by companion App bundle or admin_actions notebooks.
6. **Named `secret_scope.py`** not `secrets.py` — avoids stdlib collision.
7. **Admin actions** are manual-run notebooks cloned from `matthew-giglia/databricks-helper-notebooks`.

## Deployment Status

* `bundle validate --strict --target dev` ✓
* `bundle deploy --target dev` ✓
* `bundle run platform_bootstrap --target dev` ✓ (all 3 tasks SUCCEEDED)
