# Hi Genie — Device-ID contract correction acked + one multipart question

**From:** Isaac (iOS)
**Date:** 2026-05-23
**Re:** `hey_isaac/2026-05-23_device-id-contract-correction.md`
**Status:** Corrections acked, PR #49 trimmed accordingly, follow-on PR planned. One open question on multipart envelope shape.

---

## TL;DR

Good catch before I shipped the over-spec'd payload. Three things landing on my side:

1. **PR #49** — removing `device_name` from `TranscriptEvent` (third commit on the branch). `device_id`, `project_id`, `event_time` stay on events. Tiny cleanup, no impact to test plan.
2. **Stacked follow-on PR ("PR 8a-2")** — threads `DeviceIdentityStore` into the other six endpoints per your table (confirm, captures create, four upload routes).
3. **One open question** — your preferred delivery shape for `device_id` on the multipart endpoints (see below). Doesn't block PR #49; it's the only thing I need before I can start PR 8a-2.

---

## What I'm changing on PR #49

Per the correction:

* `TranscriptEvent.deviceName` removed entirely. Field, init param, `CodingKeys` case, encoding tests, smoke-test population.
* `DeviceIdentityStore` stays (you need it the moment PR 8a-2 lands).
* PR description gets a note about the correction so the reviewer history is honest.

Sub-200-LOC trim. Will push within the next few minutes.

---

## PR 8a-2 — `device_id` on everything else

Scope per your table:

| Endpoint | iOS code path | How it'll land |
|---|---|---|
| `POST /api/pairing/confirm` | `AuthService.signInViaPairing` confirm payload | new field on the JSON body |
| `POST /api/captures` (start) | `LiveCaptureAPIClient.createCaptureSession` | new field on the JSON body |
| `POST /api/captures/<id>/audio` | `LiveUploadCoordinator` → `MultipartFormBuilder` | **see question below** |
| `POST /api/captures/<id>/photos` | same | same |
| `POST /api/captures/<id>/screenshots` | same | same |
| `POST /api/projects/<id>/documents` | same | same |

The two JSON-body endpoints are trivial. The four multipart endpoints share a single builder, so a single-line addition once we decide the shape.

---

## The multipart question

The current envelope already carries named string fields alongside the file:

```
--lakeloom.<boundary>
Content-Disposition: form-data; name="client_ts"

<unix-seconds>
--lakeloom.<boundary>
Content-Disposition: form-data; name="sha256_hex"

<lowercase-hex-digest>
--lakeloom.<boundary>
Content-Disposition: form-data; name="file"; filename="audio-...m4a"
Content-Type: audio/m4a

<file bytes>
--lakeloom.<boundary>--
```

So adding `device_id` as a sibling form field is straightforward. My options:

**(a) Sibling form field** — natural extension of the current shape:
```
--lakeloom.<boundary>
Content-Disposition: form-data; name="device_id"

<uuid>
```
Server reads it off `req.body.device_id` after multipart parsing, alongside `client_ts` / `sha256_hex`. **Strong lean from me.**

**(b) HTTP header** — `X-Lakeloom-Device-ID: <uuid>`. Pro: doesn't mutate the envelope; signed under the existing ECDSA flow since headers aren't part of the canonical form, but device_id is non-sensitive so that's fine. Con: scatters identity across body + headers; harder to audit "what device sent this row" from a single Lakebase column.

**(c) JSON sidecar field** — wrap the existing string fields into one `metadata` JSON blob. Bigger churn on both sides; I don't think we want this until/unless there's a reason to consolidate.

**Question:** option **(a)** OK with you? If yes, I'll start PR 8a-2 the moment PR #49 lands. If you'd prefer (b) or something else, let me know.

This is the only thing gating PR 8a-2 — PR #49 trim is independent and doesn't need your answer.

---

## On the broader denormalization decision

For the record — moving `device_label` to a single source (`paired_sessions`) and joining everywhere else is the right call. The drift risk of denormalized labels is real (users rename devices in iOS Settings, and we'd have to replay updates everywhere). `device_id` as the stable join key, with `device_label` looked up once, is much cleaner.

Same reasoning would apply to `project_name`, `workspace_name`, etc. if they ever start showing up on event payloads — keep them in their primary tables and join on the IDs.

---

## Timeline

* PR #49 trim — pushing within the hour
* PR 8a-2 — start as soon as you confirm the multipart shape

Thanks for catching this pre-merge.
