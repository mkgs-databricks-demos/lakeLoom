# Morning Session Repair — Complete

**Date:** 2026-06-06  
**Re:** Your note `hi_genie/2026-06-03_reconstruct-morning-session-A.md`

---

## TL;DR

Session `019e8881-6525-7104-a83f-31b2893730bd` is live in Lakebase. All 22 morning chunks landed successfully. **Your instinct was right — this IS the iOS recovery bug you were probing for.** The session was never created server-side; iOS uploaded against a UUID it generated locally but never registered.

---

## Your two questions answered

### 1. Was dev Lakebase wiped?

**No.** We have no record of a wipe. There is also no record of a `createCaptureSession` call ever reaching the server for session `019e8881` — no OTel event, no row in Lakehouse Sync, nothing. The session simply never existed on the server.

Most likely cause: the morning recording started while the device was offline (or the app crashed before the session creation call completed), and iOS's recovery path re-queued the audio uploads without first re-ensuring the session was registered.

**This is the iOS recovery gap you asked about.** `createCaptureSession` needs to be part of the upload recovery flow, not just audio upload re-queuing.

### 2. Session reconstructed?

**Yes, done.** Migration 022 (`022_repair_morning_session.ts`) inserts the row idempotently:

```
id:                           019e8881-6525-7104-a83f-31b2893730bd
project_id:                   b96fb42a-c55e-4df5-b83e-72c5c175e502
created_by_user_id:           1081964970114387@7474657291520070
created_by_paired_session_id: dc5c85cd-84e3-47a6-8992-adf8a462ab12
device_id:                    22b3dda0-5e0a-4c91-a90d-2aba36464378
device_label:                 Matthew's iPhone 17 Pro Max
state:                        active
started_at:                   2026-06-02T09:20:00Z  (estimate; actual ~13:24 UTC from filenames)
client_generated_id:          019e8881-6525-7104-a83f-31b2893730bd
```

All values mirrored from afternoon session `019e89b4`. `ON CONFLICT (id) DO NOTHING` makes it safe to re-run.

This is a one-time retroactive rescue — the systemic fix is on the iOS side (re-ensure session creation in the recovery path).

---

## Upload outcome

After migration deployed at **14:32:45 UTC (June 6)**, iOS flushed its retry queue within 6 minutes:

| Metric | Value |
|---|---|
| Chunks received | 22 |
| Status codes | 22 × 201 — zero 404s |
| Chunk range | `chunk0` → `chunk21` (contiguous, no gaps) |
| Final chunk | `chunk21` at 4.6 MB (all others ~8.5 MB) |
| Total audio | ~183 MB |
| Burst | 14:39:02 → 14:39:44 UTC (42 sec) |
| Filenames | `audio-20260602T132401-chunk{n}.m4a` |

---

## Migration debugging notes (for your awareness)

Migration 022 took three deploy attempts before landing — wrong export format (notebook generated AppKit v2 pattern, not this project's `{name, up: string}` shape), then a `DO $$` block that pg-pool misinterpreted as a parameter placeholder. Clean on the third try.

---

## State of `mg-genie-chunked-recording-server`

13 commits ahead of main, all deployed to dev. Server-side chunked-recording work is complete:

- Migration 021: `chunk_index` + `is_final_chunk` columns + partial unique index
- Upload handler: parses and stores chunk fields; dedup returns `dedup_sha_mismatch: bool`
- Endpoints: `GET /api/captures/:id/audio/chunks` + `GET /api/captures/:id/audio/stream` (ffmpeg concat)
- Migration 022: this repair

Ready for your `chunkDuration` flip and Phase B bake-test (7-min → 2 chunks, airplane-mode toggle, Siri interruption, force-quit mid-chunk-3). Before you do — worth adding `createCaptureSession` re-ensure to the iOS recovery path so we don't hit this again in the field.

— Genie
