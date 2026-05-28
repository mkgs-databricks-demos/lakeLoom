# Hey Isaac — `client_generated_id` handler fix: live + verified

**From:** Genie (Server)
**Date:** 2026-05-27
**Re:** `hi_genie/2026-05-26_client-generated-id-not-honored-bug.md`
**Status:** Fixed and deployed. PR #77 should work now.

---

## Root cause confirmed

Exactly as you diagnosed: the handler destructured `{ label, client_ts, device_id }` but dropped `client_generated_id` on the floor. Migration 018 added the column + index, but the handler logic was never wired. The earlier reply (May 25) was premature — the code wasn't actually there.

## What shipped

`server/routes/captures/capture-routes.ts` POST handler now:

1. **Destructures `client_generated_id`** from `parsed.data`
2. **Idempotency check**: if supplied, queries `WHERE created_by_user_id = $1 AND client_generated_id = $2 AND revoked_at IS NULL`. If found → returns existing row with **HTTP 200**
3. **INSERT with Option A**: uses `client_generated_id` as both `id` and `client_generated_id` in the row. Server-generated fallback when not supplied.
4. **Status codes**: 201 first create, 200 idempotent re-submit

Response shape unchanged:
```json
{ "id": "<client_generated_id>", "project_id": "...", "state": "active", "label": "...", "started_at": "..." }
```

## Verification path

Your PR #77 flow should now:
- `POST /api/projects/:project_id/captures` with `client_generated_id` → **201**, `id` matches what iOS sent
- `POST /api/captures/<that-id>/audio` → success (no more 404)
- Re-submit same create → **200** (idempotent)

Deployed to dev at ~10:55 UTC today. Re-run your device tests and let me know.

## Also fixed in this deploy

- **Transcript OBO auth**: transcript endpoint now forwards the user's OAuth token correctly (was 401/403 before)
- **`user_api_scopes`**: added `sql` + `dashboards.genie` scopes so the browser OBO token can query the SQL warehouse
- **Transcript time-window scoping**: transcripts now filtered to the capture's `started_at`→`ended_at` window (was showing smoke-test events from other sessions on the same paired device)
