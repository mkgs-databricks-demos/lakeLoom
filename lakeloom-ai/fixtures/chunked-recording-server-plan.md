# Chunked Recording — Server-Side Implementation Plan

**Date:** 2026-05-29
**Branch:** `mg-genie-chunked-recording-server` (to be created after CAF branch merges)
**Responds to:** Isaac's `hi_genie/2026-05-29_chunked-recording-design.md`
**Status:** Planning. No blockers from Isaac — he has days of iOS-only rotation work first.

---

## Overview

Isaac is implementing chunked recording on iOS (PR A piece 4). A 60-minute capture session becomes ~12 independent 5-minute chunks, each uploaded separately. The server needs to:

1. Accept `chunk_index` + `is_final_chunk` on audio uploads
2. Enforce per-session chunk dedup (partial unique index)
3. Serve concatenated audio for playback
4. Optionally trigger early silver/gold processing on `is_final_chunk`

## Design Decisions (from §7 answers committed in `1cefd6e`)

| Question | Decision |
|---|---|
| Data model | `chunk_index INTEGER DEFAULT 0` + `is_final_chunk BOOLEAN DEFAULT FALSE` |
| Dedup behavior | Return existing row on unique conflict (not overwrite) |
| `is_final_chunk` semantics | Hint only — state PATCH remains authoritative |
| Chunk size | 5 min (iOS-controlled, server doesn't enforce) |
| Arrival order | Any order accepted; reconstructed via `ORDER BY chunk_index` |
| Playback | Server-side concat (Option A) — ffmpeg concat demuxer |
| Pipeline impact | None — CDF reads individual upload rows |

---

## Tasks

### Phase 1: Data Model (no behavior change)

#### Task 1.1 — Migration 021: `chunk_index` + `is_final_chunk`

**File:** `server/migrations/021_upload_chunked_recording.ts` (new)

```sql
ALTER TABLE app.uploads
  ADD COLUMN IF NOT EXISTS chunk_index INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS is_final_chunk BOOLEAN DEFAULT FALSE;

CREATE UNIQUE INDEX IF NOT EXISTS uploads_session_chunk_unique
  ON app.uploads (capture_session_id, chunk_index)
  WHERE kind = 'audio';
```

**Also:** Register in `server/migrations/migrate.ts`

**Backward compat:** Existing rows get `chunk_index = 0`, `is_final_chunk = false`. Pre-chunking captures appear as single-chunk sessions — correct for concat and playback.

---

#### Task 1.2 — Upload handler: parse new fields

**File:** `server/routes/uploads/upload-routes.ts`

Changes:
- Parse `chunk_index` from multipart form fields (default: `0`)
- Parse `is_final_chunk` from multipart form fields (default: `false`)
- Parse optional `total_chunks` (integrity hint, not stored — log only)
- Add `chunk_index` and `is_final_chunk` to INSERT query params
- Log `chunk_index` and `is_final_chunk` in structured OTel event

Validation:
- `chunk_index` must be non-negative integer
- `is_final_chunk` must be boolean-ish (`true`/`false`/`1`/`0`)
- If `total_chunks` provided, log warning if `chunk_index >= total_chunks`

---

#### Task 1.3 — Dedup on unique constraint violation

**File:** `server/routes/uploads/upload-routes.ts`

When INSERT hits `uploads_session_chunk_unique`:
1. Catch the unique violation error (PG error code `23505`)
2. Query for existing row: `SELECT * FROM app.uploads WHERE capture_session_id = $1 AND chunk_index = $2 AND kind = 'audio'`
3. Return 201 + existing row data (idempotent from iOS perspective)
4. Log `[upload] chunk.dedup` event (OTel) with upload_id of existing row
5. Do NOT overwrite — if SHA differs, log a warning but still return existing

**Rationale:** iOS computes SHA before upload. Identical SHA = true retry. Different SHA = bug (log it, don't silently corrupt).

---

### Phase 2: Playback

#### Task 2.1 — Chunks list endpoint (stopgap)

**File:** `server/routes/captures/capture-routes.ts` (or new file)

```
GET /api/captures/:capture_session_id/audio/chunks
→ 200 JSON: { chunks: [{ chunk_index, upload_id, volume_path, mime_type, size_bytes, duration_hint }] }
```

Ordered by `chunk_index ASC`. This gives the React AudioPlayer enough to do client-side serial loading as a stopgap until the concat endpoint ships.

---

#### Task 2.2 — Server-side concat endpoint

**File:** `server/routes/captures/audio-stream-route.ts` (new)

```
GET /api/captures/:capture_session_id/audio/stream
→ Content-Type: audio/mp4
→ Body: concatenated M4A stream
```

Implementation:
1. Query chunks: `SELECT volume_path, mime_type, chunk_index FROM app.uploads WHERE capture_session_id = :id AND kind = 'audio' ORDER BY chunk_index`
2. **Single chunk:** Pipe file directly (no concat overhead)
3. **Multiple chunks, all M4A:** ffmpeg concat demuxer with `-c copy` (stream-copy, no re-encode)
4. **Mixed format (some CAF):** Transcode CAF chunks to M4A first (temp files), then concat
5. Stream response (no full buffering — pipe ffmpeg stdout to HTTP response)

ffmpeg concat filter file format:
```
file '/Volumes/.../chunk-0.m4a'
file '/Volumes/.../chunk-1.m4a'
file '/Volumes/.../chunk-2.m4a'
```

Command: `ffmpeg -f concat -safe 0 -i <list.txt> -c copy -movflags +faststart -f mp4 pipe:1`

**Caching (optional, Phase 3):** Materialize concatenated file to volume on first request. Cache key = `{session_id}_{max_uploaded_at_epoch}`. Invalidated if a new chunk arrives.

---

#### Task 2.3 — AudioPlayer: multi-chunk support

**File:** `client/src/components/media/AudioPlayer.tsx`

Until concat endpoint ships:
- Detect multi-chunk captures (query chunks list endpoint)
- For single-chunk: existing behavior (direct src URL)
- For multi-chunk: use concat stream endpoint URL as src

Once concat endpoint ships, the AudioPlayer doesn't need to know about chunks — it just plays the stream URL.

---

### Phase 3: Intelligence (can defer)

#### Task 3.1 — Optimistic silver/gold trigger on `is_final_chunk`

When `is_final_chunk = true` arrives:
- Emit a ZeroBus event or internal trigger: `capture.chunks_complete`
- Downstream: kick off transcript assembly, silver/gold processing
- This is *advisory* — the state PATCH remains the authoritative "done" signal
- If state PATCH never comes (app died), a sweep job reconciles after N hours

#### Task 3.2 — Session completeness check

New helper: `isSessionComplete(capture_session_id)`:
1. Find the chunk with `is_final_chunk = true`
2. Verify `chunk_index + 1` rows exist (0 through chunk_index)
3. Return `{ complete: boolean, missing_chunks: number[] }`

Used by concat endpoint (refuse to concat incomplete sessions?) and by sweep job.

#### Task 3.3 — CAF sweeper job (long-term, Phase 8+)

Configurable retention for `original_volume_path` CAFs:
- Default: keep forever (lossless source-of-truth)
- Optional: delete after 90 days when transcode succeeded + M4A verified
- Only runs on sessions where state = `completed`

---

## File Inventory

| File | Action | Task |
|---|---|---|
| `server/migrations/021_upload_chunked_recording.ts` | Create | 1.1 |
| `server/migrations/migrate.ts` | Update (register 021) | 1.1 |
| `server/routes/uploads/upload-routes.ts` | Update (parse fields, dedup) | 1.2, 1.3 |
| `server/routes/captures/capture-routes.ts` | Update or new file | 2.1 |
| `server/routes/captures/audio-stream-route.ts` | Create | 2.2 |
| `client/src/components/media/AudioPlayer.tsx` | Update | 2.3 |
| `src/tests/chunked-recording-test.ipynb` | Create | Integration test |
| `resources/post_deploy_validation.job.yml` | Update (add test task) | CI |

---

## Sequencing

```
Phase 1 (foundation) ──────────────────────────────────
  1.1 Migration 021          ← ship immediately
  1.2 Parse chunk fields     ← ship with migration
  1.3 Dedup handler          ← ship with migration
  
Phase 2 (playback) ────────────────────────────────────
  2.1 Chunks list endpoint   ← ship next day (stopgap)
  2.2 Concat stream endpoint ← 2-3 days after Phase 1
  2.3 AudioPlayer update     ← after 2.2

Phase 3 (intelligence) ────────────────────────────────
  3.1 is_final_chunk trigger ← after Isaac enables real chunking
  3.2 Completeness check     ← with 3.1
  3.3 CAF sweeper            ← Phase 8+ (deferred)
```

**Isaac's timeline:** He's doing iOS rotation mechanics now (days of work). He'll wire `chunk_index` into multipart form after our Phase 1 lands. We have plenty of runway.

---

## Testing Strategy

**Integration test notebook:** `src/tests/chunked-recording-test.ipynb`
- Upload 3 chunks (chunk_index 0, 1, 2) with is_final_chunk on chunk 2
- Verify all 3 stored with correct chunk_index
- Upload duplicate chunk 1 → verify dedup (same row returned)
- Call chunks list endpoint → verify ordered response
- Call concat endpoint → verify valid M4A stream
- Verify OTel logs for chunk events

**Add to post-deploy validation job** alongside CAF transcode test.

---

## Dependencies

- **CAF branch merge to main** — Phase 1 builds on the transcode infrastructure (ffmpeg, migration pattern)
- **Isaac's iOS work** — not blocking us; he'll send chunk_index when ready
- **ffmpeg already installed** — from CAF branch (prestart hook)

---

## Open Items

- [ ] Confirm with Matthew: merge CAF branch first, then create chunked-recording branch?
- [ ] Decide: concat endpoint returns 206 Partial Content for incomplete sessions, or 409?
- [ ] Decide: concat caching — eager (materialize on is_final_chunk) vs. lazy (first request)?
