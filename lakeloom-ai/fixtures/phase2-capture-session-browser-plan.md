# Phase 2: Capture Session Browser — Implementation Plan

**Date:** 2026-05-16
**Status:** Ready to implement
**Estimated effort:** 2 days
**Dependency:** Phase 1 (Project Management) — ✅ MET

---

## Objective

Allow the Databricks employee to browse, review, and manage capture sessions created from iOS — directly from the browser within a project's detail view. This is the first "review" layer before media playback (Phase 3).

---

## Current State

### What exists (server):
- `server/routes/captures/capture-routes.ts` — 4 endpoints fully implemented:
  - `POST /api/projects/:project_id/captures` — create (iOS only)
  - `PATCH /api/captures/:capture_session_id` — state transition
  - `GET /api/captures/:capture_session_id` — detail with `?include=uploads`
  - `GET /api/projects/:project_id/captures` — list (supports `?state=`, `?limit=`, `?before=`)
- All routes currently use **`iosAuth`** middleware only

### What exists (client):
- `App.tsx` — flat route structure, no `/projects/:id` route yet
- `ProjectsPage.tsx` — card grid with CRUD, no click-through to project detail
- `client/src/lib/utils.ts` — utility module (exists but minimal)
- No shared component library yet (no `components/` directory)

### What's missing:
- Browser-accessible capture endpoints (need `dualAuth()`)
- Project detail page (`/projects/:id`) with session list
- Session detail view (`/projects/:id/captures/:cid`)
- Shared UI components (StatusBadge, TimeAgo, EmptyState, DataTable)
- Route nesting in `App.tsx`

---

## Implementation Steps

### Step 1: Server — Switch capture list/detail routes to `dualAuth()`

**File:** `server/routes/captures/capture-routes.ts`

**Changes:**
- Import `dualAuth` from `../../middleware/browser-auth`
- Change auth middleware on **read endpoints** (`GET` list + `GET` detail) from `iosAuth` to `dualAuth({ lakebase })`
- Keep `POST` (create) on `iosAuth` — captures are created from iOS only
- Add response shaping: include `upload_count` and `total_size_bytes` as summary fields on the list endpoint (avoids N+1 queries from the browser)

**New list query (replaces current):**
```sql
SELECT
  cs.id, cs.project_id, cs.created_by_user_id, cs.device_label,
  cs.state, cs.label, cs.started_at, cs.ended_at,
  COALESCE(u.upload_count, 0)::int AS upload_count,
  COALESCE(u.total_size_bytes, 0)::bigint AS total_size_bytes
FROM app.capture_sessions cs
LEFT JOIN LATERAL (
  SELECT COUNT(*) AS upload_count, SUM(size_bytes) AS total_size_bytes
  FROM app.uploads
  WHERE capture_session_id = cs.id AND revoked_at IS NULL
) u ON true
WHERE cs.project_id = $1 AND cs.revoked_at IS NULL
```

**Estimated:** 30 min

---

### Step 2: Server — Add browser-accessible PATCH for state transitions

**File:** `server/routes/captures/capture-routes.ts`

**Changes:**
- Add a **new** route: `PATCH /api/v1/captures/:capture_session_id/state` using `dualAuth()`
- Accepts `{ state: 'completed' | 'cancelled' }` — same logic as existing PATCH
- Browser authz: only the project owner (or any authenticated browser user for now) can transition
- Keep the original `PATCH /api/captures/:capture_session_id` (iOS contract) unchanged

**Rationale:** Separate route path (`/api/v1/` prefix) avoids breaking iOS contract while providing browser access.

**Estimated:** 20 min

---

### Step 3: Client — Create shared components

**Directory:** `client/src/components/`

| Component | File | Purpose |
|-----------|------|---------|
| `StatusBadge` | `StatusBadge.tsx` | Pill badge: `active` (green pulse), `completed` (green solid), `cancelled` (gray) |
| `TimeAgo` | `TimeAgo.tsx` | Relative time ("3 hours ago", "2 days ago") — updates on interval |
| `EmptyState` | `EmptyState.tsx` | Icon + title + description + optional CTA button |
| `FileIcon` | `FileIcon.tsx` | MIME-aware icon (audio waveform, image, PDF, doc) |
| `ConfirmDialog` | `ConfirmDialog.tsx` | Destructive action confirmation modal |

**Design tokens:** All components use semantic CSS vars (`--surface-*`, `--text-*`, `--accent-*`, `--border-*`) per brand spec in `databricks-app-ui-plan.md`.

**Estimated:** 1.5 hours

---

### Step 4: Client — Add route structure for project detail + captures

**File:** `client/src/App.tsx`

**Changes:**
- Add nested routes:
  ```
  /projects/:id          → ProjectDetailPage (session list + project header)
  /projects/:id/captures/:cid → CaptureDetailPage (upload timeline)
  ```
- Update `ProjectsPage` card click → navigate to `/projects/:id`
- Lazy-load both new pages

**New route tree:**
```tsx
{ path: '/', element: <ProjectsPage /> },
{ path: '/projects/:id', element: <ProjectDetailPage /> },
{ path: '/projects/:id/captures/:cid', element: <CaptureDetailPage /> },
{ path: '/pairing', element: <PairingPage /> },
// ... existing routes
```

**Estimated:** 30 min

---

### Step 5: Client — ProjectDetailPage (session list)

**File:** `client/src/pages/projects/ProjectDetailPage.tsx`

**UI Structure:**
```
┌────────────────────────────────────────────────────────┐
│ ← Back to Projects                                     │
│                                                        │
│ [Project Name]                              [Edit] [...│
│ Description text                                       │
│                                                        │
│ ─── Capture Sessions ─────────────── [Filter: All ▾] ──│
│                                                        │
│ ┌──────────────────────────────────────────────────┐   │
│ │ 🟢 Active  "Sprint Planning Meeting"             │   │
│ │ iPhone 15 Pro · Started 2h ago · 3 files (14 MB) │   │
│ │                                    [Complete] [✕] │   │
│ └──────────────────────────────────────────────────┘   │
│                                                        │
│ ┌──────────────────────────────────────────────────┐   │
│ │ ✓ Completed  "Architecture Review"               │   │
│ │ iPhone 15 Pro · 45 min · 8 files (52 MB)         │   │
│ │                                                   │   │
│ └──────────────────────────────────────────────────┘   │
│                                                        │
│ ─── or if empty: ──────────────────────────────────── │
│       📱 No capture sessions yet                       │
│       Pair an iPhone to start capturing                │
│                              [Pair iPhone →]           │
└────────────────────────────────────────────────────────┘
```

**Features:**
- Fetches project detail (`GET /api/v1/projects/:id`) + captures list
- State filter dropdown (All / Active / Completed / Cancelled)
- Sort by `started_at DESC` (default)
- Each session card shows: state badge, label, device, duration/time-ago, file count + size
- Click card → navigate to `/projects/:id/captures/:cid`
- State transition buttons on active sessions (Complete / Cancel with confirmation)
- Label inline editing (PATCH to a new endpoint or reuse existing)
- Empty state with CTA to Pair iPhone page
- Cursor-based pagination ("Load more" pattern from ProjectsPage)

**API calls:**
- `GET /api/v1/projects/:id` (existing)
- `GET /api/projects/:project_id/captures?state=&limit=25&before=`
- `PATCH /api/v1/captures/:id/state` (new, Step 2)

**Estimated:** 3–4 hours

---

### Step 6: Client — CaptureDetailPage (session detail + upload timeline)

**File:** `client/src/pages/projects/CaptureDetailPage.tsx`

**UI Structure:**
```
┌────────────────────────────────────────────────────────┐
│ ← Back to [Project Name]                               │
│                                                        │
│ "Sprint Planning Meeting"              🟢 Active       │
│ ──────────────────────────────────────────────────────  │
│ Created by: matthew.giglia  |  Device: iPhone 15 Pro   │
│ Started: 2026-05-16 10:23 AM  |  Duration: 45 min     │
│                                                        │
│ ─── Uploads (8 files · 52 MB) ─────────────────────── │
│                                                        │
│ 10:23  🎵 audio_capture_01.wav        12.4 MB          │
│ 10:24  🖼️ screenshot_01.png            2.1 MB          │
│ 10:28  🖼️ screenshot_02.png            1.8 MB          │
│ 10:35  📷 whiteboard_photo.jpeg        4.2 MB          │
│ 10:41  🎵 audio_capture_02.wav        18.7 MB          │
│ 10:42  🖼️ screenshot_03.png            2.3 MB          │
│ 10:44  📄 requirements.pdf             8.1 MB          │
│ 10:45  🖼️ screenshot_04.png            2.4 MB          │
│                                                        │
│ ─── Actions ──────────────────────────────────────────  │
│ [Mark Completed]  [Cancel Session]                     │
└────────────────────────────────────────────────────────┘
```

**Features:**
- Fetches `GET /api/captures/:id?include=uploads`
- Metadata header (who, when, device, duration, state badge)
- Upload timeline: chronological list of uploads with:
  - Timestamp (relative to session start)
  - FileIcon by MIME type
  - Filename, size
  - Click → placeholder (Phase 3 will add media viewer)
- State transition buttons (if `state === 'active'`)
- Label editing (editable title)

**API calls:**
- `GET /api/captures/:capture_session_id?include=uploads`
- `PATCH /api/v1/captures/:id/state`

**Estimated:** 2–3 hours

---

### Step 7: Update ProjectsPage card click-through

**File:** `client/src/pages/projects/ProjectsPage.tsx`

**Changes:**
- Wrap each project card in a `<Link to={`/projects/${project.project_id}`}>` (or onClick + `useNavigate`)
- Add visual hover affordance (cursor pointer, subtle shadow lift)
- Show session count + last activity as summary stats on each card

**Estimated:** 30 min

---

## File Tree (new/modified)

```
client/src/
├── App.tsx                              ← MODIFIED (add routes)
├── components/                          ← NEW directory
│   ├── StatusBadge.tsx                  ← NEW
│   ├── TimeAgo.tsx                      ← NEW
│   ├── EmptyState.tsx                   ← NEW
│   ├── FileIcon.tsx                     ← NEW
│   └── ConfirmDialog.tsx                ← NEW
├── pages/
│   └── projects/
│       ├── ProjectsPage.tsx             ← MODIFIED (card click-through)
│       ├── ProjectDetailPage.tsx        ← NEW
│       └── CaptureDetailPage.tsx        ← NEW
server/
└── routes/
    └── captures/
        └── capture-routes.ts            ← MODIFIED (dualAuth, summary fields, browser PATCH)
```

---

## Execution Order

| # | Task | Blocks | Est. |
|---|------|--------|------|
| 1 | Server: dualAuth on GET routes + summary fields | Nothing (enables client work) | 30 min |
| 2 | Server: Browser PATCH route | Step 5–6 state buttons | 20 min |
| 3 | Client: Shared components | Steps 5–6 UI | 1.5 hr |
| 4 | Client: Route structure in App.tsx | Steps 5–6 pages | 30 min |
| 5 | Client: ProjectDetailPage | Step 7 | 3–4 hr |
| 6 | Client: CaptureDetailPage | — | 2–3 hr |
| 7 | Client: ProjectsPage click-through | — | 30 min |

**Total estimated: ~9–11 hours working time (fits in 2 days with testing).**

---

## Testing Plan

1. **Server:** Add tests 11–13 to `pairing-api-test.ipynb`:
   - Test 11: Browser GET captures list (no iOS headers, should 200)
   - Test 12: Browser GET capture detail with `?include=uploads`
   - Test 13: Browser PATCH state transition
2. **Client:** Manual verification in deployed app:
   - Navigate project → detail → capture → uploads
   - Filter by state
   - Complete/cancel an active session
   - Empty state rendering
3. **Smoke test:** Update `tests/smoke.spec.ts` with new routes

---

## Open Questions (resolve during implementation)

1. **Label editing endpoint:** Reuse `PATCH /api/captures/:id` (currently iOS-only, body has `state`)? Or add a separate `PATCH /api/v1/captures/:id/label`? → Suggest: add label to existing PATCH body as optional field, wrap with dualAuth.
2. **Upload count on project card:** Should ProjectsPage show total captures per project? If yes, need a count sub-query in the projects list endpoint. → Suggest: defer to Step 7, add `capture_count` to project response.
3. **Cursor vs offset pagination for captures:** Current endpoint uses `?before=<ISO>` (cursor-like). Browser can reuse this pattern — no change needed.

---

## Dependencies on Later Phases

- **Phase 3 (Media Viewer):** Upload timeline items will become clickable links to the media viewer. For now, show metadata only (no playback/preview).
- **Phase 4 (Browser Uploads):** "Upload from browser" button on CaptureDetailPage will be added later.
- **Phase 5 (Admin Panel):** Device info in capture header links to device panel (deferred).
