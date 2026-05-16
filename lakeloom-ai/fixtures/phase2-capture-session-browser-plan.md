# Phase 2: Capture Session Browser — Implementation Plan

**Date:** 2026-05-16
**Status:** ✅ COMPLETE (implemented 2026-05-16)
**Estimated effort:** 2 days
**Dependency:** Phase 1 (Project Management) — ✅ MET

---

## Objective

Allow the Databricks employee to browse, review, and manage capture sessions created from iOS — directly from the browser within a project's detail view. This is the first "review" layer before media playback (Phase 3).

---

## Implementation Summary

Implemented in 4 commits on branch `phase2-capture-session-browser`:

| Commit | Description |
|--------|-------------|
| `7910581` | Server: dualAuth on GET routes + browser PATCH + upload summary LATERAL join |
| `18c9b7b` | Shared components: StatusBadge, TimeAgo, EmptyState, FileIcon, ConfirmDialog |
| `2c92773` | Routes + ProjectDetailPage + CaptureDetailPage + ProjectsPage click-through |
| `593f39a` | Cleanup: remove legacy todo-routes.ts, fix SIGTERM graceful shutdown |

**Additional cleanup (commit `593f39a`):**
- Removed legacy `server/routes/lakebase/todo-routes.ts` (AppKit scaffold leftover causing permission errors)
- Removed `client/src/pages/lakebase/LakebasePage.tsx` (dead todo UI stub)
- Fixed SIGTERM graceful shutdown: HTTP server close → ZeroBus → Lakebase pool → exit within 12s

---

## What Was Built

### Server (Step 1+2): `capture-routes.ts`
- ✅ GET list + GET detail switched from `iosAuth` → `dualAuth({ lakebase })`
- ✅ New `PATCH /api/v1/captures/:capture_session_id/state` with `dualAuth()`
- ✅ List endpoint enriched with `upload_count` + `total_size_bytes` via LATERAL join
- ✅ POST (create) kept on `iosAuth` — iOS-only

### Client — Shared Components (Step 3): `client/src/components/`
- ✅ `StatusBadge.tsx` — state pills with pulse animation for active
- ✅ `TimeAgo.tsx` + `Duration` — relative time with auto-refresh
- ✅ `EmptyState.tsx` — centered placeholder with icon + CTA
- ✅ `FileIcon.tsx` + `FileIconContainer` — MIME-aware icons
- ✅ `ConfirmDialog.tsx` — destructive action modal with danger variant
- ✅ `index.ts` — barrel export

### Client — Routing (Step 4): `App.tsx`
- ✅ `/projects/:id` → `ProjectDetailPage`
- ✅ `/projects/:id/captures/:cid` → `CaptureDetailPage`
- ✅ Removed `/lakebase` route (legacy)

### Client — ProjectDetailPage (Step 5)
- ✅ Project header with metadata
- ✅ Capture session card list with state filter dropdown
- ✅ Cursor-based pagination ("Load more")
- ✅ State transition buttons (Complete / Cancel) with ConfirmDialog
- ✅ Empty state with CTA to Pair iPhone page

### Client — CaptureDetailPage (Step 6)
- ✅ Capture metadata header (who, when, device, duration, state badge)
- ✅ Upload timeline with time offsets, FileIconContainer, file sizes
- ✅ State transition buttons for active sessions

### Client — ProjectsPage Click-through (Step 7)
- ✅ Cards navigable to `/projects/:id`
- ✅ Hover border highlight + cursor pointer
- ✅ `stopPropagation` on action buttons

---

## File Tree (final)

```
client/src/
├── App.tsx                              ← MODIFIED (routes, removed /lakebase)
├── components/                          ← NEW directory
│   ├── StatusBadge.tsx                  ← NEW
│   ├── TimeAgo.tsx                      ← NEW
│   ├── EmptyState.tsx                   ← NEW
│   ├── FileIcon.tsx                     ← NEW
│   ├── ConfirmDialog.tsx                ← NEW
│   └── index.ts                         ← NEW (barrel)
├── pages/
│   ├── lakebase/                        ← DELETED
│   └── projects/
│       ├── ProjectsPage.tsx             ← MODIFIED (click-through)
│       ├── ProjectDetailPage.tsx        ← NEW
│       └── CaptureDetailPage.tsx        ← NEW
server/
├── server.ts                            ← MODIFIED (removed todo-routes, fixed SIGTERM)
├── routes/
│   ├── lakebase/                        ← DELETED
│   └── captures/
│       └── capture-routes.ts            ← MODIFIED (dualAuth, summary fields, browser PATCH)
```

---

## Testing Status

- ✅ App deployed to dev target (2026-05-16 05:29 UTC)
- ✅ Build successful (5,839 modules, 2.47s)
- ✅ All Lakebase startup queries: STATUS_CODE_OK
- ✅ Migrations applied (all 4 existing)
- ⬜ Server API tests (Tests 11–13) — to be added to `pairing-api-test.ipynb`
- ⬜ Manual browser walkthrough
- ⬜ Smoke test update (`tests/smoke.spec.ts`)

---

## Open Questions (resolved)

1. ~~**Label editing endpoint**~~ → Deferred to Phase 3 (not critical for browse experience)
2. ~~**Upload count on project card**~~ → Deferred; project list works without it for now
3. ~~**Cursor vs offset pagination**~~ → Reused existing `?before=<ISO>` pattern — no change needed

---

## Dependencies on Later Phases

- **Phase 3 (Media Viewer):** Upload timeline items will become clickable links to the media viewer. For now, show metadata only (no playback/preview).
- **Phase 4 (Browser Uploads):** "Upload from browser" button on CaptureDetailPage will be added later.
- **Phase 5 (Admin Panel):** Device info in capture header links to device panel (deferred).
