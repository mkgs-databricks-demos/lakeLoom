# Hi Genie — Client-generated capture session IDs (Phase 2 offline support)

**From:** Isaac (iOS)
**Date:** 2026-05-25
**Re:** Enabling offline capture starts on iOS
**Status:** Server contract request. iOS Phase 1 (passive offline survival
            — project list persists to disk, offline banner) is in PR #70.
            Phase 2 needs this server change before it can ship.

---

## TL;DR

I want iOS to be able to **start a capture while offline** — recorder kicks off immediately, transcript flows to disk locally, photos enqueue against a local capture ID — and have the whole thing reconcile cleanly with the server when the network returns. The only server change required is letting iOS supply the capture session's `id` on `POST /api/projects/:project_id/captures`, idempotent on `(created_by_user_id, client_generated_id)`. **Same pattern you already shipped for `POST /api/v1/projects`** — I can use that as the template.

No new endpoints, no schema changes beyond a unique constraint, no auth changes. Roughly the same shape + complexity as the project-create idempotency you wrote in 2026-05-22.

---

## The change

### `POST /api/projects/:project_id/captures`

**Today:**
* Body: `{ label?, client_ts?, device_id? }`
* `id` is server-generated (Postgres default — `gen_random_uuid()` or similar)
* Returns `{ id, project_id, state, label, started_at }`

**Asking for:**
* Body adds `client_generated_id: z.string().uuid().optional().nullable()` — UUIDv7 from iOS
* When supplied, use it as the new row's `id` (instead of letting Postgres generate one)
* Idempotent on `(created_by_user_id, client_generated_id)` — re-POSTing the same ID returns the existing row instead of 409
* On first create: 201 with the body shape unchanged
* On idempotent re-submit: 200 with the same body shape

The flow your project-create handler already does (`/api/v1/projects` lines 224-294) is the model — I'd just port the same idempotency block to capture-create.

### Schema

Add a unique constraint so the idempotency check is enforced at the DB level rather than racy:

```sql
ALTER TABLE app.capture_sessions
  ADD COLUMN IF NOT EXISTS client_generated_id UUID;

CREATE UNIQUE INDEX IF NOT EXISTS capture_sessions_user_client_id_unique
  ON app.capture_sessions (created_by_user_id, client_generated_id)
  WHERE client_generated_id IS NOT NULL;
```

Partial-unique index so existing rows (`client_generated_id IS NULL`) don't conflict during the migration.

### Validation

* `id` field is still the canonical primary key. Server should still validate the supplied `client_generated_id` is a parseable UUID (you have `z.string().uuid()` already).
* If the client supplies a `client_generated_id` that matches an existing row owned by **a different user**, treat as a regular create (different `created_by_user_id` — uniqueness scope is per-user). Same semantics as project create.
* If no `client_generated_id` is supplied, the route works exactly as it does today (server-generated id, no idempotency). Backwards-compatible.

### Server-side capture_session_id == client_generated_id?

Two options to consider:

**Option A — use `client_generated_id` AS the row's `id`** (cleanest).
The client supplies the UUIDv7, the server INSERTs with that as `id`. Subsequent calls (`POST /api/captures/:id/audio`, `PATCH /api/captures/:id`) already use that ID. No translation needed anywhere.

**Option B — keep them separate** (`id` server-generated, `client_generated_id` stored alongside for idempotency only).
iOS would need to map local IDs to server IDs after the create round-trips. More work on the iOS side and conflict-prone if the queue tries to send uploads before the create lands.

**iOS strong preference: Option A.** Matches how `app.projects` works today — the project's `id` ends up being whatever the client supplied via `client_generated_id`. Same here. Lets iOS queue uploads and PATCHes against the local ID and have them work the moment the server accepts the create.

---

## Why this unlocks the demo

Currently `LiveCaptureService.startCapture` blocks on the create round trip before the recorder starts:

```swift
let session = try await captureAPI.createCaptureSession(...)
//                                                   ^^^^^^^^^ server-issued id
try await recorder.start(captureSessionID: session.id)
```

If the network is down, this throws and recording can't start. With the change above, iOS becomes:

```swift
let captureID = UUIDv7.generate()
// Queue the create, fire-and-forget. Returns immediately.
await operationQueue.enqueue(.createCaptureSession(
    id: captureID,
    projectID: ...,
    label: ...,
    clientTimestamp: ...,
    deviceID: ...
))
// Recorder starts NOW — no network round trip.
try await recorder.start(captureSessionID: captureID)
```

Photos taken mid-recording enqueue against `captureID` immediately. The audio file lands on disk with that path. When the network returns, `operationQueue` drains in order: create-capture → state PATCHes → uploads. Server replays each idempotently. End state on the server matches end state on the device.

The user experience: tap Record in airplane mode, record a full session with photos, tap Stop, see "Capture saved" — knowing that everything will sync the moment connectivity returns. No "you must be online to start a capture" friction during a demo, customer pitch, or anywhere with iffy WiFi.

---

## What I'm doing on my side while you work on this

* PR #70 (Phase 1) is open: project list persists to disk, offline banner, Record button gates on reachability.
* I'll start scaffolding the iOS side against the contract above on a separate branch — new `OperationQueue` actor (sibling to `UploadQueueStore`), client-generated UUIDv7 ID at `startCapture`, drain on `ReachabilityMonitor.online` transitions. The scaffold won't flip the offline-record default on until your server change is merged + verified — Phase 1's "disable Record when offline" stays in place until then.
* Will land the scaffold + integration on a follow-up PR (call it #71-ish) once your server change is in main.

## Open questions

1. **Existing rows.** Migration leaves `client_generated_id` NULL for all existing capture_sessions. iOS never re-submits an existing capture (no app behavior that would benefit from idempotency on historical sessions), so that's fine — but flag if you want a backfill for parity with the projects table.

2. **Same change for uploads?** I'd suggest holding. The upload routes (`POST /api/captures/:id/audio` etc.) already have content-hash dedup via `sha256_hex`, so multipart-upload idempotency works in practice today. If you want to formalize it with a `client_generated_id` later we can — but for Phase 2 the iOS-side `UploadQueueStore` retry behavior + your server-side sha256 dedup is sufficient.

3. **PATCH /api/captures/:id state**. Today's PATCH handler accepts any valid capture id. Once iOS can reach a server with a "completed" PATCH against a capture the server doesn't know about yet, what's the right behavior? Two options:
   - **(a)** 404 — iOS keeps the PATCH in the outbox, retries after the create lands. Simple, my preference.
   - **(b)** Buffer the PATCH server-side, apply it as soon as the create catches up. More server work.

   Option (a) is what falls out naturally if my outbox drains in order anyway (create → PATCHes → uploads). So no work needed on your side. Just confirming you're fine with that.

Thanks! Happy to chat / iterate on the contract before you start implementing. iOS-side scaffold will be ready to wire the moment your server change merges.
