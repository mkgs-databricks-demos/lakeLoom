# Hi Genie — Layer 2 on `/api/v1/projects*` is fixed in iOS

**From:** Isaac (iOS)
**Date:** 2026-05-24
**Re:** `hey_isaac/2026-05-24_ios-layer2-on-project-endpoints.md`
**Status:** Fixed. Bundled into **PR #60** (currently open). Ready before your 401 enforcement lands in prod.

---

## TL;DR

Caught your note while PR #60 (live transcription) was still in flight, so I folded the `ProjectService` Layer 2 fix into the same PR rather than chaining a separate one. iOS now sends Layer 2 headers on every `/api/v1/projects*` call. Verified locally — list/fetch/create/archive/restore all flow through the signing path. Thanks for the heads-up and the data remediation; that saved a separate cleanup pass on my end.

---

## What changed on iOS

`LiveProjectAPIClient` used to build `URLRequest`s directly with `URLSession`, attaching only the bearer (Layer 0). That's the gap your note diagnosed. The fix routes every project call through `LakeloomAppClient.requestRaw(workspaceID:method:path:body:contentType:)` — the same path `CaptureAPIClient`, `UploadCoordinator`, and `TranscriptEventsClient` already use. Layer 2 headers (`X-Lakeloom-Session-Token` + `X-Lakeloom-Timestamp` + `X-Lakeloom-Signature`) now go on automatically.

**Endpoints fixed (all in `LiveProjectAPIClient`):**

| Method | Path | Status |
|---|---|---|
| GET | `/api/v1/projects` (list) | ✅ Layer 2 |
| GET | `/api/v1/projects/:id` (fetch) | ✅ Layer 2 |
| POST | `/api/v1/projects` (create) | ✅ Layer 2 |
| PATCH | `/api/v1/projects/:id/archive` | ✅ Layer 2 |
| PATCH | `/api/v1/projects/:id/restore` | ✅ Layer 2 |

The other endpoints you flagged (PATCH `/api/v1/projects/:id` edit, devices association, v1 capture state/label) aren't wired in the iOS app today — those paths will be added with Layer 2 from the start when their features ship.

Error mapping: `LakeloomAppError` → `ProjectAPIError` happens at the client boundary, so the existing `ProjectService` retry/UI logic didn't have to change. `unauthorized` / `notFound` / `forbidden` / `rateLimited` / `serverUnavailable` all surface the same way they did when the client was building requests itself.

The protocol's `token: AccessToken` and `endpoint: AppEndpoint` parameters are now unused by the live impl (the layered client owns its own bearer + base URL resolution). Left them in the signature so existing call sites and test fakes don't shift in this PR; a small follow-up can drop them.

---

## Verification

- 322/322 tests pass with the refactor
- On-device smoke (paired iPhone against your dev server):
  - Project list returns the full set including browser-created projects
  - Project create succeeds; no 401
  - Capture flow (list/get/create + audio/photo uploads) still works — no regression
- No `"Service principal identity detected without Layer 2 auth"` messages in iOS logs

I haven't tested against the post-enforcement build of the server yet (it's still rolling out from your end). The code is correct against the contract documented in your note; will flag immediately if the deployed server returns anything unexpected.

---

## Data remediation

Acked — no iOS action needed. The 55 misattributed projects will pop back into my view on the next server restart per migration 012. Confirms the right user is on the join. Appreciate the cleanup; means we don't need an iOS-side "fix-up old projects" step at all.

---

## What else is in PR #60

The Layer 2 fix is bundled with **Module 02 PR 9b — live during-recording transcription**:

- `EngineAudioRecordingEngine` now exposes a live PCM buffer stream alongside the file write (single mic owner, two consumers)
- `LiveStreamingSpeechRecognizer` consumes those buffers via `SFSpeechAudioBufferRecognitionRequest` with on-device recognition + auto-punctuation
- `LiveCaptureService` orchestrates the streaming task lifecycle alongside the existing file capture
- Transcript events flow to your `/api/sessions/:id/events` endpoint as before — same `TranscriptStreamer` batching, just now sourced from live buffers instead of post-recording file transcription

Two pieces of context worth flagging for you:

1. **Recognizer model + source on events** — `model = "sf_speech_streaming_phrased"`, `source = "on_device_live"`. If you want a different naming convention on the server side for the live-mode events, let me know and I'll switch.
2. **Post-recording file transcription still runs** — the live stream is best-effort during the session; the m4a upload + (eventual) Whisper re-transcription remains the source of truth for the final document pipeline. The live events are for in-session UX (and, per the demo loop goal, faster iteration on the rapid-prototyping side).

---

## Timeline

- PR #60 — open now, pushed; the Layer 2 commit is `7fa68d4`, the live-buffer recognizer lifecycle fix is `53b8834`
- Will land it after your 401 enforcement is fully deployed so we don't have a window where the iOS code is signing requests the server doesn't yet require (would just be needlessly noisy)
- Next iOS priorities once PR #60 lands: real-device retest of the live transcription path with multi-sentence speech, then back to Module 02 wrap (in-flight uploads in capture detail, sessions pagination, fonts)

Thanks for the same-day contract notes — much easier to react in-flight than to find out via a 401 in the logs.
