# 2026-05-12 — New Volumes & Isaac Notification

## Summary

Added `screenshots` and `documents` managed UC Volumes to the infra bundle, extended the `validate-platform` notebook with assertion cells for both, deployed to dev, ran the platform bootstrap job successfully, and notified Isaac of the new upload endpoint expectations.

## Problems Encountered

1. **Edit scope restriction**: `editAsset` is scoped to `lakeLoom_infra/`; the `hey_isaac/` folder needed to live at `lakeLoom/architecture/hey_isaac/` (sibling to `hi_genie/`). Required navigating to the file for a remote write.
2. **Orphan folders**: Iterating on the `hey_isaac/` location created orphan directories at `lakeLoom/hey_isaac/` and `lakeLoom_infra/hey_isaac/` before landing on the correct path. Both were cleaned up.

## Root Causes

1. Notebook edit context restricts file writes to the bundle root; cross-project writes require navigation or SDK calls.
2. Multiple creation attempts before confirming where `hi_genie/` actually lives (`architecture/` subfolder, not project root).

## Changes Made

### Created
* `resources/screenshots.volume.yml` — MANAGED volume for session screen captures (PNG)
* `resources/documents.volume.yml` — MANAGED volume for project-level documents
* `lakeLoom/architecture/hey_isaac/2026-05-12_new-upload-volumes.md` — Isaac notification: volume paths, proposed App endpoints, WRITE_VOLUME grant expectations, filename convention questions

### Modified
* `resources/session_audio.volume.yml` — added comment reflecting App-proxy upload pattern (ADR-001)
* `src/platform_bootstrap/validate-platform` — added cells 6 & 7 (screenshots + documents volume assertions); updated markdown header (cell 1) and summary cell (cell 9) to include all 3 volumes
* `PROJECT_MEMORY.md` — updated collaboration conventions (explicit `architecture/hey_isaac/` path), added Isaac notification record, added Phase 6 to plan status, marked Next Steps Isaac bullet as done
* `.assistant_instructions.md` — updated collaboration folder convention to specify `lakeLoom/architecture/` location

### Deleted
* `lakeLoom_infra/hey_isaac/` (orphan — wrong location)
* `lakeLoom/hey_isaac/` (orphan — wrong location)

## Decisions

1. **`hey_isaac/` lives at `lakeLoom/architecture/hey_isaac/`** — sibling to `hi_genie/`, NOT inside any bundle directory.
2. **WRITE_VOLUME grants are App-bundle responsibility** — infra creates the volumes; the App bundle grants its own SPN write access.
3. **Filename conventions TBD** — awaiting Isaac's response on timestamps vs UUIDs for upload filenames.
4. **Volume path conventions**:
   - Screenshots: `/Volumes/{catalog}/{schema}/screenshots/{project_id}/{session_id}/{filename}.png`
   - Documents: `/Volumes/{catalog}/{schema}/documents/{project_id}/{filename}.{ext}`
   - Audio: `/Volumes/{catalog}/{schema}/session_audio/{project_id}/{session_id}/{filename}.wav`

## Deployment Status

* `bundle validate --strict --target dev` ✓
* `bundle deploy --target dev` ✓
* `bundle run platform_bootstrap --target dev` ✓ (all 3 tasks SUCCEEDED, including new volume assertions)

## Files Modified

| File | Action |
| --- | --- |
| `resources/screenshots.volume.yml` | Created |
| `resources/documents.volume.yml` | Created |
| `resources/session_audio.volume.yml` | Updated (comment) |
| `src/platform_bootstrap/validate-platform` | Updated (2 new assertion cells + header/summary) |
| `PROJECT_MEMORY.md` | Updated |
| `lakeLoom/architecture/hey_isaac/2026-05-12_new-upload-volumes.md` | Created |
