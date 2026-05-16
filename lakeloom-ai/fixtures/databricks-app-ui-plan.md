# Databricks App UI — Feature Plan & Implementation Order

**Date:** 2026-05-14 (created) | **Last updated:** 2026-05-15
**Status:** Phase 1 COMPLETE. Phase 2–7 planned and ready for implementation.
**Principle:** The Databricks App does everything the iOS app does EXCEPT record audio.

---

## Context

The lakeLoom Databricks App serves two roles:

1. **API server** for the iOS client (pairing, uploads, events, capture lifecycle) — DONE
2. **Browser UI** for the Databricks employee to manage projects, review captures, and trigger AI processing — THIS PLAN

The browser user and the iOS user are the **same person**. The handoff flow:

```
Pair (browser) → Capture (iPhone) → Review (browser) → Process (browser) → Execute (Genie Code)
```

---

## Milestone: End-to-End QR Pairing Validated (2026-05-15)

Physical iPhone successfully paired against the deployed Databricks App. Full auth chain proven:
QR scan → M2M token → `POST /api/pairing/confirm` → ECDSA device-key binding → project create → home screen.

This validates the entire server-side auth stack (Layer 0+1), the `x-forwarded-host` fix (PR #20), the `sha256(Buffer)` token-hash fix (PR #21), and the canonical-form spec. iOS Module 01 is officially closed and merged (PR #18).

**Known non-blocking issue:** First `GET /api/v1/projects` after pairing returns a warning on iOS (`project list failed during onboarding reason=unknown`). Subsequent `POST /api/v1/projects` works. Isaac investigating iOS-side — may surface an App-side need for `dualAuth` query-param handling.

---

## Feature Areas (7 total)

### 1. Project Management — ✅ COMPLETE (2026-05-14)

Full CRUD for lakeLoom projects from the browser.

**Server endpoints (iOS Module 06 contract):**
- `GET /api/v1/projects` — list (cursor-based pagination, filter by archive, search by name)
- `GET /api/v1/projects/:id` — fetch single
- `POST /api/v1/projects` — create (idempotent via `client_generated_id`)
- `PATCH /api/v1/projects/:id` — edit name/description
- `PATCH /api/v1/projects/:id/archive` — soft delete
- `PATCH /api/v1/projects/:id/restore` — unarchive

**Browser UI:** ✅ Shipped
- Project list view with search (debounced 300ms), archive filter toggle
- Create project modal (name + description)
- Inline edit for name/description
- Archive / restore actions
- Per-project summary card (session count, file count, last activity, total size)
- Card grid layout with Databricks brand tokens (DM Sans, semantic colors, motion)
- "Load more" button for cursor-based pagination

**Lakebase table:** `app.projects` (migration 004) — DEPLOYED
- `id` UUID PK (UUIDv7, server-generated)
- `client_generated_id` TEXT (idempotency key, UNIQUE per workspace)
- `name` TEXT NOT NULL
- `description` TEXT
- `workspace_id` TEXT NOT NULL
- `created_by_user_id` TEXT NOT NULL
- `created_by_username` TEXT NOT NULL
- `archived` BOOLEAN DEFAULT false
- `created_at` / `updated_at` TIMESTAMPTZ
- GIN trigram index on `name` (pg_trgm extension confirmed working on Lakebase)
- REPLICA IDENTITY FULL (Lakehouse Sync)

**Auth:** `dualAuth()` middleware — accepts iOS Layer 2 OR browser on-behalf-of-user per request.

**Dependencies:** None (foundational — everything else references `project_id`)

---

### 2. Capture Session Browser

Review and manage capture sessions created from iOS.

**Server endpoints (already exist):**
- `GET /api/projects/:project_id/captures` — list sessions
- `GET /api/captures/:capture_session_id` — detail (supports `?include=uploads`)
- `PATCH /api/captures/:capture_session_id` — state transitions

**Browser UI:**
- Session list per project (sortable by date, filterable by state)
- Session detail view:
  - Metadata header (who, when, which device, duration, state)
  - Upload timeline (chronological, thumbnails for images, waveform preview for audio)
  - State transition buttons (mark completed/cancelled from browser)
- Session label editing (add/update descriptive names post-capture)
- Empty state when no captures exist yet (CTA: "Pair an iPhone to start capturing")

**Dependencies:** Project Management (sessions belong to projects) — ✅ MET

---

### 3. Media Viewer & Audio Playback

The primary review experience — consuming captured material from the browser.

**New server endpoints:**
- `GET /api/files/:upload_id/stream` — proxy UC Volume file to browser (range requests for audio seek)
- `GET /api/files/:upload_id/thumbnail` — server-generated thumbnail for images (optional, can defer)
- `GET /api/files/:upload_id/metadata` — full metadata from `app.uploads`

**Browser UI — Audio Player:**
- HTML5 `<audio>` with custom controls
- Waveform visualization (peaks pre-computed or client-side via Web Audio API)
- Playback speed (0.5x / 1x / 1.5x / 2x)
- Seek bar with time display
- Download button
- Transcript sync (when available — click segment, audio jumps to position)

**Browser UI — Image Viewer:**
- Gallery grid view (thumbnails)
- Lightbox with zoom/pan
- Side-by-side comparison mode (for screenshots taken at different times)
- Metadata panel (capture time, device, dimensions, SHA-256)
- Kind indicator (screenshot vs photo)

**Browser UI — Document Viewer:**
- PDF inline rendering (pdf.js or `<iframe>`)
- DOCX: download link (inline rendering deferred to v2)
- File info panel (size, upload time, SHA-256)

**File proxy pattern:**
- App reads from UC Volume using App SPN credentials
- Streams to browser with correct `Content-Type` and `Content-Disposition`
- Supports HTTP Range requests for audio seeking
- Browser never calls UC directly

**Dependencies:** Capture Session Browser (files belong to sessions/projects)

---

### 4. Browser-Side Uploads

Upload documents, screenshots, and photos directly from the browser (no iOS needed).

**Server endpoints (reuse existing upload handlers):**
- `POST /api/captures/:capture_session_id/screenshots` — from browser
- `POST /api/captures/:capture_session_id/photos` — from browser
- `POST /api/projects/:project_id/documents` — from browser

**Browser UI:**
- Drag-and-drop zone on session detail view (screenshots/photos)
- Drag-and-drop zone on project view (documents)
- File picker button as alternative
- Upload progress indicator with cancel
- MIME validation feedback (instant client-side check before upload)
- Size limit display
- Success confirmation with link to the new file in the viewer

**Auth difference from iOS:**
- Browser requests use Databricks App's built-in on-behalf-of-user auth (no Layer 2 ECDSA)
- The upload handler detects browser vs iOS context and applies appropriate auth middleware
- Both paths write to the same `app.uploads` table with full traceability

**MIME allowlists (same as iOS — finalized 2026-05-14):**
- Audio: NOT supported from browser (recording is iOS-only)
- Screenshots: `image/png`, `image/jpeg`
- Photos: `image/jpeg` only (no HEIC — iOS captures JPEG natively via AVCapturePhotoOutput)
- Documents: `application/pdf`, `application/vnd.openxmlformats-officedocument.wordprocessingml.document`

**Dependencies:** Capture Session Browser + Media Viewer (upload then view)

---

### 5. Transcript Viewer

Display transcripts from ZeroBus events — both real-time and historical.

**New server endpoints:**
- `GET /api/captures/:capture_session_id/transcript` — historical transcript (from bronze/silver tables)
- `GET /api/captures/:capture_session_id/transcript/stream` — SSE for live transcripts during active captures
- `GET /api/projects/:project_id/search?q=<term>` — full-text search across transcripts

**Browser UI — Live View (active captures):**
- Real-time transcript appearing as text stream (SSE → DOM append)
- Speaker labels (when diarization is available)
- Auto-scroll with "pinned to bottom" toggle
- Recording indicator (pulsing dot, elapsed time)

**Browser UI — Historical View:**
- Full transcript with timestamps
- Clickable timestamps that seek the audio player (when paired with audio)
- Search/highlight within transcript
- Copy-to-clipboard for sections

**Browser UI — Cross-Project Search:**
- Search bar across all transcripts for a project
- Results with context snippets and links to source sessions
- Filter by date range, session state

**Data source:**
- Bronze: `transcript_events_raw` (via SQL warehouse query)
- Silver: `transcript_events` / `session_transcripts` (once SDP pipeline exists)
- Live: ZeroBus SSE subscription (App already has `sse-service.ts`)

**Dependencies:** Capture Session Browser + Audio Player (for time-linked playback)

---

### 6. Device & Admin Panel

Operational management and system health.

**Server endpoints (pairing routes already exist):**
- `GET /api/pairing/devices` — list paired devices
- `DELETE /api/pairing/devices/:id` — revoke
- `GET /api/admin/health` — new: system health check

**Browser UI — Paired Devices:**
- Device list (label, first seen, last seen, expires_at)
- "Active now" indicator (last_seen < 5 min ago)
- Revoke button with confirmation dialog
- "Pair new device" button (navigates to PairingPage)
- Expiring soon warning (< 24h remaining)

**Browser UI — System Health:**
- Secret scope status (all required keys present?)
- SPN health (both SPNs have valid credentials?)
- Lakebase connectivity (migrations applied, tables exist?)
- UC Volume accessibility (can App SPN write?)
- Orphan file report (latest sweep results: count, total bytes)
- Last deploy timestamp, app version

**Dependencies:** None (can be built independently)

---

### 7. Genie Code Session Planning (AI Layer)

The value proposition — transform captures into actionable Databricks build artifacts.

**New server endpoints:**
- `POST /api/projects/:project_id/generate` — trigger Agent processing
- `GET /api/projects/:project_id/artifacts` — list generated artifacts
- `GET /api/projects/:project_id/artifacts/:id` — fetch single artifact
- `POST /api/projects/:project_id/artifacts/:id/regenerate` — re-run with updated input

**Browser UI — Generation Trigger:**
- "Generate" button on project view (requires at least 1 completed capture session)
- Processing status (queued → running → complete/failed)
- Progress indicator (phases: transcription → requirements → architecture → session plans)

**Browser UI — Artifacts Viewer:**
- **Requirements document** — rendered Markdown with section navigation
- **Architecture diagrams** — Mermaid rendering (live preview)
- **Session plans** — structured view of phased Genie Code steps (task list with dependencies)
- Version history (re-generations create new versions, old ones remain accessible)
- Edit/annotate capability (user can refine generated output before export)

**Browser UI — Export / Handoff:**
- "Start Genie Code Session" button — deep link into Genie Code with plan pre-loaded
- Export as Markdown / JSON
- Copy individual sections to clipboard

**Data flow:**
- Captures (bronze) → Silver processing (SDP) → Gold knowledge base → Agent → Artifacts
- Artifacts stored in Lakebase (`app.artifacts` table) with version tracking
- Agent uses gold-layer tables as context window for generation

**Dependencies:** ALL previous features (this is the capstone)

---

## Recommended Implementation Order

The ordering optimizes for: (a) unblocking iOS Module 06, (b) delivering reviewable value early, (c) minimizing rework by building on stable foundations.

| Phase | Feature | Status | Est. Effort |
|-------|---------|--------|-------------|
| **Phase 1** | Project Management | ✅ COMPLETE (2026-05-14) | — |
| **Phase 2** | Capture Session Browser | Ready | 2 days |
| **Phase 3** | Media Viewer & Audio Playback | Ready (depends on Phase 2) | 3–4 days |
| **Phase 4** | Browser-Side Uploads | Ready (depends on Phase 2+3) | 1–2 days |
| **Phase 5** | Device & Admin Panel | Ready (independent) | 1–2 days |
| **Phase 6** | Transcript Viewer | Blocked on SDP pipeline for silver; bronze queries v1 possible | 3–4 days |
| **Phase 7** | Genie Code Session Planning | Blocked on gold-layer tables + Agent design | 5–7 days |

**Remaining estimated: ~15–21 working days for Phases 2–7.**

---

## Navigation Structure (Proposed)

```
/ (Home)
├── /projects                    → Project list (IMPLEMENTED)
│   └── /projects/:id            → Project detail (sessions + documents + summary)
│       ├── /projects/:id/captures/:cid  → Session detail (timeline + media)
│       └── /projects/:id/generate       → AI generation status + artifacts
├── /devices                     → Paired devices management
├── /pair                        → QR pairing page (IMPLEMENTED)
└── /admin                       → System health + diagnostics
```

---

## Shared UI Components (Build During Phase 2–3)

Reusable components serving multiple features:

- **DataTable** — sortable, filterable list (projects, sessions, files, devices)
- **EmptyState** — consistent empty state with illustration + CTA
- **FileIcon** — MIME-aware file type icon
- **TimeAgo** — relative timestamp display
- **StatusBadge** — state indicators (active/completed/cancelled, synced/uploading)
- **ConfirmDialog** — destructive action confirmation
- **DragDropZone** — file upload area with validation feedback
- **AudioPlayer** — reusable player component (Phase 3 but design in Phase 2)

---

## Open Questions

1. ~~**Project creation from browser vs iOS-only?**~~ → RESOLVED: Both. Browser uses on-behalf-of-user auth.
2. **Should the browser see ALL users' projects or only the current user's?** → Suggest: current user by default, admin toggle for "all projects" view.
3. **Transcript storage before SDP pipeline exists:** Query bronze directly for v1, switch to silver when pipeline ships.
4. **Agent implementation:** Notebook-based (triggered via Jobs API) or in-process (App backend calls foundation model)? → Suggest: Jobs API — decouples compute, leverages existing serverless, produces auditable runs.
5. **Non-blocking onboarding issue:** iOS `GET /api/v1/projects` fails on first call after pairing. Isaac investigating — may require `dualAuth` query-param canonicalization fix on App side.

---

## Cross-Cutting Concerns (Phase 2+ Enhancements)

### User Identity Display

Show the current user's identity in the top-right of the app shell so it's always clear who is logged in. The browser auth sidecar provides `X-Forwarded-Email` on every request.

**Implementation approach:**
- Add `GET /api/me` endpoint — returns `{ email, display_name, scim_id }` from identity headers
- App shell fetches on mount, caches in React context
- Display as avatar/email pill in the top-right nav bar (similar to Databricks workspace header)
- Also useful for showing "Created by you" vs "Created by <name>" in project cards

**Priority:** High — simple to implement, immediately clarifies identity handoff between iOS and browser.

---

### Project Permissions Model

Owner of a project should be able to grant scoped access to other workspace users. Three permission levels:

| Level | Capabilities |
|-------|-------------|
| **View** | Read-only access to project, captures, uploads, transcripts |
| **Edit** | Create/modify captures, upload files, transition session states |
| **Manage** | Grant/revoke permissions, archive/restore, change project settings |

**Implementation approach:**
- New Lakebase table: `app.project_permissions` (project_id, user_id, role, granted_by, granted_at)
- New middleware: `requireProjectAccess(minRole)` — checks permission table before handler
- Project creator automatically gets `manage` role
- `GET /api/v1/projects` returns only projects where user has at least `view` permission (or is creator)
- UI: "Share" button on project detail → modal with user search + role selector + current collaborators list

**Dependencies:** User identity display (need `/api/me` and user lookup)  
**Priority:** Medium — enables team collaboration, but single-user flow works without it.

---

## Relationship to Existing Code

| Existing | Status | Action |
|----------|--------|--------|
| `client/src/pages/pairing/` | ✅ DONE | Keep as-is |
| `client/src/pages/projects/` | ✅ DONE (Phase 1) | Extend with session list in Phase 2 |
| `client/src/pages/lakebase/` | Stub | Repurpose → Admin/diagnostics |
| `client/src/pages/files/` | Stub | Repurpose → Media Viewer |
| `client/src/pages/analytics/` | Stub | Repurpose → Per-project dashboards |
| `server/routes/captures/` | ✅ DONE | Extend with `?include=uploads` response shaping |
| `server/routes/uploads/` | ✅ DONE (audio, screenshots, photos, documents) | Add file streaming proxy endpoint |
| `server/routes/projects/` | ✅ DONE | Keep as-is |
| `server/routes/pairing/` | ✅ DONE | Surface in Device panel |
| `server/routes/lakebase/` | `todo-routes.ts` | Remove (superseded by project routes) |
| `server/services/sse-service.ts` | ✅ DONE | Reuse for live transcript streaming |
| `server/middleware/browser-auth.ts` | ✅ DONE (`dualAuth()`) | Already handles iOS vs browser detection |

---

## Databricks Brand Design System

All UI components MUST follow Databricks brand guidelines. This section is the binding specification for every visual element built in this app.

### Design Principles (Three Pillars)

Every design decision must satisfy all three:

1. **Distilled** — Clean, minimalistic, focused. Remove anything that doesn't serve meaning. Favor whitespace. If it can be removed without losing clarity, remove it.
2. **Bold** — Striking and confident. Use color palette decisively, size headings generously, create strong visual focal points.
3. **Fresh** — Modern and evolving. Use contemporary patterns, balance consistency with relevance.

**Self-check before shipping any component:** Can I remove anything? Does it make a confident impression? Does it feel current?

---

### Typography

**Fonts:**
- **DM Sans** — all UI text (headings, body, labels, navigation)
- **DM Mono** — code blocks, API paths, technical identifiers only

**Font files:** `/Shared/brandfolder/DM Sans/` and `/Shared/brandfolder/DM Mono/`

**CSS font stacks:**
```css
font-family: "DM Sans", "Inter", system-ui, -apple-system, sans-serif;
font-family: "DM Mono", "JetBrains Mono", "Fira Code", "SF Mono", monospace;
```

**Type scale (px):** 10 / 12 / 14 / 16 / 20 / 24 / 32 / 40 / 48 / 56

**Weights:** Regular (400) body, Medium (500) labels/nav/subheadings, Bold (700) headings/CTAs

**Line heights:** 150% (1.5) body copy, 120% (1.2) headings

**Hierarchy pattern:** Eyebrow (Medium, small, muted) → Heading (Bold, large, Navy 800) → Body (Regular, 16px, Gray Text) → CTA (Medium, small, Lava 600 + arrow)

---

### Color Palette

**Primary brand colors:**

| Name | Hex | Role |
|------|-----|------|
| Lava 600 | `#FF3621` | Primary accent — CTAs, highlights |
| Navy 800 | `#1B3139` | Dark surfaces, primary text (light mode) |
| Oat Medium | `#EEEDE9` | Light surface backgrounds |
| Oat Light | `#F9F7F4` | Lightest surfaces |
| White | `#FFFFFF` | Clean white backgrounds |

**Functional grays:**

| Name | Hex | Role |
|------|-----|------|
| Gray Nav | `#303F47` | Sidebar/nav backgrounds |
| Gray Text | `#5A6F77` | Body text, secondary labels |
| Gray Lines | `#DCE0E2` | Dividers, borders, separators |

**Semantic roles:**

| Role | Color | Hex |
|------|-------|-----|
| Primary CTA | Lava 600 | `#FF3621` |
| Success | Green 600 | `#00A972` |
| Warning | Yellow 600 | `#FFAB00` |
| Error | Lava 700 | `#BD2B26` |
| Info / links | Blue 600 | `#2272B4` |
| Muted / disabled | Navy 400 | `#90A5B1` |

**Rules:**
- Navy, Oat, White for large backgrounds — Lava is accent only, never background
- One accent family per view — don't combine multiple saturated hues at equal weight
- Tints/shades of analogous colors add depth without competing

---

### Dark / Light Mode

The app MUST support both modes via semantic CSS custom properties. Use `prefers-color-scheme` with a manual `.dark` class toggle for user override.

**Semantic tokens (swap between modes):**

| Token | Light | Dark |
|-------|-------|------|
| `--surface-primary` | White `#FFFFFF` | Navy 800 `#1B3139` |
| `--surface-secondary` | Oat Light `#F9F7F4` | Navy 900 `#0B2026` |
| `--surface-tertiary` | Oat Medium `#EEEDE9` | Navy 700 `#143D4A` |
| `--surface-raised` | White `#FFFFFF` | Navy 700 `#143D4A` |
| `--text-primary` | Navy 800 `#1B3139` | White `#FFFFFF` |
| `--text-secondary` | Gray Text `#5A6F77` | Navy 400 `#90A5B1` |
| `--border-default` | Gray Lines `#DCE0E2` | Navy 600 `#1B5162` |
| `--border-focus` | Blue 600 `#2272B4` | Blue 400 `#8ACAFF` |
| `--accent-primary` | Lava 600 `#FF3621` | Lava 500 `#FF5F46` |
| `--accent-error` | Lava 700 `#BD2B26` | Lava 500 `#FF5F46` |
| `--accent-success` | Green 700 `#00875C` | Green 600 `#00A972` |
| `--accent-warning` | Yellow 700 `#BA7B23` | Yellow 600 `#FFAB00` |
| `--accent-info` | Blue 600 `#2272B4` | Blue 400 `#8ACAFF` |

**Implementation:** Include ThemeProvider (React context + localStorage persistence) and use semantic tokens in ALL Tailwind classes — never raw hex values.

---

### Motion & Animation

**Duration scale:**

| Token | Duration | Use |
|-------|----------|-----|
| `--motion-fast` | 100ms | Button press, toggle, tooltip |
| `--motion-normal` | 200ms | Dropdown, accordion, tab switch |
| `--motion-moderate` | 300ms | Modal enter, sidebar collapse |
| `--motion-slow` | 400ms | Page transitions, skeleton reveal |

**Easing curves:**
- `--ease-out: cubic-bezier(0.16, 1, 0.3, 1)` — entrances (default)
- `--ease-in: cubic-bezier(0.7, 0, 0.84, 0)` — exits
- `--ease-in-out: cubic-bezier(0.45, 0, 0.55, 1)` — position changes

**Rules:**
- Exits faster than entrances (asymmetry rule)
- Max 2 properties animated simultaneously
- Never animate layout properties (`width`/`height`) — use `transform` + `opacity`
- Respect `prefers-reduced-motion: reduce` (set all durations to 0ms)
- Stagger lists: 50ms between items, max 5 staggered, same duration and easing

---

### Accessibility Requirements (Non-Negotiable)

**Contrast ratios (WCAG 2.1 AA minimum):**
- Body text (< 18px): ≥ 4.5:1
- Large text (≥ 18px or ≥ 14px bold): ≥ 3.0:1
- UI components and icons: ≥ 3.0:1

**Key constraint:** Lava 600 on white = 3.6:1 — AA-large only. Use for buttons and headings (≥ 14px bold), NOT body text. For body links use Blue 600 (5.1:1 on white).

**Focus indicators:** 2px solid ring, 2px offset, Blue 600 (light) / Blue 400 (dark). Every interactive element must have visible `:focus-visible` styling.

**Additional requirements:**
- All interactive elements: minimum 44px tap target
- Form inputs: visible labels (not placeholder-only)
- Error states: color + icon + text (never color alone)
- Images: meaningful `alt` text
- Keyboard navigation: full tab order, Escape to close modals
- Screen reader: ARIA labels on icon-only buttons

---

### Component Specifications

All shared components follow the recipes from the brand component system. Key specs:

**Button:** 4 variants (primary/secondary/ghost/danger), 3 sizes (sm/md/lg), `rounded-lg`, DM Sans Medium, `--motion-fast` transitions.

**Card:** `--surface-raised` bg, 1px `--border-default`, `rounded-xl` (12px), `px-6 py-4`, optional `shadow-sm`.

**Badge/StatusBadge:** `rounded-full`, DM Sans Medium 12px, 5 semantic variants (default/success/warning/error/info) with subtle background tints.

**Input:** `--surface-raised` bg, 1px `--border-default`, `rounded-lg`, DM Sans Regular 14px, 2px focus ring `--border-focus`.

**Modal:** Centered, `--surface-raised`, `rounded-xl`, `shadow-xl`, backdrop `--surface-overlay`, scale-up + fade entrance (300ms), Escape/backdrop-click to close, focus trapped inside.

**DataTable:** Header `--surface-secondary` with uppercase 12px labels, row hover `--surface-tertiary` (100ms), 1px bottom `--border-subtle`, `px-4 py-3` cells.

**EmptyState:** 64px icon container with `--surface-tertiary` bg, DM Sans Semibold 18px title, 14px secondary description, max-width 28rem, `py-16`.

**Toast:** Fixed bottom-right, `--surface-raised`, 3px left accent border per variant, slide-up entrance (200ms), auto-dismiss 5s.

---

### Tailwind CSS v4 Theme Configuration

The app uses Tailwind v4 with `@theme` blocks. All Databricks brand tokens MUST be registered:

```css
@theme {
  /* Colors — full palette scales */
  --color-dbx-lava: #FF3621;
  --color-dbx-navy: #1B3139;
  --color-dbx-oat: #EEEDE9;
  --color-dbx-oat-light: #F9F7F4;

  /* Semantic surfaces, text, borders, accents via CSS custom properties */
  --color-surface-primary: var(--surface-primary);
  --color-surface-secondary: var(--surface-secondary);
  --color-surface-tertiary: var(--surface-tertiary);
  --color-surface-raised: var(--surface-raised);
  --color-text-primary: var(--text-primary);
  --color-text-secondary: var(--text-secondary);
  --color-border-default: var(--border-default);
  --color-accent-primary: var(--accent-primary);

  /* Motion */
  --duration-fast: 100ms;
  --duration-normal: 200ms;
  --duration-moderate: 300ms;
  --duration-slow: 400ms;
  --ease-out: cubic-bezier(0.16, 1, 0.3, 1);
  --ease-in: cubic-bezier(0.7, 0, 0.84, 0);
}
```

---

### Spacing & Layout Constants

| Token | Value | Use |
|-------|-------|-----|
| Page padding | `px-6 py-6` (24px) | Main content area |
| Section gap | `gap-6` (24px) | Between major sections |
| Card gap | `gap-4` (16px) | Between cards in a grid |
| Component inner gap | `gap-3` (12px) | Within a card |
| Form field gap | `gap-4` (16px) | Between form fields |
| Button group gap | `gap-3` (12px) | Between buttons |
| Grid columns | `grid-cols-1 md:grid-cols-2 lg:grid-cols-4` | Stats grid |
| Max content width | `max-w-7xl mx-auto` (1280px) | Page container |
