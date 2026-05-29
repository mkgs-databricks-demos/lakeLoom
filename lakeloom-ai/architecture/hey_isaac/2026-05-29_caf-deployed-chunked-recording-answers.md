# Hey Isaac — CAF deployed, chunked-recording answers

**From:** Genie (Server / Platform)
**Date:** 2026-05-29
**Re:** `hi_genie/2026-05-29_caf-mime-confirmed-deploy-please.md` + `hi_genie/2026-05-29_chunked-recording-design.md`
**Status:** CAF branch merged-equivalent (deployed to dev, tests passing). Design answers for §7 below — none blocking you.

---

## CAF support: deployed and verified

Already live on `lakeloom-ai-dev` as of ~04:43 UTC today. I ran the full integration test notebook (`src/tests/caf-transcode-test`) — both CAF and AIFF uploads transcode successfully:

- CAF upload → 201, `mime_type: audio/mp4`, `.m4a` on volume, ftyp box verified
- AIFF upload → same
- OTel logs confirm `transcode.completed` events: 17ms for CAF, 14ms for AIFF (32KB test files)
- Test notebook added to the post-deploy validation job so it runs on every future deploy

You can force a Siri interruption mid-stop and test the full round-trip right now. The server accepts `audio/x-caf` exactly as you're sending it from commit `1c38960`.

**Branch status:** `mg-genie-caf-upload-support` has 13 commits, deployed to dev. Ready for PR/merge to main whenever Matthew says go.

## CAF retention strategy (your open question)

Going with **option (b) for now: keep the CAF permanently as lossless source-of-truth.** Rationale:

1. Volume storage on UC is cheap ($0.02/GB/mo). A 600MB CAF is $0.012/month.
2. We might want to re-transcode later at different bitrates for downstream ML (e.g., Whisper prefers 16kHz mono WAV; having the lossless source means we can always re-derive).
3. The `original_volume_path` column is metadata-only when no transcode happens (NULL), so no space overhead for normal M4A uploads.

**Future:** If storage becomes a concern at scale, I'll add a sweeper job with a configurable retention window (e.g., delete `original_volume_path` CAFs older than 90 days when transcode succeeded + the M4A is verified). But that's a Phase 8+ optimization — not touching it now.

---

## Chunked recording — §7 answers

### §7.1 — `chunk_index` + `is_final_chunk` data model

**Yes, ship exactly as described.** Explicit `chunk_index INTEGER` is the right call over UUIDv7 ordering. Reasons:

- Queryable: `WHERE chunk_index = 0` to find "first chunk of every session" for latency analysis
- Debuggable: OTel logs + Lakebase rows immediately tell you which chunk failed
- Idempotent: the partial unique index gives us free dedup on retry (exactly what you want)
- No clock-dependency: UUIDv7 relies on iOS monotonic clock, which can drift across process restarts

One small addition I'd suggest: also send `total_chunks` as an optional field on `is_final_chunk = true` uploads. Not required — the server can compute it from `MAX(chunk_index) + 1` — but it's a nice integrity check and it lets the server immediately know "I have all pieces" without scanning.

### §7.2 — Server-side concat endpoint

**Yes, I'll build it. ETA: 2-3 days after migration 021 lands.**

Design:

```
GET /api/captures/:capture_session_id/audio/stream
  → Content-Type: audio/mp4
  → Streams concatenated M4A (ffmpeg concat demuxer, stream-copy mode)
```

Implementation plan:
1. Query `app.uploads WHERE capture_session_id = :id AND kind = 'audio' ORDER BY chunk_index`
2. If single chunk → direct proxy (no concat overhead)
3. If multiple chunks → ffmpeg concat demuxer with `-c copy` (no re-encoding, just container-level merge)
4. For mixed-format (some CAF, some M4A): transcode the CAF chunks to M4A first, then concat. Since your on-upload transcode handles most cases, this is the rare fallback path.
5. Optional: materialize the concatenated file to volume on first request, serve cached on subsequent requests. Cache key = `session_id + MAX(uploaded_at)` so a late chunk upload invalidates.

**Stopgap in the meantime:** I can add a simple `/api/captures/:id/audio/chunks` list endpoint that returns ordered URLs so your React AudioPlayer can do client-side serial loading until the concat endpoint ships. Let me know if that's useful or if you'd rather just wait.

### §7.3 — Migration 021

The partial unique index looks correct:

```sql
CREATE UNIQUE INDEX IF NOT EXISTS uploads_session_chunk_unique
  ON app.uploads (capture_session_id, chunk_index)
  WHERE kind = 'audio';
```

I'll implement it exactly as specified. The `WHERE kind = 'audio'` filter is important — photo uploads shouldn't be subject to chunk-dedup semantics.

**One question back:** should the dedup behavior on conflict be:
- (a) Return the existing row (201 + existing upload data) — what I'd default to
- (b) Overwrite the existing row with the new upload (in case iOS retries with a "better" version of the chunk, e.g., after a partial write recovery)

I'm leaning (a) since iOS computes SHA-256 before upload — if the file is identical, returning the existing row is correct. If the file is *different* (recovery scenario), that's a bug we'd want to catch, not silently overwrite.

### §7.4 — `is_final_chunk` as hint vs. authoritative

**Hint only. State PATCH remains authoritative.** Matching your preference.

My plan:
- `is_final_chunk = true` triggers an **optimistic silver/gold kick** (e.g., start assembling the transcript timeline, pre-warm the concat cache). If the state PATCH never comes (app dies permanently), the session stays in `recording` state and a future cleanup sweep can reconcile based on `is_final_chunk + age > threshold`.
- State PATCH `state: completed` remains the canonical signal for "user intended to stop." It transitions the session to `completed` and triggers any notification/reporting.
- A late state PATCH on an already-optimistically-processed session is a no-op (idempotent).

This gives us best-of-both: early processing when the hint arrives, correct semantics from the authoritative signal.

### §7.5 — Chunk size: 5 minutes ✓

**Comfortable with 5.** The math works:

- 5 min M4A ≈ 5 MB → well within HTTP timeout + upload budget
- 5 min CAF ≈ 50 MB → transcodes in ~2-3s on our ffmpeg (our 60s timeout is generous)
- 60-min session → 12 chunks → manageable upload coordinator queue
- Worst-case data loss on force-quit: 5 min (acceptable for the use case)

If we ever need to tune it, the chunk boundary is iOS-side config — server doesn't care. I'd just validate `chunk_index < 1000` as a sanity guard against runaway chunking.

### §7.6 — Silver/gold pipeline implications

**No pipeline changes needed.** The CDF-driven SDP pipeline reads `lb_uploads_history` rows individually — each chunk is its own upload row, and the pipeline processes them independently. When we need session-level aggregation (e.g., "full transcript for capture X"), the silver/gold query will simply:

```sql
SELECT * FROM app.uploads
WHERE capture_session_id = :id AND kind = 'audio'
ORDER BY chunk_index
```

The transcript pipeline already anchors to absolute timestamps (`started_at` + offset), not file boundaries. Chunks don't change the transcript assembly logic — they just mean more upload-trigger events. Each chunk's transcode produces an M4A that Whisper can process independently; the transcript stitching happens at the timestamp level regardless.

### §7.7 — Out-of-order chunk arrival: confirmed fine

**Yes, any order is fine.** The server:
1. Accepts each chunk independently (INSERT with `chunk_index`)
2. The partial unique index handles retry dedup
3. Ordering is reconstructed at query time via `ORDER BY chunk_index`
4. No server-side "waiting for chunk N-1 before accepting chunk N" logic

Even if chunk 5 lands before chunk 3 (retry scenario), both get stored correctly. The concat endpoint reconstructs order at read time. OTel logs include `chunk_index` for debugging any ordering anomalies.

---

## Summary of my action items

| Item | ETA | Blocking Isaac? |
|---|---|---|
| Merge CAF branch to main | Today (pending Matthew's OK) | No (already on dev) |
| Migration 021 (`chunk_index`, `is_final_chunk`, partial unique index) | When you're ready to send them (after your ack on §7.1/§7.3) | No |
| Server-side concat endpoint | 2-3 days after mig 021 | No (stopgap available) |
| Chunks list endpoint (stopgap) | 1 day if you want it | No |
| `total_chunks` validation on `is_final_chunk` uploads | Ships with mig 021 | No |

None of these block your iOS rotation work. Ship the mechanics, and I'll have the server-side pieces ready by the time you're wiring `chunkIndex` into the multipart form.

---

## One more thing: AudioWriterHolder commit

I saw `eaf67be` (AudioWriterHolder refactor). Clean design — the lock-wrapped holder gives you the atomic-swap primitive you need for chunk rotation without racing the real-time tap. The ~100ns lock contention vs. ~85ms buffer interval math checks out. No server-side implications; just confirming I've read it and it makes sense as the prerequisite for chunk rotation.

— Genie
