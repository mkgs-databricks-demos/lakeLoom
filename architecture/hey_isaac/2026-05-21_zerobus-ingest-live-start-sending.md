# ZeroBus Transcript Ingest — Live & Ready

**Date:** 2026-05-21  
**Status:** ✅ Production-ready on dev target  
**TL;DR:** The speech-to-text events endpoint is fully operational. You can start sending transcript events from iOS at any time.

---

## What's Working

* E2E validated: iOS pairing → ECDSA-signed POST → ZeroBus ingest → Delta commit
* Batch ingest (up to 100 events per POST) — tested and confirmed
* Auto-scale: pool wakes from zero in ~500ms, scales to 3 streams under load
* Sub-second flush guarantee (1s timeout), Delta materialization within 8s
* Full teardown in CI/CD — test data cleaned automatically

---

## Endpoint Details

### URL

```
POST /api/sessions/{paired_session_id}/events
```

The `paired_session_id` is the UUID returned from the `/api/pairing/confirm` step (you already have this from the QR flow).

### Authentication

Same as all other lakeLoom iOS endpoints:
1. `Authorization: Bearer {spn_token}` — the Xcode SPN token from client_credentials grant
2. `X-Lakeloom-Session-Token: {session_token}` — from QR pairing
3. `X-Lakeloom-Timestamp: {unix_seconds}` — current time
4. `X-Lakeloom-Signature: {ecdsa_sig}` — ECDSA P-256 signature over canonical string

### Canonical String (for signature)

```
{METHOD}\n{PATH}\n{TIMESTAMP}\n{BODY_SHA256}
```

Where `BODY_SHA256` = hex-encoded SHA-256 of the raw request body bytes.

### Request Body

Single event OR array of up to 100 events:

```json
{
  "event_type": "final_transcript",
  "text": "The transcribed speech content...",
  "confidence": 0.97,
  "language": "en-US",
  "segment_index": 0,
  "duration_ms": 18400,
  "source": "speech_to_text",
  "model": "whisper-large-v3"
}
```

Or as an array for batching:
```json
[
  { "event_type": "final_transcript", "text": "...", ... },
  { "event_type": "final_transcript", "text": "...", ... }
]
```

### Supported `event_type` Values

| Type | When to send |
|------|-------------|
| `final_transcript` | Finalized speech-to-text segment (main one you'll use) |
| `partial_transcript` | Interim/streaming hypothesis (optional, for real-time UX) |
| `audio_uploaded` | After audio file upload completes (if you want to correlate) |
| `client_status` | Heartbeat or state change (recording_started, recording_stopped, etc.) |

### Response

```
202 Accepted
{ "accepted": 1 }  // or { "accepted": 5 } for batch
```

The 202 means the event is accepted into the ZeroBus buffer. It will materialize in Delta within ~8 seconds.

### Error Responses

| Code | Meaning |
|------|--------|
| 401 | Session token invalid/expired — re-pair |
| 403 | Signature verification failed |
| 422 | Body validation failed (missing required fields) |

---

## Important Notes

1. **Body must be compact JSON** — `JSON.stringify(payload)` with no extra whitespace. The ECDSA signature covers the exact bytes, so formatting matters.

2. **`Content-Type: application/json`** header is required.

3. **First request wakes the pool** — if the app has been idle >20 minutes, the ZeroBus stream pool will be at zero. First request takes ~500ms extra for wake. Subsequent requests are 40–200ms.

4. **Batch for efficiency** — if you have multiple segments from the same utterance, send them as an array in one POST rather than individual requests. Max 100 per batch.

5. **Any extra fields in the body are preserved** — the entire event object is stored in a VARIANT `body` column in Delta. So feel free to include `model`, `confidence`, `duration_ms`, `segment_index`, or any other metadata you want to surface later. We extract the known fields into typed columns AND keep the full raw payload.

6. **No ordering guarantee needed** — `segment_index` is stored for reconstruction. Events can arrive out of order.

---

## What Lands in Delta

Table: `hls_fde_dev.dev_matthew_giglia_lakeloom.transcript_events_raw`

| Column | Type | Source |
|--------|------|--------|
| `record_id` | STRING (PK) | App-generated UUID |
| `ingested_at` | TIMESTAMP | App-generated (epoch µs) |
| `event_id` | STRING | App-generated UUID (idempotency key) |
| `event_type` | STRING | From your payload |
| `session_id` | STRING | From URL path |
| `user_id` | STRING | From auth middleware |
| `transcript_text` | STRING | From `text` field |
| `transcript_language` | STRING | From `language` field |
| `source_platform` | STRING | Always `ios` |
| `body` | VARIANT | Full raw payload (everything you send) |

---

## Quick Test (from Swift)

```swift
let events: [[String: Any]] = [[
    "event_type": "final_transcript",
    "text": "Testing one two three",
    "confidence": 0.95,
    "language": "en-US",
    "segment_index": 0,
    "duration_ms": 2100,
    "source": "speech_to_text",
    "model": "whisper-large-v3"
]]

// Sign and POST to /api/sessions/{pairedSessionId}/events
// Expect: 202 { "accepted": 1 }
```

Let me know if you have questions about the signing flow or want me to adjust any field extraction logic on the backend.
