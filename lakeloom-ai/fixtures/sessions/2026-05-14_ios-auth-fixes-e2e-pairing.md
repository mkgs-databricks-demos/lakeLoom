# 2026-05-14 — iOS Auth Bug Fixes & E2E Pairing Validation

**Date:** 2026-05-14 20:00–21:00 UTC
**Scope:** Critical auth bugs in ios-auth.ts, IP access list documentation, E2E test

---

## Problems Addressed

1. iOS pairing always failed with `token_not_found` — token hash mismatch
2. Authenticated GET/DELETE requests failed with `invalid_signature` — empty body hash
3. Express `req.body = {}` truthy check caused wrong body hash on GET/DELETE
4. Phone got 403 from App sidecar after IP access list modification (transient)
5. No end-to-end pairing test existed — previous tests only validated sidecar pass-through

## Root Causes

1. `generateSessionToken()` stores `sha256(raw_bytes)` but `iosAuth` hashed the base64url string
2. Empty body used `''` instead of `sha256('')` per canonical-form spec
3. Express json() middleware sets `req.body = {}` on all requests; `{}` is truthy in JS
4. Workspace IP access list propagation takes up to 10 minutes (transient)
5. Test 4 accepted 401 as "passing" without distinguishing which Layer 2 check failed

## Changes Made

### `server/middleware/ios-auth.ts` (3 fixes)
- Token lookup: `sha256(sessionToken)` → `sha256(Buffer.from(sessionToken, 'base64url'))`
- Added `EMPTY_BODY_HASH` constant (`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`)
- Body detection: `req.body ?` → `Object.keys(req.body).length > 0`

### `src/tests/pairing-api-test` (notebook)
- Added Test 10: Full E2E pairing simulation (QR → keygen → confirm → authenticated GET)
- Updated CI/CD gate: `expected_tests` expanded to 10 items
- Test uses SPKI DER format (91 bytes) matching iOS CryptoKit `.derRepresentation`

### `README.md`
- Added "Workspace IP Access Lists" section with CLI commands (list/create/update)
- Includes CIDR reference table, propagation timing, iOS 403 troubleshooting

### `architecture/hey_isaac/2026-05-14_ios-auth-fixes-verify-pairing.md`
- Notified Isaac: 3 bugs fixed, verification instructions, public key format contract

## Decisions

- **SPKI DER is the public key format contract** — server uses `createPublicKey({ format: 'der', type: 'spki' })`. iOS must send `.derRepresentation` (not raw X9.62 point).
- **Empty body = sha256 of empty bytes** — follows AWS SigV4 convention. Constant avoids recomputation.
- **Object.keys check for body presence** — Express json() sets `{}` on all verbs; truthiness alone is unreliable.
- **IP access list in README** — operational knowledge that's needed by anyone running the phone.

## Validation

- `bundle validate --strict --target dev` ✓
- App deployed 3 times during session (incremental bug fixes)
- Full test suite: 10/10 PASS
- Test 10 confirms complete auth chain: sidecar → token lookup → ECDSA → handler

## Files Modified

| File | Type |
|------|------|
| `server/middleware/ios-auth.ts` | Modified (3 bug fixes) |
| `src/tests/pairing-api-test` | Modified (notebook — Test 10 + CI gate) |
| `README.md` | Modified (IP access list section) |
| `architecture/hey_isaac/2026-05-14_ios-auth-fixes-verify-pairing.md` | New |
