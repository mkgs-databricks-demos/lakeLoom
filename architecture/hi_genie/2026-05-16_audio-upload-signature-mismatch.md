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

## Concrete iOS-side numbers (2026-05-16 run)

PR #30 includes a `#if DEBUG`-only diagnostic log (`app.request.canonical_form_trace`) that prints, for every request, the inputs to canonical-form signing. Here's a clean run against dev:

**Working JSON endpoints (all 200 OK):**

| Endpoint | body_bytes | body_sha256 |
|---|---|---|
| `POST /api/projects/<proj>/captures` | 66 | `82c765664583e9cbb6019758f201398084ac555f55513c7785569176d70cc032` |
| `GET /api/projects/<proj>/captures?limit=20` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `GET /api/captures/<cap>/?include=uploads` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `PATCH /api/captures/<cap>` (state=cancelled) | 55 | `e2ee8d7583f224f41ae659a5c051033abea02e0d104bbd506e3b2cd60694bf22` |

The empty-body hash is `sha256(b'')` — matches the canonical-form spec you locked in your 2026-05-13 message.

**Failing multipart upload (401 unauthorized):**

```
method:      POST
path:        /api/captures/f073fc3f-1042-4758-b805-370e792c379a/audio
timestamp:   1778922156
body_bytes:  104963
body_sha256: 9a14e91190bad2ecf793aa72cffaa4a3fefffdb7852e40a6d8c0cd1379d5fb9e
body_head:   2d2d6c616b656c6f6f6d2e43434632353931342d464333342d343439372d424131302d3638444338463338363936360d0a436f6e74656e742d446973706f7369
             → "--lakeloom.CCF25914-FC34-4497-BA10-68DC8F386966\r\nContent-Disposi"
body_tail:   da90d8b326782d48ee56870d0a2d2d6c616b656c6f6f6d2e43434632353931342d464333342d343439372d424131302d3638444338463338363936362d2d0d0a
             → "…\r\n--lakeloom.CCF25914-FC34-4497-BA10-68DC8F386966--\r\n"
```

The multipart body is RFC 2046-correct: starts with `--<boundary>\r\nContent-Disposition…`, ends with `--<boundary>--\r\n`. The hash matches what `URLRequest.httpBody` is set to byte-for-byte. **The iOS half is consistent with the contract you locked.**

The recording itself is 104336 bytes (from `audio.recorder.stopped`); the multipart envelope adds 627 bytes of boundary markers + Content-Disposition headers + the optional metadata fields (`client_ts`, `client_filename`, `sha256_hex`).

---

## What I'd like from you

For the specific failed request above (or any one of them — they're trivially reproducible from the smoke-test sheet in PR #30):

1. **Dump these three values from your iosAuth middleware** when verification fails on a multipart route:
   - `body_bytes_received` — the byte count your middleware sees on the wire (before busboy)
   - `body_sha256_computed` — the digest your middleware feeds into the canonical-form reconstruction
   - `canonical_form_string` — the literal `METHOD\nPATH\nUNIX_SECONDS\nBODY_SHA256_HEX` you build before ECDSA-verify
   
   With those three numbers I can pinpoint the divergence in seconds:
   - If `body_bytes_received` ≠ 104963 → server is reading from a parsed/transformed source, not the raw stream
   - If bytes match but `body_sha256_computed` ≠ `9a14e911…` → something between the wire and your hasher is mutating bytes (TLS layer, framework normalization, etc.)
   - If both match but the `canonical_form_string` differs → path/timestamp/method normalization mismatch
   
2. **Confirm middleware order** on `/api/captures/:capture_session_id/audio`. Is iosAuth registered before `busboy`, and is it backed by `raw-body` (or equivalent) so it can read+buffer the stream once, hash it, AND hand those buffered bytes to busboy downstream? If iosAuth runs *after* busboy, the raw stream is consumed and the only way for iosAuth to compute a body hash is to re-serialize the parsed multipart — which won't byte-for-byte match what we sent.

3. **Lock the multipart canonical-form contract.** Two options on the table:
   - **(a) Sign-the-whole-envelope** — what we're doing today. iOS hashes the full multipart body bytes (boundary markers + part headers + parts + closing boundary). Server reads the same raw bytes and hashes them. Requires the raw-body buffering above.
   - **(b) Sign-the-file-only** — iOS hashes only the file part bytes. Server hashes only the file bytes after busboy parses them. Simpler server-side (no raw-body needed) but iOS has to compute *and* send the file hash for use in the canonical form. We already send `sha256_hex` as a multipart field for integrity; we could reuse that as the `BODY_SHA256_HEX` in the canonical form.

   I have a slight preference for **(a)** — same rule as JSON endpoints, "you sign whatever you send". But **(b)** is cleaner middleware-wise on your side. Either works; I just need to know which one is the contract.

---

## Next steps for me

Holding PR 5 (camera/screen capture) until upload works. The smoke-test UI (PR #30, merged) makes this reproducible in ~10 seconds: pair → tap **Create** → tap **Start recording audio** → tap **Stop + upload audio**. The diagnostic log appears in Xcode's console just before the upload attempt.

— Isaac
