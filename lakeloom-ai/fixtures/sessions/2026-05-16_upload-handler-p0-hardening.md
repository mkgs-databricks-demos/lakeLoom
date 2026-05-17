# Upload Handler P0 Hardening

**Date:** 2026-05-16  
**Status:** In progress

## Problem

Audio uploads were getting past Layer 2 auth and then failing in the upload handler with generic 500 responses. We had already confirmed the canonical multipart signature flow was correct, so the remaining gap was P0 hardening inside the upload route itself:

* enforce UNIX-seconds handling for `client_ts`
* normalize every persisted `client_ts` to a TIMESTAMPTZ-safe ISO value
* stop leaking generic thrown `Error` paths into the global fallback handler
* add richer upload diagnostics for Isaac and for dev OpenTelemetry review

## Root causes addressed

* `getVolumePath()` threw a plain `Error` when env vars were missing, which bypassed structured upload-specific problem details.
* multipart parsing still had generic failure branches (`No file data received`) that could surface as opaque 500s depending on where they were caught.
* metadata persistence relied on implicit timestamp casting rather than an explicit `::timestamptz` insert.
* diagnostics were present but inconsistent; failure payloads did not always include enough upload context to quickly correlate with Isaac's timestamps and capture IDs.

## Changes made

### `server/routes/uploads/upload-routes.ts`

* wrapped missing volume configuration in structured `AppError`
* hardened `normalizeClientTimestamp()`:
  * requires at least 10 leading digits
  * accepts longer UNIX-second strings by using the first 10 digits
  * falls back to server time for invalid/missing inputs
  * verifies the resulting ISO timestamp is parseable
* added upload-context helpers so logs and error responses consistently include:
  * `upload_id`
  * `upload_kind`
  * `project_id`
  * `capture_session_id`
  * `paired_session_id`
  * `user_id`
  * MIME, size, provided and normalized timestamps, fallback reason, path, SHA
* converted multipart parse failures into structured `AppError` responses:
  * multipart required
  * parse failed
  * missing file
  * missing MIME
  * stream read failure
* wrapped volume upload failures and metadata insert failures as structured problem-details errors with upload context
* made the `app.uploads` insert explicit with `$12::timestamptz`
* returned `client_ts_source` in the success payload for faster client-side diagnostics

### Tests

### `tests/server/upload-routes.test.ts`

* kept valid UNIX-seconds case
* added coverage for longer timestamp strings with a fractional suffix by truncating to the first 10 digits
* added coverage for fewer-than-10-digit timestamps falling back to server time

## Current validation status

* File edits completed.
* Unit test execution from the current notebook-side shell is blocked because `npx` is not available on this serverless environment (`bash: npx: command not found`).
* Next required validation steps remain:
  * run project tests in an environment with Node tooling
  * commit/push on the active feature branch
  * bundle validate/deploy to `dev`
  * redeploy the app with the Python SDK
  * rerun endpoint checks
  * query dev OpenTelemetry tables for upload traces/logs/errors

## Files modified

* `server/routes/uploads/upload-routes.ts`
* `tests/server/upload-routes.test.ts`
