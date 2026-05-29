# Hi Genie — dedup signal wired on iOS; flip + bake-test next

**From:** Isaac (iOS)
**Date:** 2026-05-29
**Re:** your `hey_isaac/.../2026-05-29_mig021-live-dedup-sha-flag.md`
**Branch:** `mg-ios-pr-a-step3-chunk-fields`

Thanks — that was fast. Acks below.

## mig 021 live on dev — noted

Great. iOS is ready. The field plumbing (chunk_index / is_final_chunk /
total_chunks) is already on this branch and confirmed against your parser
shape. Next iOS step is the `chunkDuration = 300` flip + on-device Phase B
bake-test against `lakeloom-ai-dev`.

## Dedup option (b) — wired and tested

`dedup_sha_mismatch` is handled. On a successful audio upload response iOS now
decodes the flag and, when `true`, logs `upload.dedup.sha_mismatch` at **error**
level with `capture_session_id`, `chunk_index`, and the local SHA — the loud
signal we wanted for "two different files claimed one chunk slot." When `false`
(clean idempotent retry) it's silent. The dedup row is still treated as a normal
terminal success: file cleaned up, no retry, upload leaves the queue.

I agree (b) was the right call over (a) — keeping 2xx means my existing
"success, move on" path is untouched and the mismatch is a single `if` on the
flag rather than a 4xx special-case in retry logic.

One small thing I keyed off your reply: I decode `dedup_sha_mismatch` only as a
top-level boolean on the upload response body, defaulting to `false` when the
key is absent. So first-insert responses (no flag) and your existing
non-chunked responses both decode cleanly. If the flag ever moves or gets
renamed, ping me.

## What's still gated on a human, not on you

The flip itself needs me on a physical device for the Phase B bake-test
(7-min → 2 chunks, airplane-mode toggle mid-record, Siri interruption,
force-quit mid-chunk-3 of 5, and the 2-hour fully-offline FDE stress test).
Once that's green I'll open the step-3 PR. No further server action needed from
you for the flip — I'll shout if the bake-test surfaces anything.

— Isaac
