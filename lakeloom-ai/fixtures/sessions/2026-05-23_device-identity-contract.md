# 2026-05-23 — Device Identity Contract Implementation

## Summary

Implemented full server-side support for the `device_id` contract across all iOS→App endpoints, unblocking Isaac's PR 8a-2. Added migration 008, updated Zod schemas + route handlers, fixed ZeroBus column mapping incompatibility, and validated E2E with 6 records landing in Delta with device_id populated.

## Problems Addressed

1. **Isaac's multipart question** — how should `device_id` arrive on multipart upload routes?
2. **Server didn't accept device_id** — Zod schemas stripped unknown keys; Lakebase tables lacked the column.
3. **Test notebooks outdated** — didn't include `device_id`, `project_id`, or `event_time` in payloads.
4. **Column mapping incompatible with ZeroBus** — `delta.columnMapping.mode = 'name'` on `transcript_events_raw` caused Error 1015 on stream creation.
5. **device_name vs device_label naming inconsistency** — initial implementation used `device_name`, Lakebase convention is `device_label`.

## Root Causes

* Column mapping was enabled to support earlier column rename/drop work (`device_name → device_label → dropped`). ZeroBus streaming SDK doesn't support it.
* Zod's strict parsing (`.parse()`) strips unrecognized keys — `device_id` was silently dropped until schemas were extended.
* Initial naming assumed `device_name` without checking existing Lakebase convention.

## Key Decisions

| Decision | Rationale |
|----------|-----------|
| `device_id` as sibling multipart form field (option a) | Natural extension of existing shape; `req.body.device_id` after busboy parsing |
| All Zod schemas `.optional()` | Backward compatible until PR 8a-2 ships on iOS |
| Nullable DB columns (no NOT NULL) | Existing iOS builds continue working unchanged |
| `device_label` only in `paired_sessions` | Single source of truth; other tables join via `device_id` |
| No column mapping on ZeroBus targets | Streaming ingestion SDK limitation; recreate table if mapping enabled |

## Changes

### Migration 008 (`server/migrations/008_device_id.ts`)

```sql
ALTER TABLE app.paired_sessions ADD COLUMN device_id UUID;
ALTER TABLE app.capture_sessions ADD COLUMN device_id UUID;
ALTER TABLE app.uploads ADD COLUMN device_id UUID;
-- + indexes on each
```

### Route Handler Updates

| File | Change |
|------|--------|
| `server/routes/pairing/pairing-routes.ts` | `ConfirmBody` Zod + UPDATE persists device_id |
| `server/routes/captures/capture-routes.ts` | `CreateCaptureBody` Zod + INSERT includes device_id |
| `server/routes/uploads/upload-routes.ts` | Busboy captures `device_id` field; INSERT as `$13::uuid` |

### Test Notebooks

| Notebook | Cells Changed | What |
|----------|---------------|------|
| `validate-zerobus-ingest` | 3.5, 3.6 | device_id, project_id, event_time on all events |
| `upload-trigger-test` | 4 cells | device_id on confirm, capture create, audio upload |
| `pairing-api-test` | Tests 4, 10 | device_id in confirm body |

### DDL Fix

| File | Change |
|------|--------|
| `stt-0bus-target-table-ddl.ipynb` (lakeloom-infra) | Removed `'delta.columnMapping.mode' = 'name'` |
| `transcript_events_raw` (live) | Dropped + recreated without column mapping; re-granted SPN |

### Architecture Notes

| File | Purpose |
|------|---------|
| `hey_isaac/2026-05-23_multipart-device-id-answer.md` | Confirmed option (a) for multipart device_id |

## Verification

| Check | Result |
|-------|--------|
| Migration 008 applied | OTel: `[migrations] Applied: 008_device_id` |
| validate-zerobus-ingest 3.5 (single event) | 202 Accepted, record landed with device_id |
| validate-zerobus-ingest 3.6 (5-event batch) | 202 Accepted, 5 records with device_id + event_time |
| Total records in Delta | 6, all columns populated |
| ZeroBus pool cold-start | 0→1 stream, healthy |

## Commits (branch: `mg-respond-to-isaac`)

| Hash | Message |
|------|---------|
| `7108df5` | test: add device_id, project_id, event_time to test payloads |
| `9511940` | hey_isaac: confirm multipart device_id as sibling form field (option a) |
| `7a7d5a3` | feat: server-side device_id acceptance on all iOS endpoints |
| `3b3b436` | fix: remove delta.columnMapping.mode from transcript_events_raw DDL |

## Files Modified

```
lakeloom-ai/server/migrations/008_device_id.ts (new)
lakeloom-ai/server/migrations/migrate.ts (modified)
lakeloom-ai/server/routes/pairing/pairing-routes.ts (modified)
lakeloom-ai/server/routes/captures/capture-routes.ts (modified)
lakeloom-ai/server/routes/uploads/upload-routes.ts (modified)
lakeloom-ai/src/tests/pairing-api-test.ipynb (modified)
lakeloom-ai/src/tests/upload-trigger-test.ipynb (modified)
lakeloom-ai/src/tests/validate-zerobus-ingest.ipynb (modified)
lakeloom-infra/src/platform_bootstrap/stt-0bus-target-table-ddl.ipynb (modified)
architecture/hey_isaac/2026-05-23_multipart-device-id-answer.md (new)
```

## Next Steps (pending Isaac's PR 8a-2)

* No server changes needed — handlers already accept device_id
* After PR merges: verify device_id populates in Lakehouse Sync tables (`lb_paired_sessions_history`, etc.)
* Consider follow-up migration: `ALTER TABLE ... ALTER COLUMN device_id SET NOT NULL` once all clients confirmed
* Debounce `last_seen_at` heartbeat churn (526 update pairs observed in paired_sessions)
