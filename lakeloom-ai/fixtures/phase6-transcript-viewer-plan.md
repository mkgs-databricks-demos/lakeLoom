# Phase 6 — Transcript Viewer: Implementation Plan

**Date:** 2026-05-27
**Branch:** TBD (`mg-phase6-transcript-viewer`)
**Status:** Planning
**Estimate:** 3–4 days
**Depends on:** Phase 2 (Capture Session Browser) ✅, Phase 3 (Audio Player) ✅, Bronze ingest ✅

---

## Overview

Display transcripts from ZeroBus events — both real-time (during active capture) and historical (post-session review). The transcript viewer lives inside the existing CaptureDetailPage and syncs with the audio player for time-linked playback.

---

## Data Foundation

### Bronze Table (LIVE)

`hls_fde_dev.dev_matthew_giglia_lakeloom.transcript_events_raw`

| Column | Type | Notes |
|--------|------|-------|
| `record_id` | string | ZeroBus server-generated GUID |
| `ingested_at` | timestamp | Server-side ingestion time |
| `event_id` | string | App-generated idempotency key |
| `session_id` | string | Maps to `app.paired_sessions.id` |
| `project_id` | string | Maps to `app.projects.id` |
| `user_id` | string | Authenticated user |
| `device_id` | string | Physical device UUID |
| `event_type` | string | `final_transcript` (only type currently flowing) |
| `event_time` | timestamp | Client-side STT timestamp |
| `transcript_text` | string | The transcript segment text |
| `transcript_language` | string | `en-US` |
| `source_platform` | string | `ios` |
| `headers` | variant | Request metadata |
| `body` | variant | Full event payload (see below) |

**Body VARIANT structure:**
```json
{
  "text": "string",
  "confidence": 0.33,
  "segment_index": 24,
  "duration_ms": 4230,
  "model": "sf_speech_streaming_phrased",
  "source": "on_device_live",
  "language": "en-US",
  "project_id": "uuid",
  "device_id": "uuid",
  "event_type": "final_transcript",
  "event_time": "ISO timestamp"
}
```

**Current state:** 153 records, 5 sessions, latest 2026-05-27. All `final_transcript` type. No `partial_transcript`, `audio_uploaded`, or `client_status` events yet (those will flow when iOS live-transcription pipeline ships §§2–16 of Module 02).

### Lakebase Tables (for session context)

- `app.capture_sessions` — session metadata (state, label, project, device, timestamps)
- `app.uploads` — audio files linked to captures (for audio sync)

### Silver Tables (PLANNED — not yet built)

- `transcript_events` — deduped, typed columns from VARIANT
- `session_transcripts` — concatenated full transcript per session
- `session_chunks` — ordered within session, audio reference enriched

**Decision:** v1 queries bronze directly. Silver SDP is a follow-up enhancement.

---

## New Server Endpoints

### 1. `GET /api/captures/:capture_session_id/transcript`

Historical transcript for a completed (or active) capture session.

**Query:**
```sql
SELECT
  event_id,
  event_time,
  transcript_text,
  transcript_language,
  body:confidence::double AS confidence,
  body:segment_index::int AS segment_index,
  body:duration_ms::int AS duration_ms,
  body:model::string AS model,
  body:source::string AS source
FROM hls_fde_dev.dev_matthew_giglia_lakeloom.transcript_events_raw
WHERE session_id = $1
  AND event_type = 'final_transcript'
ORDER BY event_time ASC, body:segment_index::int ASC
```

**Implementation notes:**
- Query via SQL warehouse (not Lakebase — bronze is in UC, not Lakebase)
- Need to use Databricks SDK `StatementExecution` API or a warehouse connection
- Cache consideration: transcripts for completed sessions are immutable
- Auth: browser on-behalf-of-user (same as other capture routes)

**Response shape:**
```json
{
  "session_id": "uuid",
  "segments": [
    {
      "event_id": "string",
      "event_time": "ISO timestamp",
      "text": "string",
      "language": "en-US",
      "confidence": 0.43,
      "segment_index": 0,
      "duration_ms": 4230,
      "model": "sf_speech_streaming_phrased"
    }
  ],
  "total_segments": 24,
  "duration_ms": 120000,
  "language": "en-US"
}
```

### 2. `GET /api/captures/:capture_session_id/transcript/stream`

SSE endpoint for live transcripts during active capture.

**Mechanism options (ranked):**

| Option | Pros | Cons |
|--------|------|------|
| A. ZeroBus consumer subscription | Real-time, no polling | Requires dedicated consumer stream per browser viewer |
| B. Poll bronze on interval (5s) | Simple, uses existing infra | 5s latency, warehouse cost per poll |
| C. App-side in-memory relay | Zero latency (events pass through App on ingest) | Only works if App is the ingest proxy (it is!) |

**Recommended: Option C** — The App's ZeroBus ingest route (`POST /api/v1/ingest/snippets`) already receives every event from iOS before forwarding to ZeroBus. Add an in-memory pub/sub that broadcasts to connected SSE clients for the same `session_id`. Zero additional infrastructure, zero latency.

**Implementation:**
```typescript
// In the ingest route handler (after ZeroBus forward):
if (event.event_type === 'final_transcript') {
  pushTranscriptEvent(event.session_id, {
    event_time: event.event_time,
    text: event.text,
    confidence: event.confidence,
    segment_index: event.segment_index,
  });
}

// New SSE endpoint:
app.get('/api/captures/:id/transcript/stream', (req, res) => {
  // Validate session ownership
  // Set SSE headers
  // Subscribe to in-memory transcript channel for this session_id
  // Push events as they arrive
  // Keepalive every 30s
});
```

### 3. `GET /api/projects/:project_id/search?q=<term>`

Full-text search across all transcripts for a project.

**Query:**
```sql
SELECT
  session_id,
  event_time,
  transcript_text,
  body:segment_index::int AS segment_index
FROM hls_fde_dev.dev_matthew_giglia_lakeloom.transcript_events_raw
WHERE project_id = $1
  AND event_type = 'final_transcript'
  AND LOWER(transcript_text) LIKE LOWER('%' || $2 || '%')
ORDER BY event_time DESC
LIMIT 50
```

**v2 improvement:** Silver table with full-text index or `ai_similarity()` for semantic search.

---

## Client Components

### TranscriptPanel (new)

Location: `client/src/components/TranscriptPanel.tsx`

Renders inside `CaptureDetailPage` as a new tab or section alongside the existing upload timeline.

**Props:**
```typescript
interface TranscriptPanelProps {
  captureSessionId: string;
  isActive: boolean;  // true if capture is currently recording
  audioPlayerRef?: React.RefObject<HTMLAudioElement>;  // for time-sync
}
```

**Modes:**

1. **Historical mode** (`isActive = false`):
   - Fetches full transcript via `GET /api/captures/:id/transcript`
   - Renders segments as timestamped blocks
   - Clickable timestamps → seek audio player
   - Search/highlight within transcript (client-side filter)
   - Copy-to-clipboard button per segment or full transcript

2. **Live mode** (`isActive = true`):
   - Connects to `GET /api/captures/:id/transcript/stream` (SSE)
   - Appends segments as they arrive (DOM append, no full re-render)
   - Auto-scroll with "pinned to bottom" toggle
   - Pulsing recording indicator
   - Falls back to historical mode when session completes

### TranscriptSearch (new)

Location: `client/src/components/TranscriptSearch.tsx`

Project-level search across all session transcripts.

**Placement:** ProjectDetailPage, new "Search Transcripts" section or tab.

**UI:**
- Search input with debounce (300ms)
- Results as cards: snippet with highlighted match, session label, timestamp
- Click result → navigate to CaptureDetailPage with transcript scrolled to match
- Filter by date range (optional v2)

---

## Audio Sync Design

The `event_time` field in each transcript segment corresponds to when STT produced the text on-device. The audio file starts at the capture session's `started_at` timestamp. Sync formula:

```
audio_position_ms = segment.event_time - capture.started_at
```

When user clicks a transcript segment timestamp:
1. Calculate offset from session start
2. Seek `audioPlayerRef.current.currentTime = offset_ms / 1000`

When audio is playing, highlight the current transcript segment:
1. Track `audioPlayer.currentTime` via `timeupdate` event
2. Find segment where `offset <= currentTime < offset + duration_ms`
3. Apply highlight class + scroll into view

---

## Task Breakdown

| # | Task | Estimate | Dependencies |
|---|------|----------|-------------|
| 1 | Server: `GET /transcript` endpoint (SQL warehouse query) | 0.5 day | Warehouse connection pattern |
| 2 | Server: `GET /transcript/stream` SSE (in-memory relay from ingest) | 0.5 day | Task 1 |
| 3 | Client: `TranscriptPanel` historical mode | 0.5 day | Task 1 |
| 4 | Client: `TranscriptPanel` live mode (SSE) | 0.5 day | Tasks 2, 3 |
| 5 | Client: Audio sync (click-to-seek + highlight-during-play) | 0.5 day | Task 3, audio player exists |
| 6 | Server: `GET /search` endpoint | 0.25 day | Task 1 |
| 7 | Client: `TranscriptSearch` component | 0.5 day | Task 6 |
| 8 | Integration, testing, deploy | 0.5 day | All |

**Total: ~3.75 days**

---

## Open Decisions

1. **Warehouse connection from App** — The App currently uses Lakebase (Postgres) for OLTP. Querying the bronze UC table requires either:
   - Databricks SQL Statement Execution API (REST, async)
   - A pre-existing warehouse connection via the SDK
   - A Lakebase foreign-data-wrapper to UC (not available)
   
   **Recommended:** Use `@databricks/sql` driver or the Statement Execution REST API with the existing `DATABRICKS_WAREHOUSE_ID` env var.

2. **Live transcript relay scope** — Should the in-memory relay in Option C be:
   - Per-session (only push to SSE clients watching that session) ✅ Yes
   - Global (all transcript events broadcast, client filters) — wasteful

3. **Silver SDP timing** — Build as part of Phase 6 or defer?
   - **Defer** — bronze-direct is sufficient for v1 (153 records, fast queries)
   - Build silver when: record count grows past ~10K, or when gold/Agent layer needs it

4. **Transcript concatenation** — Should the API return raw segments or also a concatenated full-text view?
   - Return both: `segments[]` array + `full_text` string (server-side join with newlines)

---

## Architecture References

- **Bronze schema:** `databricks-architecture-overview-and-bronze.md` §6
- **Silver pipeline plan:** same doc §4.2
- **iOS ingest flow:** `module-03-ingest-service.md` (outbox → App proxy → ZeroBus)
- **iOS capture engine:** `module-02-capture-engine.md` §1.5 (file-upload shipped; live transcription design-only)
- **UI plan Phase 6:** `fixtures/databricks-app-ui-plan.md` §5 (Transcript Viewer)
- **ZeroBus target table:** validated 2026-05-21 (106+ records, sub-second ingest)

---

## Success Criteria

1. Historical transcript renders for any session with transcript data
2. Live transcript streams in real-time during active capture (< 1s latency)
3. Audio seek-to-timestamp works (click segment → audio jumps)
4. Audio-highlight-sync works (playing audio → current segment highlighted)
5. Project-level search returns matching segments with context
6. No new infrastructure required (uses existing warehouse + in-memory relay)
