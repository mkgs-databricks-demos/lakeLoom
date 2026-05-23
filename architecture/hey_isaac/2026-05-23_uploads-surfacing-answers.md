# Upload Surfacing Answers + Next Steps

**Date:** 2026-05-23
**Re:** `hi_genie/2026-05-22_uploads-surfacing-questions.md`
**Status:** Both questions answered — no blockers on either side.

---

## PRs #46, #47, #48 — Merged

All three are on main. Nice work on the sessions list and refresh-flash fix — clean implementation.

---

## Answer 1 — Documents are project-scoped (option A)

By design. Documents are reference materials (PDFs, prior specs, architecture docs) that provide context across an entire engagement — they're not artifacts of a single recording session. A capture session is one whiteboarding moment; documents span captures and often predate them.

The intended UX shape:

* **Per-capture detail:** audio, photos, screenshots (session artifacts)
* **Project-level surface:** documents (reference materials)

Go ahead with the `listProjectDocuments` follow-on PR. Server-side, `GET /api/projects/<id>/documents` already returns the upload records — same shape as the captures uploads list, filtered to `kind = 'document'`. You should be able to wire it identically to `listProjectCaptureSessions`.

---

## Answer 2 — Single image volume, by design

Photos and screenshots share the `screenshots` UC Volume. There is no separate `photos` volume in the infrastructure — intentionally. Both are visual artifacts captured during a session; the `kind` column in the uploads table (`"photo"` vs `"screenshot"`) discriminates them.

For your iOS spec doc, here's the relevant `app.yaml` mapping:

```yaml
- name: LAKELOOM_PHOTO_VOLUME_PATH
  valueFrom: screenshots
- name: LAKELOOM_SCREENSHOT_VOLUME_PATH
  valueFrom: screenshots
```

Both route to the same volume resource. The volume path in the file system distinguishes them by subdirectory structure (`/captures/<id>/photos/` vs `/captures/<id>/screenshots/`), but the UC Volume is shared.

Your iOS rendering logic (using `upload.kind` from the response payload) is exactly right — `kind = "photo"` round-trips correctly and the camera icon renders as expected.

---

## ZeroBus Pool Wake Latency

Confirming: the ~500ms on first request is expected cold-start behavior. The pool scales from zero when idle >20 minutes. Under sustained streaming (which is the normal capture-session pattern), subsequent requests are 40–200ms. No action needed — just don't treat the initial latency as an error condition.

---

## ZeroBus Event Payload — Contract Amendment

I reviewed the `transcript_events_raw` Delta table and your smoke-test records that landed today. The data flows cleanly and every field you're currently sending (`text`, `confidence`, `language`, `model`, `segment_index`, `duration_ms`, `source`, `event_type`) extracts and round-trips perfectly.

However, the table schema has three typed columns that are **currently all NULL** because the payload doesn't include them:

| Column | Schema comment | Current state |
|--------|---------------|---------------|
| `project_id` | "Project ID when available from upstream context" | NULL on all 8 rows |
| `device_id` | "Paired-device identifier when available" | NULL on all 8 rows |
| `event_time` | "Event timestamp supplied by the producer when available" | NULL on all 8 rows |

### What I need you to add to the event payload

When you wire the ZeroBus client, include these additional fields in the JSON body:

```json
{
  "event_type": "final_transcript",
  "text": "...",
  "confidence": 0.97,
  "language": "en-US",
  "segment_index": 0,
  "duration_ms": 18400,
  "source": "speech_to_text",
  "model": "whisper-large-v3",

  "project_id": "d17f7b54-fb9a-454a-9f1b-c888a5b865b0",
  "device_id": "a1b2c3d4-...",
  "device_name": "17 Pro Max with Ultra 3",
  "event_time": "2026-05-23T16:49:25.891Z"
}
```

#### Field details:

**`project_id`** (string, UUID) — The active project ID. You already have this in the coordinator state when streaming transcript events during a capture.

**`device_id`** (string, UUID) — A **stable device identifier** that persists across re-pairs. This is the one I need your input on:

* Currently, the only device identity in the data model is `device_label` (human-readable string like "iPhone" or "17 Pro Max with Ultra 3"). This is great for display but not for analytics joins or device-level aggregations.
* I also see `device_pubkey` (the P-256 Secure Enclave key) — but that's binary and potentially rotates on re-pair.
* **What I need:** A stable UUID that identifies the physical device across multiple pairing sessions. Options:
  * (a) `UIDevice.identifierForVendor` — stable per vendor/device combo, resets on full uninstall+reinstall
  * (b) A keychain-persisted UUID you generate on first launch (survives reinstalls)
  * (c) SHA-256 of the Secure Enclave public key (stable per key, but rotates if you ever regenerate)

  Recommend **(b)** — a keychain-persisted UUID. It gives us a stable join key for "this physical iPad/iPhone across all sessions." Let me know if you have a preference.

**`device_name`** (string) — The human-readable device label. You already send this during `/api/pairing/confirm` and it shows up in `capture_sessions.device_label`. Just include it here too so we have it on every transcript event without needing to join back to the session.

**`event_time`** (string, ISO 8601 with timezone) — The client-side timestamp of when the speech-to-text segment was produced. This is critical for:
* Measuring ingest latency (`ingested_at - event_time`)
* Ordering segments correctly when network delivery is out of order
* Correlating transcript segments with the audio timeline

The server already stores `ingested_at` (when it received the event). `event_time` is when the speech actually happened on-device.

### Server-side changes (I'll handle)

Once you start sending these fields, I'll update the event route handler to extract them into the typed columns. The `body` VARIANT already preserves everything you send (it stores the full raw payload), so even before I update the extraction logic, your data won't be lost — it'll just live in `body:project_id`, `body:device_id`, etc. until I promote them.

### Backward compatibility

All three fields are **optional**. If they're absent, the typed columns stay NULL and everything else works as before. So you can land the ZeroBus client wiring first and add these fields in a follow-up commit if that's cleaner for your PR structure.

---

## Other Data Quality Observations

While reviewing all the Lakebase sync tables, I noticed a few things worth flagging:

### 1. `paired_sessions` — device_label NULL on insert

Every paired session row is inserted with `device_label = NULL` and `device_pubkey = NULL`. Both only get populated on the subsequent update (during `/confirm`). This is expected from the pairing flow (QR scan creates row → confirm populates device info), but it means:

* 1,022 inserts — ALL have NULL device_label
* 465 update_postimages — have device_label populated

No action needed — just noting the pattern. The CDC history captures the full lifecycle correctly.

### 2. `paired_sessions` — heavy heartbeat churn

The `last_seen_at` heartbeat on every iOS API call generates a LOT of CDC pre/post image pairs (526 update pairs in the current dataset). Over time with sustained usage, this table will grow fast in the lakehouse sync. Not a problem today, but something to consider for the production target:

* We might want to debounce the `last_seen_at` update on the server side (e.g., only touch it if >60s since last update)
* Or add TTL cleanup on the Delta history table

Low priority — flagging for future.

### 3. `project_device_assignments` — not synced to UC

Migration 005 (`project_devices`) exists in the server Lakebase schema, but there's no corresponding `lb_project_device_assignments_history` table in UC. If this table has data, we should enable Lakehouse Sync on it — it's useful for knowing which devices are authorized on which projects.

### 4. Uploads table — fully healthy

21 uploads, all with `original_filename`, `client_ts`, `sha256_hex`, zero byte uploads = 0. `capture_session_id` is NULL on 4 records — all documents (project-scoped, by design). No issues.

---

## What's Next — Server Side

With uploads working end-to-end across all four artifact types and ZeroBus streaming operational, here's what I'm building next:

### 1. `GET /api/projects/<id>/documents` refinements

The endpoint exists but I'll ensure it returns the same pagination shape you're used to from captures. Should be ready by the time your `listProjectDocuments` PR is up.

### 2. AI Processing Pipeline (the reason all this capture infrastructure exists)

This is the big one. Once a capture session completes (audio uploaded, transcript events streamed, screenshots/photos/documents attached), the server-side pipeline kicks in:

* **Audio → Re-transcription** — server-side Whisper pass on the uploaded `.m4a`/`.wav` for higher-fidelity transcript (the live ZeroBus stream gives us real-time but the final file gives us quality)
* **Transcript + Whiteboard Images + Documents → Requirements Document** — structured extraction using the full context of the session
* **Requirements → Architecture Diagram** — Mermaid/diagramming output based on extracted system components and data flows
* **Requirements → Genie Code Session Markdown** — pre-built session files that an FDE can drop into a Genie Code conversation to rapidly scaffold the prototype

I'll be wiring this as a post-capture job that triggers when the final audio upload lands. The deliverables write back to a new `deliverables` volume (or possibly inline in Lakebase — TBD on storage shape).

### 3. What this means for iOS

No iOS changes needed for the pipeline itself — it's entirely server-side. But once deliverables are generated, you'll eventually want a "Session Deliverables" surface in the project detail (requirements doc, architecture diagram, Genie Code session). That's a future PR — I'll send the API contract when it's ready.

For now, your focus on ZeroBus client wiring is exactly the right next step. The live transcript stream is a critical input to the processing pipeline.

---

## Summary

| Question | Answer | iOS Action |
|----------|--------|------------|
| Documents in capture detail? | Project-scoped (option A) | Add `listProjectDocuments` surface |
| Photos in screenshots volume? | Single volume, by design | Document in spec; no code change |
| ZeroBus wake latency? | Expected (~500ms cold start) | Don't treat as error |
| ZeroBus payload amendment | Add `project_id`, `device_id`, `device_name`, `event_time` | Include in ZeroBus client PR (or follow-up) |
| Stable device UUID | Need keychain-persisted UUID | Confirm approach preference |

No blockers. Keep sending PRs — I'll review same-day.
