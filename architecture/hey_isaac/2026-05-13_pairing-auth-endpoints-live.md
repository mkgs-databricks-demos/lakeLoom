# 2026-05-13 — Pairing Auth Endpoints Live & Validated

Hey Isaac,

The QR-pair auth system is deployed and validated end-to-end. Here's what you need for the iOS side:

## What's Working

1. **QR code rendering** — `/pairing` page shows a live QR that rotates every 30s
2. **Xcode SPN M2M token** — `client_credentials` grant works (3600s tokens)
3. **Auth sidecar accepts SPN** — No 302 redirect, requests reach the app
4. **`iosAuth` middleware** — Validates Layer 2 headers, returns proper errors
5. **Lakebase `paired_sessions`** — Table created, indexes in place, ready for pairing

## iOS Integration Contract

### Layer 1: Sidecar Authentication
```
POST <workspace_url>/oidc/v1/token
  grant_type=client_credentials
  client_id=<xcode_spn_client_id>     (from QR payload: xcode_spn.client_id)
  client_secret=<xcode_spn_secret>    (from QR payload: xcode_spn.client_secret)
  scope=all-apis

→ { access_token, token_type: "Bearer", expires_in: 3600 }
```

Every request to the app needs: `Authorization: Bearer <access_token>`

### Layer 2: Session + Signature (for iOS-auth endpoints)
```
X-Lakeloom-Session: <session_token>      (from QR payload: session.token)
X-Lakeloom-Timestamp: <ISO 8601>         (skew tolerance: 90s past, 30s future)
X-Lakeloom-Signature: <base64 ECDSA sig> (P-256, over canonical message)
```

**Canonical message format** (for ECDSA signing):
```
<HTTP method>
<path>
<timestamp>
<body_sha256_hex>
```
- `body_sha256_hex` = SHA-256 of the raw request body (empty string → hash of empty)

### POST /api/pairing/confirm (One-Shot Device Binding)

**Headers:** Bearer + Layer 2 headers (with `allowUnboundSession` — first call uses the session token from QR but no prior device binding exists yet)

**Body:**
```json
{
  "device_pubkey": "<base64-encoded P-256 public key (DER/SPKI)>",
  "device_label": "Matthew's iPhone 15 Pro"
}
```

**Response (200):**
```json
{
  "session_id": "<uuid>",
  "paired_at": "<ISO timestamp>",
  "expires_at": "<ISO timestamp>"
}
```

**Error responses (RFC 9457 problem details):**
- `401` — `token_not_found`: "The session token is invalid or has been revoked. Please re-pair."
- `401` — `token_expired`: "Session has expired. Please re-pair."
- `401` — `signature_invalid`: "Request signature verification failed."
- `409` — `already_bound`: "This session is already bound to a device."

### Verified Error Response Format
```json
{
  "type": "https://lakeloom/errors/token_not_found",
  "title": "Session not found",
  "status": 401,
  "detail": "The session token is invalid or has been revoked. Please re-pair."
}
```
Content-Type: `application/problem+json; charset=utf-8`

## QR Payload Structure (confirmed working)

The QR encodes a base64 JSON payload with:
```json
{
  "v": 1,
  "workspace": { "url": "...", "id": "...", "name": "...", "cloud": "aws" },
  "user": { "scim_id": "...", "user_name": "...", "display_name": "..." },
  "xcode_spn": { "client_id": "...", "client_secret": "..." },
  "session": { "token": "...", "expires_at": "..." },
  "app": { "base_url": "https://lakeloom-ai-dev-7474657291520070.aws.databricksapps.com" }
}
```

## iOS Flow Summary

1. User scans QR → extract payload
2. Store `xcode_spn` creds in Keychain
3. Generate Secure Enclave P-256 keypair
4. Acquire M2M token: `POST <workspace.url>/oidc/v1/token`
5. Call `POST <app.base_url>/api/pairing/confirm` with:
   - `Authorization: Bearer <m2m_token>`
   - `X-Lakeloom-Session: <session.token>`
   - `X-Lakeloom-Timestamp: <now>`
   - `X-Lakeloom-Signature: <sign(canonical_message)>`
   - Body: `{ device_pubkey: <SE pub key>, device_label: <device name> }`
6. On 200 → pairing complete, store `session_id` + `expires_at`
7. All subsequent requests use same Bearer + Session + Signature pattern

## What's NOT Ready Yet

- **Upload endpoints** (`/api/sessions/:id/audio`, `/api/sessions/:id/screenshots`, `/api/projects/:id/documents`) — implemented but untested, filename convention TBD
- **Event endpoint** (`/api/sessions/:id/events`) — implemented, forwards to ZeroBus

## Questions for You

1. **Device label format** — What should `device_label` look like? I'm expecting something like "Matthew's iPhone 15 Pro" or the `UIDevice.name` value.
2. **Public key encoding** — I'm expecting base64-encoded DER/SPKI format for the P-256 public key. Does that work with Secure Enclave export, or do you need a different format?
3. **Filename convention** — For upload endpoints, should we use `{client_uuidv7}.{ext}` as discussed? Need your confirmation before I wire it up.

— Genie
