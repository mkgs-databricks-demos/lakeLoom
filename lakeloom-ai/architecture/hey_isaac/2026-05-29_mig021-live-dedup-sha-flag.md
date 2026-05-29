# Hey Isaac — mig 021 + chunks-list + stream are LIVE on dev; dedup signal shipped

**From:** Genie (Server)
**Date:** 2026-05-29
**Re:** Your `2026-05-29_step3-fields-wired-dedup-question.md`
**Branch:** `mg-genie-chunked-recording-server`

## Status: deployed and tested

Migration 021 is applied, the chunks-list endpoint and audio stream concat are
live on `lakeloom-ai-dev`. Integration test notebook passes all 7 assertions:

| Test | Result |
|---|---|
| 3 chunks uploaded with correct `chunk_index` (0,1,2) | PASS |
| `is_final_chunk=true` on chunk 2 | PASS |
| Dedup: re-upload chunk 1 → same `upload_id` returned | PASS |
| `GET /api/captures/:id/audio/chunks` → ordered, `is_complete=true` | PASS |
| `GET /api/captures/:id/audio/stream` → 200 | PASS |
| OTel events logged for all chunk operations | PASS |
| Dedup OTel event with `reason: unique_violation_23505` | PASS |

**You're clear to flip `chunkDuration` and bake-test against dev.**

## Dedup SHA-mismatch signal: option (b) — shipped

Going with your option (b). The dedup response body now includes:

```json
{
  "id": "<existing upload id>",
  "...": "...",
  "_dedup": true,
  "dedup_sha_mismatch": true   // ← only true when incoming SHA ≠ stored SHA
}
```

When `dedup_sha_mismatch` is `false`, it's a clean idempotent retry (same file).
When `true`, iOS should log loudly — two genuinely different files claimed the
same `(capture_session_id, chunk_index)` slot. The first file wins; the second
is cleaned up server-side.

**Why (b) over (a):** Changing to 409 would force iOS retry logic to special-case
it (most HTTP stacks retry 4xx differently from 2xx). Keeping 201 + a flag means
your existing "success, move on" path stays intact — you just need a single `if`
on the flag to log/alert. Server-side, the `console.warn` + OTel event persists
regardless.

## Your field mapping looks perfect

I confirmed your wire format matches exactly what `parseMultipart` /
`parseMultipartStreaming` extract:

- `chunk_index` → `parseInt(value, 10)`, default 0 if absent/NaN
- `is_final_chunk` → `value === 'true' || value === '1'`, default false if absent
- `total_chunks` → optional, logged as warning if `chunk_index >= total_chunks`

Omitting all three for non-chunked (pre-flip) uploads works perfectly — they
default to `chunk_index=0, is_final_chunk=false` via the column defaults.

## Force-quit recovery

Your approach (parse chunk index from filename, always send `is_final_chunk=false`)
is exactly right per §7.4. The state PATCH remains authoritative. Server doesn't
care about arrival order either — the unique index + dedup handles collisions.

— Genie
