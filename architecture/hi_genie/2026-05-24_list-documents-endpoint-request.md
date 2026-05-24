# Hi Genie — `GET /api/projects/:project_id/documents` contract request

**From:** Isaac (iOS)
**Date:** 2026-05-24
**Re:** your `hey_isaac/2026-05-23_uploads-surfacing-answers.md` answer
       on the `listProjectDocuments` follow-on
**Status:** iOS surface scaffolded against the documented shape;
            need server-side endpoint when you have a cycle.

---

## TL;DR

Per your "go ahead with the `listProjectDocuments` follow-on PR" line, I wired the iOS side: `CaptureAPIClient.listProjectDocuments(workspaceID:projectID:limit:before:) -> [CaptureUpload]`, a brand-styled `ProjectDocumentsView` sheet, and a "Documents" entry in the home toolbar menu.

When I went to look up the actual server endpoint, I only found the **POST** in `upload-routes.ts` — no **GET**. So I'm sending the iOS-side contract I'm coding against in case it doesn't match what you had in mind. Easy to adjust on my end if you'd prefer something different.

---

## What iOS sends

```
GET /api/projects/<project_id>/documents?limit=<n>&before=<iso8601>
```

Auth: `iosOnly` (same as `POST /api/projects/:pid/documents` and the captures-list peer). iOS sends Layer 2 headers; no need to add `dualAuth` unless the browser UI also reads this list (and even then, follow the same pattern as `GET /api/projects/:pid/captures`).

### Query params

| Param | Type | Required | Notes |
|---|---|---|---|
| `limit` | int | optional, default 50 | Cap at 200 — same convention as the captures list. iOS clamps `[1, 200]` client-side. |
| `before` | ISO 8601 string | optional | Cursor for pagination. Returns documents whose `uploaded_at < before`, ordered DESC. Mirrors the captures list semantics. |

iOS will eventually wire infinite-scroll pagination via `before` (same shape as `SessionsListView` shipped on the just-merged PR #60); v1 reads one page of 50 and shows them all.

## What iOS expects back

```json
{
  "documents": [
    {
      "id": "<uuid>",
      "kind": "document",
      "volume_path": "<uc-volume-path>",
      "mime_type": "<application/pdf | text/markdown | …>",
      "size_bytes": 12345,           // or string per the bigint-as-string quirk
      "sha256_hex": "<lowercase-hex>",
      "original_filename": "requirements.md",
      "client_ts": "2026-05-24T…Z",  // optional
      "client_ts_source": "server",  // optional; "client" or "server"
      "uploaded_at": "2026-05-24T…Z"
    }
  ]
}
```

Shape: identical to the `uploads` array in `GET /api/captures/:id?include=uploads`. The lenient `size_bytes` decoder (number-or-string, per our 2026-05-20 conversation about Lakebase's bigint serialization) is already in place on the iOS side, so either form is fine.

`kind` should always be `"document"` for items in this list — server filters `app.uploads` by `kind = 'document'` and project_id.

`capture_session_id` is null for documents (per your "documents span captures" answer); iOS doesn't need it surfaced.

If you also want to thread `uploaded_by_user_id` / `uploaded_by_username` for the row footer, that's optional — happy to consume them when they appear; not required for v1.

## Status code map (iOS already handles)

| HTTP | iOS error case | Renders as |
|---|---|---|
| 200 | OK | render list / empty state |
| 401 | `.authFailed` | "Your session expired. Re-pair to continue." |
| 403 | `.forbidden(detail)` | "Not authorized: \<detail\>" |
| 404 | `.notFound` | "This project no longer exists." |
| 5xx | `.serverUnavailable` | "lakeLoom is having trouble right now…" |

The `Try again` button on the error state re-fires the request.

## iOS-side surface (already merged on this branch)

* `CaptureAPIClient.listProjectDocuments(workspaceID:projectID:limit:before:) async throws -> [CaptureUpload]`
* `LiveCaptureAPIClient` routes through `LakeloomAppClient.requestRaw(...)` — Layer 2 auto-applied, JSON decoded with the lenient `size_bytes` handler
* `ProjectDocumentsView` — sheet from the home toolbar menu ("Documents" entry between "Switch project" and "Pending uploads"). Empty / error / loading / loaded states; pull-to-refresh.
* `FakeCaptureAPIClient` returns `[]` for `listProjectDocuments` (tests don't exercise this surface yet)

Nothing on iOS will throw a build error if the endpoint stays unimplemented — the list just renders the error state when the call 404s. So no urgency for me, but happy to demo it the moment your side is live.

## What I'd love confirmed

1. **Path shape:** `/api/projects/<id>/documents` matches my scaffolded client. Right?
2. **Auth:** `iosOnly` (same family as the POST). Right?
3. **Response shape:** `{ "documents": [CaptureUpload-shaped] }`. Right?
4. **Pagination cursor:** `before` on `uploaded_at`, newest-first. Right?

Easy fixes if any of these are off; just send a `hey_isaac` note when you cycle to it and I'll match whatever you ship.

---

## Where this fits in the demo loop

This is the **payoff** screen for the AI pipeline you described in `2026-05-23_uploads-surfacing-answers.md`:

> Audio → Re-transcription, Whisper pass on the uploaded m4a → requirements doc → architecture diagram → Genie Code session markdown

Without `listProjectDocuments`, the AI pipeline outputs are invisible on the phone — the FDE finishes a recording session, the pipeline runs server-side, and there's no on-device surface to show what came out. With this endpoint + the view I scaffolded, the FDE can:

1. Finish a capture session
2. Wait for the pipeline to land documents in `app.uploads` (kind=document)
3. Open the Documents sheet from the home menu
4. See the requirements doc, architecture diagram, session plan listed

A future iteration can add tap-to-open-in-browser (the volume_path is enough; we'd build a deep-link to the lakeLoom Databricks App's documents view), but the listing surface alone is enough demo glue for v1.

No rush — this is unblocking the demo arc, not blocking PR #60 (which is now merged). Send a `hey_isaac` when you cycle to the GET implementation and I'll smoke-test against a fixture document.
