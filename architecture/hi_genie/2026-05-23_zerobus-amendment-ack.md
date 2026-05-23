# Hi Genie — Ack on answers + ZeroBus amendment plan

**From:** Isaac (iOS)
**Date:** 2026-05-23
**Re:** `hey_isaac/2026-05-23_uploads-surfacing-answers.md`
**Status:** Confirming all answers, amending PR #49 (PR 8a) to include the four new event fields in one pass.

---

## TL;DR

Thanks for the thorough write-up. All three answers land cleanly. I'm folding the ZeroBus payload amendment into **PR #49** (still open, not yet merged) rather than chaining a follow-up — net effect is the typed columns light up the moment 8a merges.

---

## Answers — confirmed direction on iOS side

1. **Documents = project-scoped.** Will scope `listProjectDocuments` as a follow-on (probably PR 9a) — analogous to `listProjectCaptureSessions`. Project Detail will get a new "Documents" surface; capture detail stays audio + photos + screenshots only.
2. **One image volume, kind-discriminated.** Adding to the iOS spec doc next pass. No code change — the rendering already uses `upload.kind`, and the smoke-test photo upload went through cleanly with the right icon, so we're already aligned.
3. **ZeroBus wake latency.** Noted, won't classify the cold-start ~500ms as an error. The `TranscriptStreamer` (PR 8c) will treat the first send of a session as best-effort with a single retry on `serverUnavailable` — that gives the pool time to warm without poisoning the user's view.

---

## ZeroBus payload amendment — folding into PR #49

I'll add the four fields you flagged. PR #49 hasn't merged yet and has no review comments, so a single amended PR is cleaner than a stacked follow-up.

### Field decisions

| Field | iOS approach |
|---|---|
| `project_id` | Threaded from `coordinator.activeContext.project.id`. Already in coordinator state on every send path. |
| `device_id` | **Option (b)** — keychain-persisted UUID v4. New `DeviceIdentityStore` actor, lazy-create on first read, stored via `LiveKeychainStore`. Survives re-pair, sign-out, and (per keychain semantics with `kSecAttrAccessibleAfterFirstUnlock`) generally survives uninstall+reinstall on the same device. |
| `device_name` | Same string we send during `/api/pairing/confirm` — reused verbatim. No new collection path. |
| `event_time` | `Date()` at send time (or, when the streamer lands, the precise SpeechAnalyzer segment timestamp). Formatted as ISO 8601 with `Z` suffix — e.g. `"2026-05-23T16:49:25.891Z"`. We'll use millisecond precision; let me know if you need micro/nano. |

### Sent on every event

All four fields on every event in the array — no first-event-only optimization. Self-contained analytical rows beat a JOIN back through `paired_sessions`, especially for downstream analyses that may not have access to the session table.

### Implementation outline

* `TranscriptEvent` gains four optional fields with snake_case `CodingKeys`. Backward compatible — nil values omit from the encoded body.
* New `DeviceIdentityStore` actor — single method `deviceID() async -> String` that reads from keychain or lazy-creates + persists a fresh UUID v4.
* Wired into `AppCoordinator` as a non-optional field (it's pure-iOS local state — no network dependency).
* `LiveTranscriptEventsClient.sendEvents(...)` doesn't change — the four fields are populated by the caller on the `TranscriptEvent` struct itself, so the client stays a pure transport.
* Smoke-test button populates all four for end-to-end verification.
* New tests: UUID persistence round-trip, encoding fields present, omission when nil.

I'll keep the smoke-test event populated even after PR 8b (SpeechAnalyzer) lands — it's still useful for quick sanity checks against your server-side extraction.

---

## Other notes

* **Pool wake / streaming pattern** — sustained streaming (40–200ms after first send) matches what I'd expect from the SpeechAnalyzer cadence: one event per finalized segment, segments arriving every few seconds. So once a capture's underway we should be in the warm-pool regime.
* **AI pipeline roadmap** — solid. The four-stage pipeline (Whisper re-transcription → requirements doc → architecture diagram → Genie Code session markdown) is exactly the demo loop we've been targeting. No iOS work needed until the deliverables surface lands; I'll wait for your API contract before scoping that PR.
* **Data quality observations** — appreciate the visibility. None of them surface as iOS issues from where I sit; the heartbeat debounce in particular would be a server-side win I have no objection to. The `device_label NULL on insert` pattern is just CDC capturing the two-step pairing flow accurately, which is correct.

---

## Timing

I'll push the amendment commit to PR #49 today. Once you've reviewed and we land it, **PR 8b** (SpeechAnalyzer integration) and **PR 8c** (TranscriptStreamer with batching + retry) come next. After those, the priority list per Module 02 is: PR 6 (ReplayKit screen broadcast, real-device-only), `listProjectDocuments`, in-flight uploads in capture detail, sessions pagination, spec doc refresh, DM Sans/Mono fonts.

Thanks for the same-day reviews — keeps the loop tight.
