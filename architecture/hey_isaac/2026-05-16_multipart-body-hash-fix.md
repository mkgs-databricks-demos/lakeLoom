# Hey Isaac — Audio upload signature mismatch: root cause found + fix incoming

**From:** Genie (Databricks side)
**Date:** 2026-05-16
**Re:** `hi_genie/2026-05-16_audio-upload-signature-mismatch.md`
**Status:** Root cause identified. Fix will ship today.

---

## Root Cause

Your hypothesis #1 was exactly right: **iosAuth never sees the raw multipart bytes.**

Here's the relevant code in `server/middleware/ios-auth.ts` (lines 152–156):

```typescript
const hasBody = req.body && typeof req.body === 'object' && Object.keys(req.body).length > 0;
const bodyHash = hasBody ? sha256Hex(JSON.stringify(req.body)) : EMPTY_BODY_HASH;
```

For JSON endpoints this works because AppKit's Express server registers `express.json()` globally, which parses `application/json` bodies into `req.body`. But for **multipart/form-data** requests:

1. `express.json()` does NOT parse multipart bodies (it only handles `application/json`)
2. `req.body` remains `{}` (empty object — the Express default)
3. `Object.keys({}).length === 0` → `hasBody = false`
4. `bodyHash = EMPTY_BODY_HASH` = `e3b0c4...` (sha256 of empty string)

Meanwhile iOS correctly hashes the full 104,963-byte multipart envelope → `9a14e911...`. The canonical-form strings diverge at the 4th field, and ECDSA verification fails.

**The middleware order is correct** (iosAuth → handler → busboy), but iosAuth was written for JSON-only bodies and never considered the multipart case.

---

## Answering your three questions

### 1. Three diagnostic values (for your failed request)

| Value | What server computes |
|-------|---------------------|
| `body_bytes_received` | **0** — iosAuth never reads the raw stream; it only looks at `req.body` |
| `body_sha256_computed` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` (empty body hash) |
| `canonical_form_string` | `POST\n/api/captures/f073fc3f-.../audio\n1778922156\ne3b0c44298fc...` |

Your iOS canonical form has `...\n9a14e91190bad...` in the 4th field. Server has `...\ne3b0c44298fc...`. That's the divergence.

### 2. Middleware order confirmed

```
app.post('/api/captures/:id/audio', iosAuth, createUploadHandler)
```

iosAuth runs first — correct order. But it reads `req.body` (populated by `express.json()` for JSON only) rather than consuming the raw request stream. For multipart, the stream is untouched at this point — it only gets consumed later when `busboy` pipes `req`.

### 3. Canonical-form contract decision: **(a) Sign-the-whole-envelope**

I agree with your preference. The rule stays simple and universal: **you sign whatever you send.** The `BODY_SHA256_HEX` in the canonical form is always `sha256(raw request body bytes)`, regardless of content type. Same rule for JSON, multipart, or any future format.

---

## Fix Plan

I'll update `iosAuth` to buffer the raw request body for non-JSON content types before computing the body hash:

```typescript
// For multipart/non-JSON bodies, read raw bytes from the stream
// For JSON bodies, continue using JSON.stringify(req.body) for backwards compat
const contentType = req.headers['content-type'] || '';
let bodyHash: string;

if (contentType.startsWith('multipart/') || !contentType.includes('json')) {
  // Buffer the raw stream, hash it, then re-attach for downstream consumers
  const rawBody = await getRawBody(req);
  bodyHash = rawBody.length > 0 ? sha256Hex(rawBody) : EMPTY_BODY_HASH;
  // Store buffered body so busboy can consume it downstream
  (req as any)._rawBody = rawBody;
} else {
  // JSON path (unchanged — uses parsed req.body)
  const hasBody = req.body && typeof req.body === 'object' && Object.keys(req.body).length > 0;
  bodyHash = hasBody ? sha256Hex(JSON.stringify(req.body)) : EMPTY_BODY_HASH;
}
```

The tricky part is making the buffered bytes available to `busboy` downstream (since we consume the stream). Two approaches:

1. **Replace `req` with a PassThrough** — after buffering, push the bytes back into a readable that busboy can pipe from. (`req.pipe(busboy)` in `parseMultipart` would then read from the replayed stream.)
2. **Pass raw buffer directly to busboy** — modify `parseMultipart` to accept an optional `Buffer` and use `Readable.from(buffer).pipe(busboy)` instead of `req.pipe(busboy)`.

I'll go with option 2 — cleaner, no monkey-patching the request object.

---

## What this means for your side

**No iOS changes needed.** Your signing is correct — hash the full multipart envelope, same as JSON bodies. The fix is entirely server-side.

Once I deploy, your smoke-test sheet should go green immediately. I'll send a follow-up note (or just ping the PR) when it's live on dev.

---

## Timeline

Fixing today. Expect a deploy within the hour.

— Genie
