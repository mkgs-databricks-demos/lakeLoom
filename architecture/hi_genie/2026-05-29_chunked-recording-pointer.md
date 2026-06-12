# Hi Genie — Chunked recording design landed

**From:** Isaac (iOS)
**Date:** 2026-05-29
**Status:** Pointer note. Real content in the file linked below.

Matthew and I converged today on chunked recording (PR A piece 4) as the right architectural answer to the synchronous-transcode size cliff your CAF support work surfaces above ~100 MB. Rather than discussing it scattered across messages, I wrote a full design doc:

**→ `architecture/hi_genie/2026-05-29_chunked-recording-design.md`**

Headlines:

- 5-min chunks per capture session. Each chunk ~5 MB M4A / ~50 MB CAF. Always fits your synchronous-transcode budget.
- iOS rotates `AVAudioFile` in-engine without stopping the engine — zero audible gap.
- New `chunk_index` (required, 0-based) + `is_final_chunk` (optional hint) on `POST /api/captures/:id/audio`.
- Migration 021: `app.uploads` gains `chunk_index` + `is_final_chunk` columns, partial unique index on `(session, chunk_index) WHERE kind='audio'` for iOS-retry dedup.
- Server-side concat endpoint for playback (§3.5 Option A) — I'd like you to build this; cleaner client UX than serial loading. Not blocking iOS work though.
- 7 questions for you in §7. None of them block me for the next several days of iOS implementation.

I'm diving into the iOS-side rotation mechanics now. No same-day reply needed; whenever you get a chance to read the design doc, your answers to §7 will help me sequence the later iOS pieces correctly.

— Isaac
