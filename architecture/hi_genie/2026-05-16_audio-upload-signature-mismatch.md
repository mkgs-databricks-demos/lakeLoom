# Hi Genie — audio upload signature failing iosAuth verification

**From:** Isaac (iOS side)
**Date:** 2026-05-16
**Status:** Blocking PR 5 work. iOS-side traces added; need server-side hash comparison.

---

## Symptom

Every single capture-lifecycle endpoint exercises cleanly against dev — `POST /api/projects/:id/captures`, `GET /api/projects/:id/captures`, `GET /api/captures/:id`, `PATCH /api/captures/:id` all 200 OK with valid signatures.

The moment we move to the **audio multipart upload** (`POST /api/captures/:id/audio`), the server rejects every request with:

```
401 The request signature could not be verified against the bound device key.
```

…even though the same paired session, same Xcode SPN M2M token, and same `RequestSigner` is producing those signatures.

Two clean iOS-side runs from a fresh pair:

```
[info] capture.create.ok
[info] audio.recorder.started capture_session_id=16a19199-…
[info] audio.recorder.stopped duration_s=9.391 bytes=132336
[info] upload.queue.enqueued upload_id=E743A508… kind=audio
[info] upload.attempt.start upload_id=E743A508… attempt=1
[warning] app.request.unauthorized path=/api/captures/16a19199-…/audio kind=unknown detail=The request signature could not be verified against the bound device key.

[info] capture.create.ok
[info] audio.recorder.started capture_session_id=e24b9116-…
[info] audio.recorder.stopped duration_s=5.650 bytes=101959
[info] upload.queue.enqueued upload_id=E1986A63…
[info] upload.attempt.start upload_id=E1986A63… attempt=1
[warning] app.request.unauthorized path=/api/captures/e24b9116-…/audio kind=unknown detail=…
```

---

## What iOS is doing on the upload path

For each upload, the iOS side:

1. Builds a `multipart/form-data` body in memory containing four parts:
   - `client_ts` (unix-seconds string)
   - `client_filename` (e.g., `audio-20260516T085419.m4a`)
   - `sha256_hex` (lowercase hex SHA-256 of the audio file bytes)
   - `file` (raw M4A/AAC bytes)
2. Sets `Content-Type: multipart/form-data; boundary=<boundary>` on the request.
3. Sets `httpBody = <multipart body bytes>`.
4. Calls `RequestSigner.sign(method:, pathAndQuery:, body:)` to produce:
   - `X-Lakeloom-Timestamp` (unix seconds)
   - `X-Lakeloom-Signature` (ECDSA over `METHOD\nPATH\nUNIX_SECONDS\nBODY_SHA256_HEX`)
5. `RequestSigner.bodyHash(for: body)` is `SHA-256.hex(body)` — same code path that works for the JSON endpoints.

In `LakeloomAppClient.requestRaw`, the same `Data` object that gets hashed is what `URLRequest.httpBody` is set to. No body modification happens between sign and send.

---

## Hypothesis space

Since every JSON-bodied endpoint (with non-empty bodies) signs and verifies fine, the contract works in principle. What's different for the multipart route:

1. **Server-side iosAuth doesn't hash the raw multipart bytes.** If iosAuth runs after `busboy` has parsed the body, the raw stream is gone. If it re-serializes the parsed body before hashing, the bytes won't match what iOS hashed.
2. **URLSession is re-encoding the body before sending.** Less likely — `httpBody` is documented to send verbatim — but possible with HTTP/2 chunking or unusual `Transfer-Encoding`. I don't have a way to introspect this without a proxy.
3. **A trailing-CRLF / boundary-format quirk in iOS's multipart builder.** My builder ends with `--<boundary>--\r\n` per RFC 2046. If the server normalizes the body bytes before hashing (e.g., strips trailing whitespace), the hashes would diverge.
4. **The `busboy` stream consumes the body before iosAuth's hash gate.** I assume your middleware order is `iosAuth → busboy`; if it's reversed, iosAuth never sees raw bytes for multipart.

---

## What I added on iOS side to debug

PR #30 includes a `#if DEBUG`-only diagnostic log (`app.request.canonical_form_trace`) that prints, for every request:

```
method           POST
path             /api/captures/<id>/audio
timestamp        1747408459
body_bytes       132548
body_sha256      <lowercase hex digest of the exact bytes URLRequest.httpBody is set to>
body_head_hex_64 <first 64 bytes>
body_tail_hex_64 <last 64 bytes>
```

So I can correlate that hash with whatever your server logs.

---

## What I'd like from you

1. **Log the expected hash on the server side** for failing requests — specifically, the `BODY_SHA256_HEX` value that iosAuth uses when it reconstructs the canonical form. If you can dump that alongside the iOS-supplied signature in your `ios-auth.ts` middleware (DEBUG flag, of course), we can compare directly.
2. **Confirm the middleware order** for the `/api/captures/:id/audio` route. Specifically, does iosAuth run before `busboy`, and does it have access to the raw request bytes (e.g., via `raw-body` or a similar buffering primitive) before they're consumed by the multipart parser?
3. **Confirm the canonical-form bytes for multipart.** For JSON endpoints, the body is the JSON string bytes (utf-8). For multipart endpoints, is the expectation that the body is the **entire multipart envelope** (including boundary markers, part headers, file bytes, and closing boundary), or just the file portion?

If it turns out to be a middleware-order / raw-body issue, the fix on your side might be as simple as wiring `raw-body` (or a small custom buffer middleware) before iosAuth so the raw bytes are available, and then handing those buffered bytes to `busboy`.

If you'd prefer to flip the contract to sign over only the file bytes (or some normalized canonical multipart representation), let me know — I'd rather not, since the current "sign whatever you send" rule is simpler, but I can adapt.

---

## Next steps for me

Holding PR 5 (camera/screen capture) until upload works. The smoke-test UI (PR #30, merged) makes this reproducible in ~10 seconds: pair → tap **Create** → tap **Start recording audio** → tap **Stop + upload audio**. The diagnostic log appears in Xcode's console just before the upload attempt.

— Isaac
