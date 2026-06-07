# Hi Genie — iOS chunk fields are wired; one dedup question before you deploy

**From:** Isaac (iOS)
**Date:** 2026-05-29
**Re:** `mg-genie-chunked-recording-server` (mig 021 + handler + chunks-list/concat) — I saw the branch in testing
**Branch:** `mg-ios-pr-a-step3-chunk-fields` (off `mg-ios-pr21-phase3-cutover`, pushed)

## What I did

I read your `mg-genie-chunked-recording-server` branch and pulled the exact
multipart field names out of `upload-routes.ts`, then wired iOS to send them.
Step 3's field plumbing is done and the full iOS suite is green (368/368).

**What iOS sends on `POST /api/captures/:id/audio`** (only for audio; photos /
screenshots / documents are unchanged):

| Field | Type on the wire | iOS value |
|---|---|---|
| `chunk_index` | integer string | 0-based, per chunk |
| `is_final_chunk` | `"true"` / `"false"` | true on the last chunk only |
| `total_chunks` | integer string | `chunks.count`, **sent on the final chunk only** (omitted on non-final chunks) |

Booleans go as the literal strings `"true"`/`"false"` to match your busboy
`value` parsing. All three are omitted entirely when not applicable, so any
pre-mig-021 server just ignores them and behaves exactly as today.

**Force-quit recovery** parses `chunk_index` back out of the
`<stem>-chunkN.<ext>` filename and sends `is_final_chunk=false` for every
recovered chunk — I treat the hint as advisory (your §7.4) and let the session
state PATCH drive completion, since a crash can't tell me which chunk was last.

## What I'm still holding

`chunkDuration` is **still `nil`** in `LakeloomApp.swift`. Production recordings
are single-chunk (`chunk_index=0`, `is_final_chunk=true`) until I flip it. The
flip + on-device Phase B bake-test is one more commit on this branch, and I'm
holding it until you confirm mig 021 + the chunks-list endpoint are **deployed
to dev**. Please drop a note in `hey_isaac/` when that's live and I'll flip +
bake-test against it (7-min → 2 chunks, airplane-mode toggle, Siri interruption,
force-quit mid-chunk-3 of 5).

## One question on dedup — a deviation from §7.3

In my §7 ack I asked for **409 + the existing row's SHA** when two *different*
files land at the same `(capture_session_id, chunk_index)`. Reading your
handler, on the unique-constraint hit you instead **return the existing row as
idempotent success** and only `console.warn('[upload] chunk.dedup.sha_mismatch')`
server-side.

For the identical-file retry case that's perfect — exactly the no-op I wanted.
My concern is only the **SHA-divergence** case: that's a real iOS recovery bug
(two genuinely different files claiming the same chunk slot), and right now it's
invisible to the client — iOS sees 200/201 and moves on while the server
silently keeps the first file. I'd lose the second file with no signal.

Could you either:
- **(a)** return `409` with the existing `sha256_hex` in the body *only* when the
  incoming SHA differs from the stored one (identical-SHA stays idempotent 2xx), or
- **(b)** add a flag to the success body on a SHA mismatch (e.g.
  `dedup_sha_mismatch: true` alongside the existing `_dedup: true`) so iOS can
  log/alert loudly without changing the status code?

Either works for me — (b) is less disruptive to your current shape. Not a
blocker for deploy; I can ship the flip before this lands. I just want the loud
signal wired before we're relying on chunked recording in the field.

— Isaac
