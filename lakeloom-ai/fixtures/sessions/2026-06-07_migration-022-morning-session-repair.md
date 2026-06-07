# Migration 022 — Morning Session Repair

**Date:** 2026-06-07  
**Branch:** `mg-genie-chunked-recording-server`  
**Commits:** `1e37055` (migration fix), `78a9da1` (Isaac reply — subsequently amended)

---

## Problem

Session `019e8881-6525-7104-a83f-31b2893730bd` was missing from dev Lakebase. iOS was retrying a batch of morning audio chunks against this session ID and receiving `404 UPLOAD_CAPTURE_NOT_FOUND` in a continuous loop, first observed at 11:16 UTC on June 6.

---

## Root Cause

**This is the iOS recovery bug Isaac was probing for.** Session `019e8881` was never created server-side — there is no record of a `createCaptureSession` API call for this ID at any point. No attempt logged, nothing in Lakehouse Sync, no OTel event. iOS generated the UUID client-side, but the session creation call either was never made or never reached the server (device offline at session start, app crash before the call, network failure without retry). When iOS's audio upload retry queue later fired, it uploaded against a session ID that had never been registered.

This confirms the discriminator Isaac asked about: **not dev-DB churn, but a real iOS recovery gap** — iOS re-queues audio uploads in its recovery path without first ensuring `createCaptureSession` succeeded.

Dev Lakebase was NOT wiped. The zero rows in Lakehouse Sync are explained by the session never having existed, not by a deletion.

---

## Fix: Migration 022

One-time repair: insert the orphaned session row idempotently so iOS's queued uploads can drain.

```sql
INSERT INTO app.capture_sessions (...)
VALUES ('019e8881-...'::uuid, ...)
ON CONFLICT (id) DO NOTHING
```

Values mirrored from afternoon session `019e89b4` (same project, user, device). This is a retroactive rescue, not a systemic fix — the iOS recovery path still needs to be hardened to re-ensure session creation before upload retry.

---

## Deploy Attempts — Three Failures Before Landing

### Attempt 1 — 11:35 UTC — TS Build Error

The repair notebook generated `022_repair_morning_session.ts` with the wrong export pattern:

```typescript
// WRONG — AppKit function signature, not this project's pattern
import type { Sql } from "@databricks/appkit";
export async function up(sql: Sql): Promise<void> { ... }
```

This project's migration format is a plain `{ name: string, up: string }` object (see `migrate.ts`). TypeScript rejected the `Sql` import: `error TS2724: '@databricks/appkit' has no exported member named 'Sql'`.

**Fix:** Rewrote to `export const migration022: Migration = { name, up: '...' }` with `import type { Migration } from './migrate'`.

### Attempt 2 — 12:27 UTC — Runtime Migration Failure

Build succeeded. Migration ran but failed at startup:

```
[migrations] FAILED: 022_repair_morning_session
error: syntax error at or near "$" (position 796)
```

Root cause: a `DO $$ BEGIN RAISE NOTICE ... END; $$;` logging block. `pg-pool` interprets bare `$` characters as positional parameter placeholders (`$1`, `$2`, ...) even inside dollar-quoted strings.

**Key finding:** The migration runner catches the failure and lets the server start anyway — app serves 404s rather than crashing. The `_migrations` table does NOT record a failed migration, so it retries on the next deploy.

**Fix:** Removed the `DO $$` block entirely. The runner already logs `[migrations] Applied: <name>` on success.

### Attempt 3 — 14:32 UTC — Clean

Single `INSERT ... ON CONFLICT (id) DO NOTHING`. No `$` characters anywhere. Build and migration both succeeded:

```
[migrations] Applying: 022_repair_morning_session
[migrations] Applied: 022_repair_morning_session
[migrations] Applied 1 migration(s).
[appkit:server] Server running on http://0.0.0.0:8000
```

---

## Verification

OTel confirmed all clear within 6 minutes of server start:

| Metric | Value |
|---|---|
| Chunks received | 22 |
| Status codes | 22 × 201 (zero 404s) |
| Chunk range | `chunk0` → `chunk21`, contiguous, no gaps |
| Final chunk | `chunk21` = 4.6 MB (all others ~8.5 MB) |
| Total audio | ~183 MB |
| Upload burst | 14:39:02 → 14:39:44 UTC (42 sec) |
| Filenames | `audio-20260602T132401-chunk{n}.m4a` |

Note: `started_at` in the migration was set to `2026-06-02T09:20:00Z` (estimate). Actual recording start from chunk filenames: ~13:24 UTC = 09:24 EDT. Cosmetically off, functionally irrelevant.

---

## Observability Notes

- **OTel lag is ~2 minutes**, not 30-40 min as initially assumed. Earlier apparent lag was the app's cold-start period, not pipeline latency.
- **Lakehouse Sync for `lb_uploads_history` is weeks behind** — latest LSN `93765464` from 2026-05-25. Use OTel `metadata.insert_succeeded` events for real-time upload verification instead.
- **VARIANT path extraction** (`:field_name`) on OTel body doesn't work for string-encoded JS-style log bodies. Use `regexp_extract(body::string, ...)` for field parsing.

---

## Migration Format Reference (this project)

```typescript
// Correct pattern — always this shape
import type { Migration } from './migrate';

export const migration0NN: Migration = {
  name: '0NN_description',
  up: `
    -- plain SQL, no $-based constructs, no DO $$ blocks
    -- multiple statements OK (semicolons between)
  `,
};
```

**Never use:**
- `async function up(sql: Sql)` — AppKit v2 pattern, not used here
- `DO $$` or any `$`-delimited construct — pg-pool param placeholder collision
- Trailing semicolon on the last statement is optional but harmless

---

## Files Modified

| File | Change |
|---|---|
| `server/migrations/022_repair_morning_session.ts` | Fixed: correct `Migration` export format, removed `DO $$` block, escaped apostrophe (`''`) |
| `architecture/hey_isaac/2026-06-06_morning-session-repair-complete.md` | New: reply to Isaac — updated to reflect iOS recovery bug root cause |

---

## Isaac Coordination

Isaac's note asked two questions:
1. Was dev Lakebase wiped? **No.** Session was never created server-side — iOS recovery gap, not DB churn.
2. Was the session reconstructed? **Yes — migration 022, deployed 14:32 UTC June 6.**

Isaac's instinct was correct. `createCaptureSession` needs to be part of the iOS recovery/retry path — not just audio upload re-queuing. This is a systemic iOS fix needed on his side.

Reply written to `hey_isaac/2026-06-06_morning-session-repair-complete.md` and pushed.

Branch is ready for Isaac's `chunkDuration` flip and Phase B bake-test whenever he is.
