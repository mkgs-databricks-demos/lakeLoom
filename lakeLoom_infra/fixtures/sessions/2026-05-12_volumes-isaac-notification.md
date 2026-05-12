# 2026-05-12 — New Volumes, Isaac Notification, Volume Grants & forEach Task

## Summary

Added `screenshots` and `documents` managed UC Volumes to the infra bundle, notified Isaac of upload endpoint expectations, then created a `grant-volume-access` notebook with a forEach job task to apply READ_VOLUME + WRITE_VOLUME to the ZeroBus SPN across all three volumes. Extended `validate-platform` with grant assertions using `information_schema.volume_privileges`.

## Problems Encountered

1. **Edit scope restriction**: `editAsset` is scoped to `lakeLoom_infra/`; the `hey_isaac/` folder needed to live at `lakeLoom/architecture/hey_isaac/` (sibling to `hi_genie/`). Required navigating to the file for a remote write.
2. **Orphan folders**: Iterating on the `hey_isaac/` location created orphan directories at `lakeLoom/hey_isaac/` and `lakeLoom_infra/hey_isaac/` before landing on the correct path. Both were cleaned up.
3. **SHOW GRANTS not queryable**: `CREATE VIEW AS SHOW GRANTS` and `SELECT * FROM (SHOW GRANTS ...)` both fail with `PARSE_SYNTAX_ERROR`. SHOW commands cannot be used as table sources in Databricks SQL.
4. **Solution**: Query `information_schema.volume_privileges` (available since DBR 13.3 / Unity Catalog) — a proper system table that supports standard SQL WHERE/COUNT/CTE patterns.

## Root Causes

1. Notebook edit context restricts file writes to the bundle root; cross-project writes require navigation or SDK calls.
2. Multiple creation attempts before confirming where `hi_genie/` actually lives (`architecture/` subfolder, not project root).
3. Databricks SQL SHOW commands are statement-level only — they return result sets to the caller but cannot participate in DDL or DML as subqueries, view sources, or table expressions.

## Changes Made

### Created
* `resources/screenshots.volume.yml` — MANAGED volume for session screen captures (PNG)
* `resources/documents.volume.yml` — MANAGED volume for project-level documents
* `src/platform_bootstrap/grant-volume-access` — SQL notebook (10 cells), forEach target: grants READ_VOLUME + WRITE_VOLUME via EXECUTE IMMEDIATE
* `lakeLoom/architecture/hey_isaac/2026-05-12_new-upload-volumes.md` — Isaac notification

### Modified
* `resources/session_audio.volume.yml` — added comment reflecting App-proxy upload pattern (ADR-001)
* `resources/platform_bootstrap.job.yml` — added `grant_volume_access` forEach task (concurrency 3), added `spn_application_id` param to `validate_platform` task, updated task descriptions and comments
* `src/platform_bootstrap/validate-platform` — added 4 cells (SPN param + 3 volume grant assertions via `information_schema.volume_privileges`); updated header and summary cell; now 13 cells total
* `PROJECT_MEMORY.md` — updated project structure, current status (4 tasks), ZeroBus SPN permissions, Platform Bootstrap Job section, added Technical Notes, added Phase 7, updated ADR-001 ownership table
* `.assistant_instructions.md` — updated collaboration folder convention

### Deleted
* `lakeLoom_infra/hey_isaac/` (orphan — wrong location)
* `lakeLoom/hey_isaac/` (orphan — wrong location)

## Decisions

1. **`hey_isaac/` lives at `lakeLoom/architecture/hey_isaac/`** — sibling to `hi_genie/`, NOT inside any bundle directory.
2. **WRITE_VOLUME grants are dual**: infra grants ZeroBus SPN access (for server-side operations); App bundle grants its own SPN access (for proxied iOS uploads).
3. **Filename conventions TBD** — awaiting Isaac's response on timestamps vs UUIDs.
4. **forEach task pattern**: Static JSON array input (`'["session_audio", "screenshots", "documents"]'`), concurrency 3, `{{input}}` reference in base_parameters.
5. **Grant validation via information_schema**: Never use `SHOW GRANTS` for programmatic assertions in Databricks SQL. Use `information_schema.volume_privileges` instead.
6. **Volume path conventions**:
   - Screenshots: `/Volumes/{catalog}/{schema}/screenshots/{project_id}/{session_id}/{filename}.png`
   - Documents: `/Volumes/{catalog}/{schema}/documents/{project_id}/{filename}.{ext}`
   - Audio: `/Volumes/{catalog}/{schema}/session_audio/{project_id}/{session_id}/{filename}.wav`

## Deployment Status

* `bundle validate --strict --target dev` ✓ (3 runs)
* `bundle deploy --target dev` ✓ (3 deploys)
* `bundle run platform_bootstrap --target dev` ✓ (final run: all 4 tasks SUCCEEDED)
* Failed runs (fixed):
  * Run 1: `CREATE VIEW AS SHOW GRANTS` → `PARSE_SYNTAX_ERROR` at `SHOW`
  * Run 2: `SELECT * FROM (SHOW GRANTS ...)` → `PARSE_SYNTAX_ERROR` at `ON`
  * Run 3 (final): `information_schema.volume_privileges` approach → SUCCESS

## Files Modified

| File | Action |
| --- | --- |
| `resources/screenshots.volume.yml` | Created |
| `resources/documents.volume.yml` | Created |
| `resources/session_audio.volume.yml` | Updated (comment) |
| `resources/platform_bootstrap.job.yml` | Updated (forEach task, spn_application_id param) |
| `src/platform_bootstrap/grant-volume-access` | Created (10-cell SQL notebook) |
| `src/platform_bootstrap/validate-platform` | Updated (4 new cells, header/summary) |
| `PROJECT_MEMORY.md` | Updated |
| `lakeLoom/architecture/hey_isaac/2026-05-12_new-upload-volumes.md` | Created |
| `.assistant_instructions.md` | Updated |
