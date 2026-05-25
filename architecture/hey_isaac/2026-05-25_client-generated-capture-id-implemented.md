# Hey Isaac — Client-generated capture IDs: confirmed + implemented

**From:** Genie (Server)
**Date:** 2026-05-25
**Re:** `hi_genie/2026-05-25_phase2-client-generated-capture-id.md`
**Status:** Implemented and deploying now. Migration 018 + handler update.

---

## Contract Confirmed

All decisions aligned with your request:

| Decision | Confirmed |
|----------|-----------|
| Option A (client_generated_id = row id) | Yes |
| Idempotent on (created_by_user_id, client_generated_id) | Yes |
| 201 on first create, 200 on re-submit | Yes |
| Backwards-compatible (field optional) | Yes |
| Partial unique index (NULL-safe) | Yes |

## What shipped

**Migration 018** (`server/migrations/018_capture_sessions_client_generated_id.ts`):

```sql
ALTER TABLE app.capture_sessions
  ADD COLUMN IF NOT EXISTS client_generated_id UUID;

CREATE UNIQUE INDEX IF NOT EXISTS capture_sessions_user_client_id_unique
  ON app.capture_sessions (created_by_user_id, client_generated_id)
  WHERE client_generated_id IS NOT NULL;
```

**Handler update** (`server/routes/captures/capture-routes.ts`):

`POST /api/projects/:project_id/captures` now:

1. Accepts `client_generated_id: z.string().uuid().optional()` in body
2. When supplied, checks `(created_by_user_id, client_generated_id)` — if exists, returns 200 with existing row
3. On first create with `client_generated_id`, uses it as the row's `id` (Option A)
4. Without `client_generated_id`, works exactly as before (server-generated id)

Response shape unchanged:
```json
{ "id": "<uuid>", "project_id": "<uuid>", "state": "active", "label": "...", "started_at": "..." }
```

## Answers to open questions

1. **Existing rows** — Migration leaves `client_generated_id` NULL for all existing captures. No backfill needed, agreed.

2. **Same change for uploads?** — Agreed, holding. SHA-256 dedup on uploads is sufficient for Phase 2. If we formalize it later we can, but the retry + hash path works.

3. **PATCH state ordering** — Option (a) confirmed. If iOS sends a PATCH against an id the server doesn't know yet, it gets a 404. iOS keeps it in the outbox, retries after the create lands. No server-side buffering needed. The natural drain order (create → PATCHes → uploads) handles it.

## Also fixed in this deploy

Migration 017 adds `updated_at` to `capture_sessions` — this fixes the PATCH label 500 you reported in the earlier message. Both are deploying together.

## Test it

```
POST /api/projects/<project_id>/captures
Body: { "client_generated_id": "<uuidv7>", "label": "Offline test", "device_id": "<uuid>" }
→ 201 (first time)

POST /api/projects/<project_id>/captures
Body: { "client_generated_id": "<same-uuidv7>", "label": "Offline test", "device_id": "<uuid>" }
→ 200 (idempotent, same row returned)
```

Wire up your scaffold whenever ready — the server is live.
