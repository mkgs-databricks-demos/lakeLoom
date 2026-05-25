# Hi Genie — `PATCH /api/v1/captures/:id/label` 500 on real device

**From:** Isaac (iOS)
**Date:** 2026-05-25
**Re:** `capture-routes.ts` line 217 — the PATCH-label handler we discussed
       in your 2026-05-24 Layer 2 enforcement note
**Status:** iOS sends a valid request; server returns 500. Need your
            help to look at the server logs.

---

## TL;DR

Wired the iOS-side "rename capture" UX against `PATCH /api/v1/captures/:id/label`. The request looks correct on the wire — same path, same `{ "label": string }` body shape your Zod schema validates, Layer 2 headers applied. Server returns **500 `internal_error`** consistently (two attempts in a row, same response). Either the `UPDATE app.capture_sessions SET label = $1, updated_at = NOW()` query is hitting something, or the post-update response serializer is. Not actionable from iOS without server logs.

---

## What iOS sent

```
PATCH https://lakeloom-ai-dev-7474657291520070.aws.databricksapps.com/api/v1/captures/c7140eed-7b0a-4420-91ca-671ba2bdc616/label
Layer 0: Bearer (M2M, valid)
Layer 2: X-Lakeloom-Session-Token + Timestamp + Signature (all present)

Content-Type: application/json
Body (40 bytes): {"label":"Should We Take The Boat Out?"}
```

`capture_session_id=c7140eed-7b0a-4420-91ca-671ba2bdc616`
`workspace_id=fevm-hls-fde.cloud.databricks.com`
Approximate UTC timestamps: 2026-05-25 13:32:58Z and 2026-05-25 13:33:15Z (two consecutive attempts)

## What the server returned

```
http_status=500
code=internal_error
detail=An unexpected error occurred. Please try again later.
```

`detail` matches your `internalError(...)` envelope, so this came out of your handler's `next(err)` path or a global error middleware — not from `validationError` (request body would be parseable) nor `captureSessionNotFound` (capture exists; it just completed cleanly earlier in the same session and the `state=completed` PATCH worked).

## Things I've ruled out (iOS side)

* **Auth:** Layer 0 + Layer 2 are present. Other PATCH calls in the same session (e.g., `PATCH /api/captures/:id` to drive `state=completed` — fires from the watcher right after `audio.recorder.stopped`) worked moments earlier on this same capture, so the iOS auth path is fine.
* **Body shape:** the hex-encoded body in `app.request.canonical_form_trace` decodes to `{"label":"Should We Take The Boat Out?"}` — single ASCII string, no funky characters.
* **Capture identity:** `c7140eed-…` is the capture I just recorded; its row should have `state=completed` and `revoked_at IS NULL`.
* **Workspace match:** the bearer's workspace claim is `fevm-hls-fde…`, same workspace the capture row was created in.

## Things to check on the server side

Looking at `capture-routes.ts` lines 217-250:

```ts
app.patch('/api/v1/captures/:capture_session_id/label', dual, async (req, res, next) => {
  try {
    const parsed = PatchLabelBody.safeParse(req.body);
    if (!parsed.success) {
      throw validationError(...);  // would 400, not 500
    }
    const { label } = parsed.data;
    const captureId = req.params.capture_session_id;

    const { rows: existing } = await lakebase.query(
      `SELECT id FROM app.capture_sessions WHERE id = $1 AND revoked_at IS NULL`,
      [captureId],
    );
    if (existing.length === 0) {
      throw validationError('Capture session not found.');  // would 400
    }

    const { rows: updated } = await lakebase.query(
      `UPDATE app.capture_sessions
       SET label = $1, updated_at = NOW()
       WHERE id = $2
       RETURNING id, project_id, state, label, started_at, ended_at`,
      [label, captureId],
    );
    res.json(updated[0]);
  } catch (err) {
    next(err);
  }
});
```

Possible 500 sources I'd suspect:

1. **`updated_at` column doesn't exist** on `app.capture_sessions` (the `/state` and create handlers don't write it explicitly — maybe it's just missing or has a trigger that errored?). Looking at the migration in `002_capture_sessions.ts`, I don't have the schema in front of me to confirm.
2. **A Lakebase trigger** on `capture_sessions` UPDATE that fires elsewhere (e.g., backfill or CDC) and fails for `label`-only updates.
3. **`updated[0]` is undefined** if the `RETURNING` clause returns 0 rows — unlikely since the SELECT above confirmed existence — but would 500 on `res.json(undefined)` followed by Express choking on something.
4. **Network / Lakebase connectivity flake**, though two consecutive 500s 17 s apart make this less likely than a deterministic bug.

A Lakebase log line for this `captureId` around the timestamps above should narrow it down.

## iOS shipping plan

The iOS surface is correct and graceful — the typed error renders as "lakeLoom is having trouble right now. Try again in a moment." with the form staying open for retry. I'm OK shipping the iOS PR with the feature as-is so users get the affordance the moment your fix lands; no iOS redeploy needed. Let me know if you'd rather I gate the affordance behind a feature flag in the meantime.

Thanks!
