# Phase 5: Device & Admin Panel — Implementation Plan

**Date:** 2026-05-26
**Branch:** `mg-phase5-device-admin-panel`
**Status:** 🚧 In progress
**Estimated effort:** 4–5 hours (Tasks 1–4 core, Tasks 5–6 enhancements)

---

## Overview

Operational management and system health for the lakeLoom Databricks App. Two new pages:

1. **Devices** (`/devices`) — manage paired iOS devices (list, revoke, status)
2. **Admin** (`/admin`) — system health dashboard (secrets, Lakebase, volumes, ZeroBus, sweeper)

---

## What Already Exists

| Layer | Item | Status |
|-------|------|--------|
| Server | `GET /api/pairing/devices` (list for current user) | ✅ Done |
| Server | `DELETE /api/pairing/devices/:id` (soft-revoke) | ✅ Done |
| Server | `GET /healthz` (basic ok/timestamp) | ✅ Done |
| Server | SSE pairing events (`/api/pairing/events`) | ✅ Done |
| Client | PairingPage (QR generation) | ✅ Done |
| Client | ConfirmDialog component | ✅ Done |
| Client | useCurrentUser hook | ✅ Done |
| Data | `app.paired_sessions`: id, device_label, first_seen_at, last_seen_at, expires_at, paired_at, revoked_at, device_id, username | ✅ Done |

---

## Task 1 — `GET /api/admin/health` Endpoint

**File:** `server/routes/admin/admin-routes.ts`
**Register in:** `server/server.ts`
**Auth:** Browser-only (on-behalf-of-user, requires `x-forwarded-user`)

### Subsystem Checks

| Check | Method | Returns |
|-------|--------|---------|
| Secrets | `getSecrets()` + `getMissingKeys()` | present count, missing key names |
| Lakebase | `SELECT 1` query + migration count from `_migrations` table | latency_ms, migrations_applied |
| Volumes | `files.list()` on session_audio, screenshots, documents | per-volume ok/error |
| ZeroBus | Import pool status from `zeroBusService` | active_streams, pool_size, last_ingest |
| App | `process.env`, `process.uptime()` | app_name, node_version, uptime_s |
| Sweeper | Query `app.sweeper_runs` for latest row | last_run_at, orphan_count, bytes_reclaimed |

### Response Shape

```json
{
  "status": "healthy | degraded | unhealthy",
  "checks": {
    "secrets": { "status": "ok", "present": 6, "missing": [] },
    "lakebase": { "status": "ok", "migrations_applied": 18, "latency_ms": 12 },
    "volumes": {
      "session_audio": { "status": "ok" },
      "screenshots": { "status": "ok" },
      "documents": { "status": "ok" }
    },
    "zerobus": { "status": "ok", "active_streams": 2, "pool_size": 16, "last_ingest_at": "..." },
    "app": { "name": "lakeloom-ai-dev", "node_version": "22.x", "uptime_s": 3600 },
    "sweeper": { "status": "ok", "last_run_at": "...", "orphan_count": 0, "bytes_reclaimed": 0 }
  },
  "timestamp": "2026-05-26T01:00:00.000Z"
}
```

### Status Logic

- `healthy` = all checks pass
- `degraded` = non-critical check fails (sweeper, zerobus)
- `unhealthy` = critical check fails (lakebase, secrets, volumes)

---

## Task 2 — DevicesPage Component

**File:** `client/src/pages/devices/DevicesPage.tsx`
**Route:** `/devices`

### UI Elements

- **Header:** "Paired Devices" title + "Pair new device" button (→ `/pairing`)
- **Device cards** (grid layout, same pattern as ProjectsPage):
  - Device label (bold, DM Sans Medium)
  - `paired_at` as relative time ("Paired 3 days ago")
  - `last_seen_at` with status badge:
    - 🟢 "Active now" if last_seen < 5 min ago
    - 🟡 "Last seen 2h ago" otherwise
  - `expires_at` with warning:
    - 🟠 "Expiring soon" badge if < 24h remaining
    - Gray "Expires in X days" otherwise
  - Revoke button (Trash icon) → ConfirmDialog → `DELETE /api/pairing/devices/:id`
  - After revoke: remove card with exit animation
- **Empty state:**
  - Device icon (Smartphone from lucide-react)
  - "No devices paired yet"
  - "Pair your first device" CTA → `/pairing`
- **Loading state:** Skeleton cards (3 placeholders)

### Data Flow

```
mount → GET /api/pairing/devices → setDevices(response.devices)
revoke → DELETE /api/pairing/devices/:id → remove from local state
```

---

## Task 3 — AdminPage Component

**File:** `client/src/pages/admin/AdminPage.tsx`
**Route:** `/admin`

### UI Elements

- **Status banner:** Large dot (green/yellow/red) + "All systems healthy" / "Some systems degraded" / "Systems unhealthy"
- **Refresh button:** Manual refresh + auto-refresh toggle (30s interval)
- **Subsystem cards** (vertical stack):

| Card | Content |
|------|---------|
| Secrets | ✅/❌ per key, count present vs expected |
| Lakebase | Connection status, migration count, latency |
| Volumes | 3 sub-rows (session_audio, screenshots, documents) with individual ✅/❌ |
| ZeroBus | Pool size, active streams, last ingest timestamp |
| App | App name, Node version, uptime formatted (Xh Xm) |
| Sweeper | Last run time, orphan count, bytes reclaimed (formatted) |

- **Card states:**
  - ✅ Green check + "Healthy" for passing checks
  - ⚠️ Amber warning for degraded (sweeper stale, zerobus no recent ingest)
  - ❌ Red X for failures (Lakebase unreachable, secrets missing)

### Data Flow

```
mount → GET /api/admin/health → setHealth(response)
refresh → re-fetch → setHealth(response)
auto-refresh → setInterval(30s) when toggle enabled
```

---

## Task 4 — Navigation & Routing Updates

**File:** `client/src/App.tsx`

### Changes

1. Add lazy imports:
   ```tsx
   const DevicesPage = lazy(() => import('./pages/devices/DevicesPage').then(m => ({ default: m.DevicesPage })));
   const AdminPage = lazy(() => import('./pages/admin/AdminPage').then(m => ({ default: m.AdminPage })));
   ```

2. Add routes:
   ```tsx
   { path: '/devices', element: <DevicesPage /> },
   { path: '/admin', element: <AdminPage /> },
   ```

3. Update nav links:
   - "Projects" (existing)
   - "Devices" (new — between Projects and Pair)
   - "Pair Device" (renamed from "Pair iPhone")
   - "Admin" (new — rightmost, before user pill)

---

## Task 5 — Sweeper Runs Table (Option A)

**Migration:** `019_sweeper_runs.ts`

### Schema

```sql
CREATE TABLE IF NOT EXISTS app.sweeper_runs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at TIMESTAMPTZ,
  orphan_count INTEGER NOT NULL DEFAULT 0,
  bytes_reclaimed BIGINT NOT NULL DEFAULT 0,
  files_deleted INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'running',
  error_message TEXT
);
```

### Integration

- The existing `orphan_byte_sweeper` job writes a row at start (`status='running'`) and updates on completion (`status='completed'`, set counts)
- Admin health endpoint queries: `SELECT * FROM app.sweeper_runs ORDER BY started_at DESC LIMIT 1`
- "Stale" threshold: warn if `completed_at` is > 7 days ago (sweeper should run weekly)

---

## Task 6 — Revoked Device History (Enhancement)

### Server Change

Update `GET /api/pairing/devices` to accept query param:
```
GET /api/pairing/devices?include_revoked=true
```

When `include_revoked=true`: change WHERE clause from `revoked_at IS NULL` to include revoked devices.

### Client Change

- Toggle button: "Show revoked" on DevicesPage
- Revoked devices rendered with:
  - Muted/grayscale card styling (`opacity-50`)
  - "Revoked on {date}" red badge
  - No revoke button (already revoked)
  - No expiry warning

---

## File Inventory

| Path | Action | Task |
|------|--------|------|
| `server/routes/admin/admin-routes.ts` | CREATE | 1 |
| `server/server.ts` | EDIT (add import + register) | 1 |
| `server/migrations/019_sweeper_runs.ts` | CREATE | 5 |
| `server/migrations/migrate.ts` | EDIT (register 019) | 5 |
| `client/src/pages/devices/DevicesPage.tsx` | CREATE | 2 |
| `client/src/pages/admin/AdminPage.tsx` | CREATE | 3 |
| `client/src/App.tsx` | EDIT (routes + nav) | 4 |
| `server/routes/pairing/pairing-routes.ts` | EDIT (include_revoked param) | 6 |

---

## Dependencies

None — fully independent of Phases 6 and 7. Can ship without blocking anything.

---

## Testing Checklist

- [ ] `GET /api/admin/health` returns structured response with all checks
- [ ] DevicesPage lists paired devices with correct status badges
- [ ] Revoke flow: click trash → confirm → device removed → API returns 204
- [ ] Empty state shows when no devices paired
- [ ] AdminPage renders all subsystem cards with correct status colors
- [ ] Auto-refresh toggle works (30s interval)
- [ ] Nav links highlight correctly on each route
- [ ] Migration 019 applies cleanly on deploy
