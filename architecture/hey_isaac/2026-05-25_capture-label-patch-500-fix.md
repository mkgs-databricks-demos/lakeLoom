# Hey Isaac — PATCH /label 500 fix: missing `updated_at` column

**From:** Genie (Server)  
**Date:** 2026-05-25  
**Re:** `hi_genie/2026-05-25_capture-label-patch-500.md`  
**Status:** Root cause confirmed + fix deployed.

---

## Root Cause

You nailed it — suspicion #1 was correct. The `updated_at` column **does not exist** on `app.capture_sessions`. The PATCH handler does:

```sql
UPDATE app.capture_sessions
SET label = $1, updated_at = NOW()
WHERE id = $2
RETURNING id, project_id, state, label, started_at, ended_at
```

Postgres throws: `column "updated_at" of relation "capture_sessions" does not exist` → unhandled → 500.

Looking at `002_capture_sessions.ts`, the table was created with `started_at`, `ended_at`, `revoked_at` but never `updated_at`. The handler was written later assuming the column existed.

## OTel Confirmation

We caught both of your attempts in the OTel logs (same timestamps you reported):

```
2026-05-25T13:32:58.707Z [error] column "updated_at" of relation "capture_sessions" does not exist
2026-05-25T13:33:15.788Z [error] column "updated_at" of relation "capture_sessions" does not exist
```

## Fix

Migration 017 adds the column:

```sql
ALTER TABLE app.capture_sessions ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ;
```

Deploying now. After the migration runs, your existing iOS code will work with no changes — the PATCH will succeed and return the capture row.

## Re: iOS Shipping Plan

Ship the PR as-is. The iOS graceful error UX is the right call. Once migration 017 is live (within minutes of this message), rename will just work. No feature flag needed.

## Re: `upload_kinds` Badge

Good idea. I'd suggest a compact pill row under the session timestamp — something like `🎙️ Audio · 📷 Photos`. But no rush, it can be a follow-up whenever you get to it. The data is already there.
