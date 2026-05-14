# Databricks App UI — Feature Plan & Implementation Order

**Date:** 2026-05-14
**Status:** Planning — approved by Matthew, ready for implementation
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

## Feature Areas (7 total)

### 1. Project Management

Full CRUD for lakeLoom projects from the browser.

**Server endpoints (iOS Module 06 contract):**
- `GET /api/v1/projects` — list (filter by archive, search by name)
- `GET /api/v1/projects/:id` — fetch single
- `POST /api/v1/projects` — create (idempotent via `client_generated_id`)
- `PATCH /api/v1/projects/:id` — edit name/description
- `PATCH /api/v1/projects/:id/archive` — soft delete
- `PATCH /api/v1/projects/:id/restore` — unarchive

**Browser UI:**
- Project list view with search, archive filter toggle
- Create project modal (name + description)
- Inline edit for name/description
- Archive / restore actions
- Per-project summary card (session count, file count, last activity, total size)
- Default project indicator

**Lakebase table:** `app.projects` (new migration 004)
- `id` UUID PK (UUIDv7)
- `name` TEXT NOT NULL
- `description` TEXT
- `workspace_id` TEXT NOT NULL
- `created_by_user_id` TEXT NOT NULL
- `created_by_username` TEXT NOT NULL
- `archived` BOOLEAN DEFAULT false
- `created_at` / `updated_at` TIMESTAMPTZ
- REPLICA IDENTITY FULL (Lakehouse Sync)

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

**Dependencies:** Project Management (sessions belong to projects)

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

**MIME allowlists (same as iOS):**
- Audio: NOT supported from browser (recording is iOS-only)
- Screenshots: `image/png`, `image/jpeg`
- Photos: `image/jpeg`
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

| Phase | Feature | Rationale | Est. Effort |
|-------|---------|-----------|-------------|
| **Phase 1** | Project Management | Foundation — everything references project_id. Unblocks iOS Module 06. | 2–3 days |
| **Phase 2** | Capture Session Browser | Second-most foundational. Users need to see what's been captured. | 2 days |
| **Phase 3** | Media Viewer & Audio Playback | Core value: "I recorded on my phone, now I review on my laptop." | 3–4 days |
| **Phase 4** | Browser-Side Uploads | Quick win — same handlers, just browser auth. | 1–2 days |
| **Phase 5** | Device & Admin Panel | Independent. Provides operational confidence. Can interleave earlier. | 1–2 days |
| **Phase 6** | Transcript Viewer | Depends on SDP pipeline (silver layer). Start with raw bronze queries. | 3–4 days |
| **Phase 7** | Genie Code Session Planning | Capstone. Requires gold-layer tables and Agent design. Largest unknown. | 5–7 days |

**Total estimated: ~17–24 working days for full feature set.**

---

## Phase 1 Detailed Breakdown (Project Management)

### Day 1: Server + Migration
1. Migration `004_projects.ts` — create `app.projects` table
2. Server routes: `server/routes/projects/project-routes.ts`
3. Validation (Zod schemas for create/update payloads)
4. Browser auth middleware variant (on-behalf-of-user, not iOS Layer 2)

### Day 2: Client UI
5. Project list page (`client/src/pages/projects/`)
6. Create project modal
7. Edit inline
8. Archive/restore

### Day 3: Polish + Test
9. Per-project summary stats (join to captures + uploads)
10. Update post-deploy validation notebook with project endpoint tests
11. Bundle validate + deploy

---

## Navigation Structure (Proposed)

```
/ (Home)
├── /projects                    → Project list
│   └── /projects/:id            → Project detail (sessions + documents + summary)
│       ├── /projects/:id/captures/:cid  → Session detail (timeline + media)
│       └── /projects/:id/generate       → AI generation status + artifacts
├── /devices                     → Paired devices management
├── /pair                        → QR pairing page (EXISTING)
└── /admin                       → System health + diagnostics
```

---

## Shared UI Components (Build During Phase 1–2)

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

---

## Relationship to Existing Code

| Existing | Status | Action |
|----------|--------|--------|
| `client/src/pages/pairing/` | DONE | Keep as-is |
| `client/src/pages/lakebase/` | Stub | Repurpose → Project Management |
| `client/src/pages/files/` | Stub | Repurpose → Media Viewer |
| `client/src/pages/analytics/` | Stub | Repurpose → Per-project dashboards |
| `server/routes/captures/` | DONE | Extend with `?include=uploads` response shaping |
| `server/routes/uploads/` | DONE | Add file streaming proxy endpoint |
| `server/routes/pairing/` | DONE | Keep as-is, surface in Device panel |
| `server/routes/lakebase/` | `todo-routes.ts` | Replace with project routes |
| `server/services/sse-service.ts` | DONE | Reuse for live transcript streaming |
