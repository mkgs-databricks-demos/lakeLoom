# Session: Phase 6 Transcript Auth + Phase 2 Handler Wiring

**Date:** 2026-05-27
**Branch:** `mg-phase6-transcript-viewer`
**Commit:** `f1e57a0`

---

## Problems Identified

1. **Transcript endpoint returning 500 (was 401, then 403):**
   - Initial: `sql-service` never received an auth token → 401 from Statement Execution API
   - After OBO fix: token forwarded correctly but lacked `sql` scope → 403 "Provided OAuth token does not have required scopes: sql"
   - Root cause: `user_api_scopes` in `lakeloom_ai.app.yml` only declared `files.files`

2. **Transcript showing wrong data for a capture:**
   - Query returned ALL `final_transcript` events for the paired session across all time
   - A single paired session spans multiple captures; needed time-window scoping

3. **Phase 2 `client_generated_id` handler never wired (Isaac's PR #77 blocker):**
   - Migration 018 added the column + unique index
   - Zod schema accepted `client_generated_id`
   - But POST handler only destructured `{ label, client_ts, device_id }` — field dropped on floor
   - Result: server returned server-generated ID; iOS uploads against client ID → 404

## Root Causes

 Issue | Root Cause |
-------|-----------|
 401 → Statement API | `transcript-routes.ts` never passed `options.accessToken` to `executeStatement()` |
 403 → missing scope | `lakeloom_ai.app.yml` `user_api_scopes` lacked `sql` |
 Wrong transcript | No `event_time >= started_at` filter in bronze query |
 Phase 2 404s | Handler code never implemented despite migration + reply claiming it was |

## Changes Made

 File | Change |
------|--------|
 `server/routes/transcripts/transcript-routes.ts` | Added `getAccessToken(req)` helper; pass OBO token to both `executeStatement` calls; added `started_at`/`ended_at` time-window filter to transcript query |
 `resources/lakeloom_ai.app.yml` | Added `sql` and `dashboards.genie` to `user_api_scopes` |
 `server/routes/captures/capture-routes.ts` | Wired Phase 2: destructure `client_generated_id`, idempotency check (200 on re-submit), INSERT with client ID as row `id` (Option A) |
 `server/services/sql-service.ts` | No logic change (already supported OBO via `options.accessToken`) |

## Key Decisions

- **OBO over App SPN for transcript reads:** The user's own token (via `x-forwarded-access-token`) has full schema access. App SPN grant is a future fallback but not needed today.
- **`uc_securable` cannot grant TABLE SELECT:** Confirmed via docs — only supports VOLUME. Table grants must be SQL GRANTs outside the bundle.
- **User re-consent required:** Adding scopes to an existing app requires users to re-authorize (incognito window or clear session). Existing tokens don't auto-upgrade.
- **Time-window scoping:** Filter by `event_time >= started_at AND event_time <= ended_at` (or unbounded upper if capture still active).

## Verification

- OTel logs: zero errors after final deploy (10:55 UTC onward)
- Transcript panel loads correctly with session-specific content
- 115 total events for paired session → 20 segments correctly scoped to OSU capture window

## Isaac Communication

- Read his May 26 bug report from `origin/mg-ios-pr21-phase3-cutover` (not yet merged to main)
- Wrote reply: `architecture/hey_isaac/2026-05-27_client-generated-id-fix-live.md`
- His PR #77 should now pass device tests (create returns client-supplied ID; uploads succeed)

## Files Modified

```
server/routes/transcripts/transcript-routes.ts
server/routes/captures/capture-routes.ts
server/services/sql-service.ts
resources/lakeloom_ai.app.yml
architecture/hey_isaac/2026-05-27_client-generated-id-fix-live.md
```
