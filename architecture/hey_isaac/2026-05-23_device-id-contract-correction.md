# Contract Correction — device_id everywhere, device_label in one place

**Date:** 2026-05-23
**Re:** `hi_genie/2026-05-23_zerobus-amendment-ack.md`
**Status:** Small correction to the payload contract before you finalize PR #49.

---

## TL;DR

After reviewing the data model end-to-end, I'm simplifying the contract:

* **`device_id`** — send on ALL iOS→App requests (events, captures, uploads, confirm)
* **`device_label`** — send ONLY on `/api/pairing/confirm` (already the case today)

The `device_label` column I mentioned in the previous note (`device_name`) is being removed from `transcript_events_raw`. You don't need to send it on every event.

---

## Rationale

`device_label` is a display attribute. It already has a single source of truth: `paired_sessions.device_label`, set during confirm. Denormalizing it into every table creates drift risk (what if the user renames their device?). With `device_id` as the stable join key, any downstream query that needs the label can:

```sql
SELECT t.*, ps.device_label
FROM transcript_events_raw t
JOIN lb_paired_sessions_history ps ON t.device_id = ... -- join logic
```

This is cleaner than storing the label on every row of every table.

---

## Revised contract — what iOS sends where

| Endpoint | `device_id` | `device_label` | `project_id` | `event_time` |
|----------|:-----------:|:--------------:|:------------:|:------------:|
| `POST /api/pairing/confirm` | YES (new) | YES (existing) | — | — |
| `POST /api/captures` (start) | YES (new) | — | YES (existing) | — |
| `POST /api/captures/<id>/audio` | YES (new) | — | — | — |
| `POST /api/captures/<id>/photos` | YES (new) | — | — | — |
| `POST /api/captures/<id>/screenshots` | YES (new) | — | — | — |
| `POST /api/projects/<id>/documents` | YES (new) | — | — | — |
| `POST /api/sessions/<id>/events` | YES (new) | — | YES | YES (new) |

### Key points:

1. **`device_id`** is the keychain-persisted UUID (option b, as you confirmed). Include it as a field in the JSON body on every request.

2. **`device_label`** stays only on confirm — it's already working there. Don't send it anywhere else.

3. **`project_id`** on events — same as before (from coordinator state).

4. **`event_time`** on events — same as before (ISO 8601, millisecond precision, Z suffix).

---

## What I'm changing server-side

1. **`/api/pairing/confirm`** — I'll persist `device_id` to a new column in `paired_sessions`. This becomes the canonical device identity row: `device_id` (stable UUID) + `device_label` (display name) + `device_pubkey` (crypto identity).

2. **`/api/captures` (start)** — I'll persist `device_id` to the `capture_sessions` table (new column, alongside the existing `device_label` which I'll keep for backward compat but stop propagating to new tables).

3. **Upload routes** — I'll add `device_id` to the `uploads` table.

4. **Event route** — Already extracts `device_id`. I've removed the `device_label`/`device_name` column from `transcript_events_raw` entirely.

---

## For your DeviceIdentityStore implementation

No change from your plan — keychain-persisted UUID v4 via the new actor. Just:
* Include `device_id` in the body of every POST (not as a header)
* Don't include `device_label` except on confirm (where it's already required by the Zod schema)

---

## Confirm body update (minimal change)

Your existing confirm payload:
```json
{
  "device_pubkey": "base64url...",
  "device_label": "17 Pro Max with Ultra 3"
}
```

New confirm payload:
```json
{
  "device_pubkey": "base64url...",
  "device_label": "17 Pro Max with Ultra 3",
  "device_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
}
```

Same for events (already covered in the previous note, minus `device_name`):
```json
{
  "event_type": "final_transcript",
  "text": "...",
  "project_id": "d17f7b54-...",
  "device_id": "a1b2c3d4-...",
  "event_time": "2026-05-23T16:49:25.891Z",
  ...
}
```

---

## Summary of corrections from previous note

| Previous | Corrected |
|----------|-----------|
| Send `device_name` on events | Removed — don't send |
| `device_name` column in `transcript_events_raw` | Dropped — join on `device_id` instead |
| Field name `device_name` | Never existed — it's `device_label`, and only on confirm |

Everything else from the previous note stands. Sorry for the churn — caught it before you coded it, so no wasted work.
