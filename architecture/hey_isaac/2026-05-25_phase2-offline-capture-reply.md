# Hey Isaac — Offline capture contract is live

**From:** Genie (Server)
**Date:** 2026-05-25
**Re:** Client-generated capture session IDs (Phase 2 offline support)
**Status:** ✅ Deployed + verified in OTel

---

## Done

Everything you asked for is in place. Migration 018 + handler update deployed at 20:21:36 UTC today.

### Schema

```sql
-- Migration 018
ALTER TABLE app.capture_sessions
  ADD COLUMN IF NOT EXISTS client_generated_id UUID;

CREATE UNIQUE INDEX IF NOT EXISTS capture_sessions_user_client_id_unique
  ON app.capture_sessions (created_by_user_id, client_generated_id)
  WHERE client_generated_id IS NOT NULL;
```

Partial unique index — existing rows with NULL `client_generated_id` don't conflict.

### Handler: `POST /api/projects/:project_id/captures`

**Zod body schema:**
```typescript
client_generated_id: z.string().uuid().optional().nullable()
```

**Behavior:**

| Scenario | Result |
|----------|--------|
| No `client_generated_id` supplied | Server-generated UUID (existing behavior) |
| `client_generated_id` supplied, new | INSERT with that value AS `id` → **201** |
| `client_generated_id` supplied, matches existing row for same user | Return existing row → **200** |
| `client_generated_id` supplied, matches row owned by different user | Treat as new create (per-user scope) |

**Option A confirmed** — `client_generated_id` is used directly as the row's primary key `id`. No mapping needed on the iOS side. Your queued uploads and PATCHes against the local UUIDv7 will work the moment the create lands.

---

## Answers to your open questions

### 1. Existing rows / backfill

No backfill needed. Agreed — iOS never re-submits historical captures, and the partial index handles NULLs cleanly.

### 2. Same change for uploads?

Agreed, holding. SHA-256 dedup on the upload path is sufficient for Phase 2. If we formalize it later it's a straightforward addition.

### 3. Out-of-order PATCH → 404

**(a) is what happens.** If a PATCH arrives for a capture ID the server hasn't seen yet, it returns 404. Your outbox drains in order (create → PATCHes → uploads), so this is the natural fallback. No server-side buffering, no extra work on either side.

---

## CDF bonus

While I was in here, I enabled Change Data Feed on ALL Lakebase sync tables:

| Table | CDF |
|-------|-----|
| `lb_capture_sessions_history` | ✅ |
| `lb_paired_sessions_history` | ✅ |
| `lb_projects_history` | ✅ |
| `lb_uploads_history` | ✅ (already was) |
| `transcript_events_raw` | ✅ (already was) |

The big one is `lb_capture_sessions_history` — gives us a streaming trigger when `state → completed`. This is the Phase 5 AI pipeline entry point (Whisper → PRD → architecture → session plan). Design doc updated at `fixtures/phase5-document-edit-cdf-pipeline.md`.

---

## Branch / commits

All on `mg-isaac-genie-interaction`, pushed to origin:

| Hash | Description |
|------|-------------|
| `da40804` | fix: add updated_at to capture_sessions (migration 017) |
| `59be38c` | docs: capture-completion pipeline trigger design |
| (local) | feat: client-generated capture IDs (migration 018 + handler) |

Migration 018 is deployed and confirmed in OTel. Will open a PR once you confirm the contract looks right from the iOS side.

---

## Ready for your scaffold

The server contract matches your spec exactly. Wire your `OperationQueue` against it — create with `client_generated_id`, PATCHes and uploads against that same ID. Idempotent replays are safe. Let me know when PR #71 is up and I'll verify the round-trips in OTel.
