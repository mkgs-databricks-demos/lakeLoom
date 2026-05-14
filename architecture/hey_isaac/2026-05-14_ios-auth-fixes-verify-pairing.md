# iOS Auth Fixes — Please Verify Pairing on Device

**Date:** 2026-05-14 ~21:00 UTC
**From:** Genie
**To:** Isaac

---

## Summary

We found and fixed **three bugs** in `server/middleware/ios-auth.ts` that collectively prevented iOS pairing from ever completing. The app has been redeployed and all 10 post-deploy tests pass (including a new end-to-end pairing simulation from the notebook). Please verify on a physical device.

## Bugs Fixed

### 1. Token hash mismatch (critical — broke ALL pairing)

`generateSessionToken()` stores `sha256(raw_32_bytes)` in the DB, but `iosAuth` was hashing the base64url *string* representation. Token lookup NEVER matched — every iOS request got `token_not_found`.

**Fix:** `sha256(Buffer.from(sessionToken, 'base64url'))`

### 2. Empty body hash for GET/DELETE requests

The canonical-form spec says empty body = `sha256('')` = `e3b0c442...`. Server was using literal empty string `''`. Fixed to use constant `EMPTY_BODY_HASH`.

### 3. Express `req.body = {}` on GET requests

Express json() middleware sets `req.body = {}` even for GET/DELETE. `{}` is truthy in JS, so the old check computed `sha256('{}')` instead of `EMPTY_BODY_HASH`. Fixed with `Object.keys(req.body).length > 0` check.

## What You Need to Verify

1. **Scan QR code from the app** — pairing should now complete (200 from `/api/pairing/confirm`)
2. **After pairing, make any authenticated request** (list captures, create capture) — should get 200, not 401
3. **Confirm the public key format** — server expects SPKI DER (91 bytes, starts `0x30`), matching iOS CryptoKit `.derRepresentation`. NOT raw X9.62 uncompressed point (65 bytes, starts `0x04`).

## Key Contract Reminder

**Public key:** SPKI DER (91 bytes) = `privateKey.publicKey.derRepresentation`

**Canonical message:** `<METHOD>\n<PATH>\n<UNIX_SECONDS>\n<BODY_SHA256_HEX>`
- Empty body: `sha256('')` = `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
- Body present: `sha256(compact_json_bytes)`

**Body serialization:** No extra whitespace (JSONEncoder default matches JS `JSON.stringify`)

## IP Access List

If you get **403** (not 401): phone IP must be in workspace ALLOW list. Current: `98.10.37.0/24` (label: `lakeLoomZeroBus`). Propagation: up to 10 min. iOS logs public IP as `signin.public_ip`.

## Test Evidence

All 10 tests pass including new Test 10 (full E2E pairing simulation: QR -> confirm -> authenticated GET with ECDSA).

---

Let me know how the device test goes. If issues arise, grab the full error response body — the `type` field identifies which verification step failed.


---

## UPDATE: 403 Still Occurring — IP Egress Mismatch (not auth)

The 403 is NOT an auth or permissions issue. All server-side checks pass:
- Xcode SPN: active, CAN_USE on App ✓
- Token: acquired successfully from workspace OIDC ✓
- Notebook test (same SPN, same token, same App): all 10 tests pass ✓

**Root cause:** The phone's ACTUAL egress IP hitting `*.databricksapps.com` likely differs from the self-detected `98.10.37.99`. The workspace allowlist has `98.10.37.0/24` but the App sidecar sees a different source IP.

**Please check on the phone:**

1. Is **iCloud Private Relay** enabled? (Settings → Apple Account → iCloud → Private Relay)
   - If YES: disable it and retry. Private Relay routes traffic through Apple's relay network with a different IP.

2. Is the phone on **WiFi** (home network) or **cellular**?
   - Cellular carrier NAT will use a completely different IP range.

3. Open Safari on the phone and visit `https://api.ipify.org` — what IP does it show?
   - Compare with the `signin.public_ip=98.10.37.99` from the Xcode logs.
   - If they differ, that's the problem.

4. If the Safari IP differs from `98.10.37.99`, share that IP and I'll add it to the allowlist.

**Why OIDC works but App doesn't:** The workspace OIDC endpoint and the App sidecar may be behind different infrastructure (different AWS edge/region). The phone's IP routing may present different source IPs to each destination.
