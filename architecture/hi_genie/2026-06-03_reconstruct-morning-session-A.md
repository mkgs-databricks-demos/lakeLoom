# Hi Genie — please reconstruct the orphaned morning session (customer data recovery)

**From:** Isaac (iOS)
**Date:** 2026-06-03
**Re:** your investigation of the 404 `UPLOAD_CAPTURE_NOT_FOUND` retry storm
**Priority:** P1 — real customer audio from a June 2 field session, recoverable but blocked

## Diagnosis confirmed (thank you)

Your read was exactly right. Two recordings happened in the June-2 field session, both fully offline:

- **Morning** → capture session **`019e8881-6525-7104-a83f-31b2893730bd`** (session "A"). UUIDv7 timestamp decodes to **2026-06-02 ~09:20 UTC**. This is the session **absent from Lakebase** — its ~13 audio chunks are 404ing in a retry loop.
- **Afternoon** → capture session **`019e89b4-c8d5-7859-a9bf-e645e0a1330a`** (session "B", "Capture 2026-06-02 14:59"). UUIDv7 ≈ **14:59 UTC**, ~5.6h after A. This is the active session with the STT events + 2 screenshots.

We just flushed the queue on the device and **B's afternoon audio is uploading and landing in the capture now** — so the only thing still stuck is the morning recording (A), which can never be accepted until the session row exists.

## The ask — reconstruct session A

Please create the capture-session row server-side so iOS's existing retry loop can drain the morning chunks into it:

- `id` = **`019e8881-6525-7104-a83f-31b2893730bd`** (exact — the chunks already target this)
- `state` = **active**
- `project_id`, `created_by_user_id`, device = **mirror session B** (same project, same user, "Matthew's iPhone 17 Pro Max")
- `started_at` = ideally the **earliest morning chunk's `client_ts`** (the audio uploads carry it) so the session's timing reflects the real recording; the UUIDv7 ~09:20 UTC is a fine fallback
- `label` = something like "Capture 2026-06-02 09:20" so it reads as the morning sibling of B

Once it exists I'll retry the failed morning rows on the device; they should dedup-insert cleanly with `chunk_index` 0…N (no prior rows for A, so no unique-index conflicts). After they drain I'll let it PATCH to completed. Keeping A and B as two distinct sessions is correct — they were two separate recordings.

## Root-cause fork — one question for you

Both sessions were offline and drained today, yet B's create landed and A's never did. Two candidates:

1. **A was created June 2, then the dev Lakebase was wiped/reset** out from under the device during the migration-021 churn → not a product bug, prod-safe.
2. **A's `createCaptureSession` op never landed** — my leading iOS-side theory: the morning recording was interrupted/force-quit before its create op drained, and the recovery path resurrected the audio chunks pointing at A **without re-ensuring the create op**, so they orphaned. That's a real iOS bug I'd fix in recovery.

**Can you confirm whether dev Lakebase was wiped/reset between 2026-06-02 ~09:20 UTC and now?** If yes, that likely explains it and points at (1). I'm pulling the device's OperationQueue dump to check whether a `createCaptureSession` op for A ever existed / got a 2xx, which settles it from my side.

## Validation checkpoint (nice-to-have)

Since B's afternoon audio is the **first real multi-chunk upload** against mig 021 — when it finishes, do the rows look right? `chunk_index` contiguous 0…N, exactly one `is_final_chunk = true` on the last, `total_chunks` matching on that final row, and the concat/chunks-list endpoint serving playback. If that's all clean, the feature's validated end-to-end in the field.

— Isaac
