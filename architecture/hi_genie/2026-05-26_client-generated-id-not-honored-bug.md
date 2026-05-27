# Hi Genie — `client_generated_id` accepted but not honored on capture create

**From:** Isaac (iOS)
**Date:** 2026-05-26
**Re:** Re-opens `hey_isaac/2026-05-25_client-generated-capture-id-implemented.md`
**Status:** Blocking Phase 3 cutover on iOS (PR #77).

---

## What broke

iOS shipped Phase 3 (PR #77) — the cutover that generates a UUIDv7 locally for each capture session and sends it as `client_generated_id` in `POST /api/projects/:project_id/captures`. Every uploaded artifact then references that local id.

On device test against the live workspace this morning, **every audio upload immediately after a successful create returned 404**:

```
[info] capture.create.ok                              ← server returned 201
[info] upload.attempt.start upload_id=F8DB1F15… attempt=1
[error] app.request.http_error url=…/api/captures/019e6777-605d-7351-b586-681dda9c56ab/audio
        http_status=404 code=validation_error
        detail=No active capture session '019e6777-605d-7351-b586-681dda9c56ab' was found.
[warning] upload.attempt.failed_transient … retry_in_s=2.0
```

After 5 retries (the upload coordinator's max-attempt budget) the upload parks as terminal-failed. We get a recording the user thinks succeeded that the server has no audio for.

## Root cause

`lakeloom-ai/server/routes/captures/capture-routes.ts` lines 70–110:

```typescript
app.post('/api/projects/:project_id/captures', iosOnly, async (req, res, next) => {
  try {
    const parsed = CreateCaptureBody.safeParse(req.body);
    ...
    const { label, client_ts, device_id } = parsed.data;  // ← client_generated_id NOT destructured
    ...
    const { rows } = await lakebase.query(
      `INSERT INTO app.capture_sessions
         (project_id, created_by_user_id, created_by_paired_session_id, device_label, label, started_at, device_id)
       VALUES ($1, $2, $3, $4, $5, $6, $7::uuid)
       RETURNING id, project_id, state, label, started_at`,
      [projectId, userId, pairedSessionId, deviceLabel, label ?? null, startedAt, device_id ?? null],
    );
    ...
```

The Zod schema (`CreateCaptureBody`) accepts `client_generated_id: z.string().uuid().optional()`, so the iOS request validates fine. But the destructure on line 77 drops `client_generated_id` on the floor, and the INSERT doesn't reference the column at all — the row's `id` falls back to whatever default the column has (server-generated). Migration 018 added the column, but the handler change to populate it never landed.

The response (`res.status(201).json({ id: capture.id, … })`) returns the **server-generated** id, not the one iOS sent. iOS doesn't read that field today (Phase 3 design assumes Option A: row id == client_generated_id), so every subsequent upload / PATCH against `client_generated_id` 404s.

## Suggested fix

Three things to change in the handler:

1. **Destructure `client_generated_id`** from `parsed.data`.
2. **Branch on idempotency**: if a `client_generated_id` is supplied, first check `SELECT id FROM app.capture_sessions WHERE created_by_user_id = $1 AND client_generated_id = $2`. If a row exists, return it with **HTTP 200** (idempotent re-submit — matches the contract from your 2026-05-25 reply).
3. **INSERT with the supplied id**: when `client_generated_id` is present, use it as both `id` AND `client_generated_id` in the new row. When absent, fall through to the existing server-id-generation path.

Pseudo-shape:

```typescript
const { label, client_ts, device_id, client_generated_id } = parsed.data;
...
// Idempotency check
if (client_generated_id) {
  const { rows: existing } = await lakebase.query(
    `SELECT id, project_id, state, label, started_at
     FROM app.capture_sessions
     WHERE created_by_user_id = $1 AND client_generated_id = $2`,
    [userId, client_generated_id],
  );
  if (existing.length > 0) {
    const c = existing[0];
    return res.status(200).json({
      id: c.id,
      project_id: c.project_id,
      state: c.state,
      label: c.label,
      started_at: c.started_at,
    });
  }
}

// Create with supplied id (Option A) or server-generated id
const insertColumns = client_generated_id
  ? `(id, client_generated_id, project_id, created_by_user_id, created_by_paired_session_id, device_label, label, started_at, device_id)`
  : `(project_id, created_by_user_id, created_by_paired_session_id, device_label, label, started_at, device_id)`;
const insertValues = client_generated_id
  ? [client_generated_id, client_generated_id, projectId, userId, pairedSessionId, deviceLabel, label ?? null, startedAt, device_id ?? null]
  : [projectId, userId, pairedSessionId, deviceLabel, label ?? null, startedAt, device_id ?? null];
// ... etc
```

Or simpler — always include the columns and pass `null` when not supplied so PG falls back to the column default for `id`:

```sql
INSERT INTO app.capture_sessions
  (id, client_generated_id, project_id, created_by_user_id, ...)
VALUES (COALESCE($1, gen_random_uuid()), $1, $2, $3, ...)
```

Status code: **201 on first create, 200 on idempotent re-submit** (the contract from your 2026-05-25 reply).

## How to verify

Once deployed, the iOS flow on PR #77 should:
- Issue `POST /api/projects/:project_id/captures` with `client_generated_id` in body.
- Receive **201** with `id == client_generated_id`.
- Immediately POST audio to `/api/captures/<that-same-id>/audio` → **204** (or whatever the success status is).
- No 404s in iOS logs.

OTel should also stop reporting `column "id" does not exist on … capture_sessions` if there's a corresponding "id was null on insert" error path that's currently silently being papered over by the default UUID generator.

## Out of scope for this fix

- `client_generated_id` validation on the upload-side endpoints isn't needed — the upload looks up by the row's `id`, so as long as the create populates `id` correctly from `client_generated_id`, the upload finds it.
- Same handler logic should apply to `POST /api/v1/projects` for the offline-project-create flow when we get there.

Holler when this is live and I'll re-run the offline-record device tests.
