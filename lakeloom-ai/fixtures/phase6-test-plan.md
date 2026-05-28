# Phase 6 — Transcript Viewer: Test Plan

**Date:** 2026-05-28
**Branch:** `main` (commits `d22de49`→`efbac02`→`78b5d93`)
**App:** `lakeloom-ai-dev`
**Status:** All code deployed. Manual browser verification pending.

---

## Prerequisites

- Paired iOS device with active capture session (or use existing session data)
- Browser logged in to Databricks workspace (OBO token active with `sql` scope)
- At least one capture session with transcript data in `transcript_events_raw`
- Known session: paired session `0128b3ae-bafd-4500-b246-009a59dc49a0` (OSU May 26, 20 segments)

---

## Test Matrix

### T1. Historical Transcript Rendering

 # | Scenario | Steps | Expected Result | Status |
---|----------|-------|-----------------|--------|
 1.1 | Load transcript for session with data | Navigate to `/projects/:id/captures/:cid` for a session with transcript events | TranscriptPanel shows segments with timestamps, confidence dots, segment count header | ☐ |
 1.2 | Empty transcript | Navigate to a capture session with no transcript data | "No transcript available" empty state with FileText icon | ☐ |
 1.3 | Cancelled session | Navigate to cancelled capture session | Panel renders (shows whatever was captured before cancel); no SSE connection attempted | ☐ |
 1.4 | Time-window scoping | Navigate to a capture whose paired session has data from MULTIPLE captures | Only segments within this capture's `started_at`→`ended_at` appear (not other captures' data) | ☐ |
 1.5 | Segment limit | Add `?limit=5` to transcript API call (DevTools) | Response contains max 5 segments (verify in Network tab) | ☐ |

### T2. Click-to-Seek (Transcript → Audio)

 # | Scenario | Steps | Expected Result | Status |
---|----------|-------|-----------------|--------|
 2.1 | Basic seek | Click any transcript segment timestamp | Audio player seeks to that position; waveform progress jumps | ☐ |
 2.2 | Seek while paused | Pause audio, click a later segment | Audio position updates but stays paused; resume plays from new position | ☐ |
 2.3 | Seek while playing | During playback, click a much earlier segment | Audio jumps back; playback continues from new position | ☐ |
 2.4 | No audio file | Open a capture that has transcript but no audio upload | Segments render without cursor styling; clicking does nothing (no crash) | ☐ |

### T3. Highlight-During-Play (Audio → Transcript)

 # | Scenario | Steps | Expected Result | Status |
---|----------|-------|-----------------|--------|
 3.1 | Active segment highlight | Play audio from start | Current segment gets Lava 600 border + subtle bg; timestamp turns bold accent color | ☐ |
 3.2 | Segment transitions | Let audio play through multiple segments | Highlight moves from segment to segment as audio progresses | ☐ |
 3.3 | End of transcript | Play past last segment | No segment highlighted after last one's timespan; no crash | ☐ |
 3.4 | Speed change | Change playback speed (2x) | Highlights still track correctly at higher speed | ☐ |

### T4. Auto-Scroll Follow Mode

 # | Scenario | Steps | Expected Result | Status |
---|----------|-------|-----------------|--------|
 4.1 | Follow during playback | Play audio; let active segment scroll below visible area | Panel auto-scrolls to keep active segment visible (smooth) | ☐ |
 4.2 | Manual scroll disengages | While audio plays, scroll the transcript panel up manually | "Follow" button appears in header; auto-scroll stops | ☐ |
 4.3 | Re-engage via button | Click the "Follow" button | Panel snaps to active segment; auto-scroll resumes | ☐ |
 4.4 | Re-engage via click-to-seek | While follow is off, click a segment | Follow re-engages; audio seeks; subsequent segments auto-scroll | ☐ |
 4.5 | Short transcript (no scroll) | Open a session with < 5 segments (fits in viewport) | No Follow button ever shown; no scroll behavior issues | ☐ |

### T5. Live Transcript Streaming (SSE)

 # | Scenario | Steps | Expected Result | Status |
---|----------|-------|-----------------|--------|
 5.1 | Connect to active capture | Open an active (recording) capture session in browser | "Live" indicator shows with green pulsing dot; `: connected` in SSE | ☐ |
 5.2 | Receive live segments | Speak into paired iPhone during active capture | Segments appear in real-time (< 1s from speech to screen) | ☐ |
 5.3 | Auto-scroll during live | Let multiple segments stream in | Panel scrolls to bottom for each new segment | ☐ |
 5.4 | Manual scroll stops auto-scroll | Scroll up during live stream | New segments still arrive but panel stays at scrolled position | ☐ |
 5.5 | Reconnect after disconnect | Kill app (force redeploy), reopen page | SSE reconnects automatically (1s, 2s, 4s backoff visible in DevTools) | ☐ |
 5.6 | Completed session transition | Complete the capture session while viewing | SSE closes cleanly; panel shows final state (no error) | ☐ |

### T6. Project-Level Search

 # | Scenario | Steps | Expected Result | Status |
---|----------|-------|-----------------|--------|
 6.1 | Basic search | On ProjectDetailPage, type a known word in search box | Results appear after 400ms debounce with highlighted match, session label, timestamp | ☐ |
 6.2 | Click result navigates | Click a search result card | Navigates to `/projects/:id/captures/:cid` (the matching session) | ☐ |
 6.3 | No results | Search for "xyznonexistent123" | "No results found" message shown | ☐ |
 6.4 | Special characters | Search for text with quotes, ampersands, SQL metacharacters | No SQL errors; results return correctly (or empty set) | ☐ |
 6.5 | Empty query clears results | Type a search, get results, then clear the input | Results disappear; no stale results shown | ☐ |
 6.6 | Enter key triggers immediate search | Type and press Enter (no 400ms wait) | Search fires immediately | ☐ |

### T7. Graceful Shutdown

 # | Scenario | Steps | Expected Result | Status |
---|----------|-------|-----------------|--------|
 7.1 | Clean shutdown with SSE clients | Have browser open on active capture (SSE connected); redeploy | OTel shows `[shutdown] SSE connections closed.` then `ZeroBus streams closed.` then `Clean exit.`; no 15s timeout ERROR | ☐ |
 7.2 | Shutdown without SSE clients | Redeploy with no active browser viewers | Same clean exit sequence; no errors | ☐ |

### T8. Auth & Scoping

 # | Scenario | Steps | Expected Result | Status |
---|----------|-------|-----------------|--------|
 8.1 | OBO token forwarded | Open DevTools Network; load transcript | SQL Statement Execution API call uses user's token (not App SPN) | ☐ |
 8.2 | Missing sql scope | Revoke consent, reload without re-consenting | Transcript returns 403 or error message mentioning scope; panel shows error state | ☐ |
 8.3 | Re-consent flow | Open in incognito, grant new scopes | Transcript loads successfully after consent | ☐ |

---

## Regression Checks

These features worked previously; verify they still work after Phase 6 changes:

 # | Area | Quick Check |
---|------|-------------|
 R1 | Audio playback (no transcript) | Play audio in a session that has audio but no transcript → player works normally |
 R2 | Upload timeline | Non-audio uploads still show in left column with icons, sizes, MIME types |
 R3 | Browser uploads | Drag-drop a PNG into capture detail page → upload succeeds, appears in timeline |
 R4 | Session state transitions | Mark active session as completed → state badge updates, SSE disconnects |
 R5 | Project-level documents | Open documents from project page → MediaModal renders correctly |

---

## OTel Validation Queries

Run after testing to confirm clean operation:

```sql
-- Errors in last 30 min (should be 0)
SELECT time, severity_text, body::string
FROM hls_fde_dev.dev_matthew_giglia_lakeloom.lakeloom_ai_otel_logs
WHERE time > current_timestamp() - INTERVAL 30 MINUTES
  AND (severity_text = 'ERROR' OR body::string LIKE '%error%')
ORDER BY time DESC;

-- Shutdown sequence (after redeploy)
SELECT time, body::string
FROM hls_fde_dev.dev_matthew_giglia_lakeloom.lakeloom_ai_otel_logs
WHERE body::string LIKE '%[shutdown]%'
ORDER BY time DESC
LIMIT 10;

-- Transcript endpoint usage
SELECT time, body::string
FROM hls_fde_dev.dev_matthew_giglia_lakeloom.lakeloom_ai_otel_logs
WHERE body::string LIKE '%transcript%'
ORDER BY time DESC
LIMIT 20;
```

---

## Known Limitations (Not Bugs)

1. **Silver SDP not built** — v1 queries bronze directly. Performance is fine for current scale (< 200 records). Silver pipeline is Phase 6.5 enhancement.
2. **No speaker diarization** — iOS STT produces single-speaker segments. Multi-speaker labels will come with Whisper pipeline in gold layer.
3. **Search is LIKE-based** — No ranking, no fuzzy match, no semantic search. Silver table with full-text index is planned.
4. **Segment limit** — Sessions with > 500 segments show first 500 (configurable via `?limit=`). UI doesn't indicate truncation yet.
5. **SSE reconnect max 10 attempts** — After 10 failed reconnects (~8 min), stops trying. User must reload page.
