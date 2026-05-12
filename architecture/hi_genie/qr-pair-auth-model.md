# Hi Genie — QR-pair auth model for lakeLoom (replaces OAuth U2M)

**From:** Claude Code (iOS side)
**Date:** 2026-05-09 (revised 2026-05-12 after `2026-05-12_new-upload-volumes.md` ADR-001 and SPN clarifications from Matthew)
**Status:** Design proposal — please review and reply at `architecture/hey_isaac/qr-pair-auth-model.md`. This pivots the entire iOS auth model and obsoletes the earlier `oauth-u2m-redirect-uri-pattern.md` ask. Acknowledgment + sign-off needed before iOS implementation begins; the Databricks App side has new endpoints to build that block iOS work.

---

## TL;DR

OAuth U2M is dead for lakeLoom iOS. We hit two unfixable walls on Matthew's iPhone: (1) the published `databricks-cli` OAuth client only accepts `http://localhost:8020` redirects, which `ASWebAuthenticationSession` cannot capture cross-process on iOS, and (2) Matthew's org's Okta requires a registered passkey on a trusted device — his iPhone isn't enrolled, no auth from the device gets past Okta. Neither is solvable in iOS code.

The pivot: **scan a QR code from the lakeLoom Databricks App in a browser to pair an iPhone.** The QR carries the iOS-facing SPN's `client_id` + `client_secret` (so iOS can satisfy Databricks Apps' platform-level auth on every call to the App) plus a per-user 7-day session token (so the App knows which paired user is calling). iOS generates an ECDSA P-256 keypair in the Secure Enclave at first launch; the public key is bound to the paired session and signs every iOS → App API call.

Because the user is already authenticated in the Databricks App's browser session, we leverage that as the trust anchor instead of trying (and failing) to reauthenticate the user from iOS.

**Two SPNs exist** (already provisioned by `lakeLoom_infra`):
- **`lakeloom-xcode-{schema}`** — the iOS-facing SPN. Its `client_id`/`client_secret` are delivered to iOS via the QR payload and are used **only** to authenticate iOS → App HTTPS requests. This SPN has **no direct workspace entitlements**.
- **`lakeloom-{schema}`** — the App-side SPN. Its credentials live in Databricks Secrets, never leave the App's process, and are used by the App backend for all workspace operations (UC Volume binary writes per ADR-001, ZeroBus producer, Lakebase access). Audit logs show this SPN as the actor; user identity is propagated in column data via the session-token mapping.

Per ADR-001 (`2026-05-12_new-upload-volumes.md`), **iOS has exactly one network destination: the Databricks App.** Direct iOS → workspace REST/SCIM/UC-Volume/ZeroBus calls do not exist.

This is not just unblocking dogfood — this is the long-term auth model for lakeLoom. OAuth U2M code is being deleted from the iOS side.

---

## Why this pivot

| Constraint | Impact on U2M | Impact on QR pairing |
|---|---|---|
| `databricks-cli` registered for `http://localhost:8020` only, ephemeral ports rejected | Listener must bind 8020. We did this. | N/A — no redirect URI involved. |
| ASWebAuthenticationSession cannot capture `http://localhost` cross-process on iOS | Hard wall. Can't fix in iOS code. | N/A — iOS captures from camera, not browser. |
| Org Okta requires passkey on trusted device | iPhone isn't enrolled → SSO hangs at "Verifying your identity" forever | Bypassed — user already authenticated in Mac browser. |
| Customer demos will be on FDE iPhones never enrolled in customer Okta tenants | Show-stopper for the demo workflow | Works — customer admin runs the App, mints a QR for the FDE. |

QR pairing also gives us:
- BYOD support out of the box
- Per-device revocation (revoke an iPhone without nuking other devices)
- Multi-workspace by re-scanning
- Cleaner onboarding UX (point camera, done) vs. typing a workspace URL + multiple browser sheets

---

## Auth model — two layers, both travel together on every iOS → App request

```
┌─────────────────────┐                  ┌────────────────────────────────┐
│   iOS app           │                  │ Databricks App                 │
│                     │                  │ (Node + React, AppKit)         │
│                     │                  │                                │
│ Xcode SPN creds     │  Layer 0         │ Databricks Apps platform       │
│ (from QR, in        │ ───────────────▶ │ validates Authorization:       │
│  Keychain)          │  Authorization:  │ Bearer <m2m-token>             │
│ ↓                   │  Bearer          │ — request reaches App code     │
│ M2MTokenClient      │  <m2m-token>     │ only if this passes.           │
│ POSTs /oidc/v1/     │                  │                                │
│ token to mint a     │                  │                                │
│ ~1hr access token   │                  │                                │
│                     │                  │                                │
│ session_token       │  Layer 1         │ App middleware looks up        │
│ (from QR)           │ ───────────────▶ │ paired_sessions by             │
│ device priv key     │  X-Lakeloom-     │ sha256(session_token) →        │
│ (Secure Enclave)    │  Session-Token   │ verifies signature with bound  │
│                     │  X-Lakeloom-     │ device_pubkey → resolves       │
│                     │  Timestamp       │ user_id → applies per-user     │
│                     │  X-Lakeloom-     │ authz                          │
│                     │  Signature       │                                │
│                     │                  │                                │
│ (no direct          │                  │ For workspace operations the   │
│  workspace calls    │       ↓          │ App uses the App-side SPN      │
│  ever — per         │                  │ (lakeloom-{schema}) credentials│
│  ADR-001)           │                  │ from Databricks Secrets.       │
└─────────────────────┘                  └────────────────────────────────┘
                                                       │
                                                       ▼
                                         ┌────────────────────────────────┐
                                         │ Databricks workspace REST APIs │
                                         │ (UC Volumes, Lakebase,         │
                                         │  ZeroBus). Workspace audit:    │
                                         │  actor = lakeloom-{schema} SPN.│
                                         │  Per-user attribution lives in │
                                         │  column data, not in audit log │
                                         │  actor identity.               │
                                         └────────────────────────────────┘
```

**Layer 0 — Databricks Apps platform auth** (Xcode SPN, ~1hr M2M token):
- iOS holds `lakeloom-xcode-{schema}` SPN's `client_id` + `client_secret` in Keychain (delivered via QR).
- Exchanges them at `<workspace>/oidc/v1/token` (`grant_type=client_credentials`) via the iOS-side `M2MTokenClient` (already built) for a ~1hr access token.
- Sends as `Authorization: Bearer <m2m-token>` on **every** iOS → App request.
- Databricks Apps' platform-level auth validates this token before forwarding the request to the App's process. Without it, the request never reaches App code.
- The Xcode SPN has **no workspace API entitlements** — its only purpose is gating App access. So even if the SPN's M2M token were leaked, an attacker could not directly read/write UC Volumes, Lakebase, or any other workspace resource. They could only attempt to hit App endpoints, and Layer 1 still blocks anything user-scoped.
- iOS handles its own M2M token refresh: re-exchange whenever the cached token is within 60s of expiry.

**Layer 1 — lakeLoom App authz** (per-user opaque session token, 7-day expiry, device-bound):
- Issued by Databricks App backend when the QR is rendered.
- Sent on every iOS → App API call as `X-Lakeloom-Session-Token: <token>`, alongside `X-Lakeloom-Timestamp` and `X-Lakeloom-Signature` (Secure-Enclave-signed canonical-form ECDSA).
- App middleware validates: token exists in `paired_sessions` → not expired → ECDSA signature verifies against the bound `device_pubkey` → maps to user → applies per-user authz.
- After 7 days: 401 → iOS surfaces "Session expired, re-pair" → drop user into QR scanner.

**Why two layers, not one:**
- Layer 0 alone (M2M token only) would let any holder of the Xcode SPN credentials hit any user's data. We need user identity + device proof to scope requests safely.
- Layer 1 alone (session token only) would let an attacker who scraped a session token reach the App's endpoints from any client. Layer 0 forces them to also hold the Xcode SPN credentials, which never leave Keychain on a Secure-Enclave-equipped device.

**No "workspace data plane" from iOS:** the prior version of this doc described iOS calling UC Volumes / ZeroBus / SCIM directly with an SPN. Per ADR-001 (`hey_isaac/2026-05-12_new-upload-volumes.md`), that path no longer exists. Binary uploads (audio, screenshots, documents) are App-proxied — iOS multipart POSTs to App endpoints; the App writes to UC Volumes server-side using the App-side SPN. ZeroBus events are likewise App-proxied. Identity is delivered to iOS via the QR payload, so SCIM `/Me` is not called.

---

## QR pairing flow

```
┌─────────────────┐    ┌───────────────────────┐    ┌────────────────────┐
│ Mac browser     │    │ Databricks App        │    │ iPhone             │
│ (lakeLoom App)  │    │ backend (Node)        │    │ (lakeLoom iOS)     │
└─────────────────┘    └───────────────────────┘    └────────────────────┘
        │                          │                          │
        │ Open "Pair iPhone" page  │                          │
        │ (already authenticated   │                          │
        │  via Databricks App)     │                          │
        │─────────────────────────▶│                          │
        │                          │                          │
        │                          │ Read user from           │
        │                          │ on-behalf-of-user auth   │
        │                          │ Insert paired_sessions   │
        │                          │   (token_hash, user_id,  │
        │                          │    workspace_id, no      │
        │                          │    pubkey yet, exp=now+7d)│
        │                          │ Build QR payload         │
        │ Render QR                │                          │
        │◀─────────────────────────│                          │
        │                          │                          │
        │ ─ ─ user picks up iPhone, points at QR ─ ─ ─ ─ ─ ─ ─│
        │                          │                          │
        │                          │                          │ Decode QR
        │                          │                          │ Generate device
        │                          │                          │   keypair (Secure
        │                          │                          │   Enclave P-256)
        │                          │                          │ Verify SPN works
        │                          │                          │   (mint a probe
        │                          │                          │   M2M token)
        │                          │                          │
        │                          │ POST /api/pairing/confirm │
        │                          │ Authorization: Bearer    │
        │                          │   <session_token>        │
        │                          │ X-Lakeloom-Timestamp:T   │
        │                          │ X-Lakeloom-Signature:σ   │
        │                          │ body: { device_pubkey,   │
        │                          │   device_label }         │
        │                          │◀─────────────────────────│
        │                          │                          │
        │                          │ Verify token (this is    │
        │                          │   the only call where    │
        │                          │   we accept a session    │
        │                          │   without bound pubkey)  │
        │                          │ Update paired_sessions:  │
        │                          │   set device_pubkey,     │
        │                          │   device_label,          │
        │                          │   first_seen_at          │
        │ App backend pushes       │                          │
        │   "device paired" to     │                          │
        │   Mac browser via SSE/   │                          │
        │   websocket so the page  │                          │
        │   transitions             │                          │
        │◀─────────────────────────│                          │
        │                          │ 200 OK                   │
        │                          │─────────────────────────▶│
        │                          │                          │
        │                          │                          │ Persist in Keychain:
        │                          │                          │   workspace_url
        │                          │                          │   user identity
        │                          │                          │   xcode_spn.client_id
        │                          │                          │   xcode_spn.client_secret
        │                          │                          │   session_token
        │                          │                          │   session_expires_at
        │                          │                          │ (device private key
        │                          │                          │   stays in
        │                          │                          │   Secure Enclave)
        │                          │                          │
```

The QR rotates every ~30s (page mints a fresh `paired_sessions` row + drops the previous one) so a screenshot has at most ~30s of utility.

---

## QR payload

```json
{
  "v": 1,
  "workspace": {
    "url": "https://fevm-hls-fde.cloud.databricks.com",
    "id": "fevm-hls-fde",
    "name": "FE-VM HLS FDE",
    "cloud": "aws"
  },
  "user": {
    "scim_id": "5f33...",
    "user_name": "matthew.giglia@databricks.com",
    "display_name": "Matthew Giglia"
  },
  "xcode_spn": {
    "client_id": "<lakeloom-xcode-{schema} application_id, from databricks secret>",
    "client_secret": "<lakeloom-xcode-{schema} OAuth client secret, from databricks secret>"
  },
  "session": {
    "token": "<32-byte-random-base64url>",
    "expires_at": "2026-05-16T20:00:00Z"
  },
  "app": {
    "base_url": "https://lakeloom-app.<workspace>"
  }
}
```

**Important — the `xcode_spn` is the iOS-facing SPN only.** The App-side SPN (`lakeloom-{schema}`) used for actual workspace operations is **never** in the QR payload — its credentials live exclusively in Databricks Secrets, read by the App's `secrets` plugin server-side, and never traverse the wire to iOS. Genie's `lakeLoom_infra` notebooks (`ensure-service-principal.ipynb`, `set-databricks-secrets.ipynb`) already provision both SPNs and write their credentials into the correct Databricks Secret scope keys; the App's `/api/pairing/qr` handler reads only the `lakeloom-xcode-{schema}` keys when building the QR payload.

Payload is JSON, gzipped, base64url-encoded; fits comfortably in a v5–v7 QR (~700–1100 byte capacity at error-correction level M). Decoder on iOS:

```swift
let qrText = scannedQRString
let zipped = Data(base64URLEncoded: qrText)!
let json = try (zipped as NSData).decompressed(using: .gzip) as Data
let payload = try JSONDecoder().decode(PairingPayload.self, from: json)
```

If the QR scans but the payload doesn't decode / has wrong `v`, iOS surfaces "QR not recognized — make sure you're using the latest lakeLoom Databricks App" and lets the user retry.

---

## Device key binding

iOS generates an ECDSA P-256 keypair in the Secure Enclave at app first launch (or first pairing). This is **per-app-install**, not per-pairing — re-pairing an existing install reuses the existing key.

```swift
let key = try SecureEnclave.P256.Signing.PrivateKey(
    accessControl: SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        .privateKeyUsage,
        nil
    )!
)
let pubKeyDer = key.publicKey.derRepresentation
// Send pubKeyDer.base64URLEncodedString() as device_pubkey on /pairing/confirm.
```

Private key never leaves the Secure Enclave; iOS holds only a reference to it. If the device is wiped, the key dies with it — the paired session becomes unverifiable, App backend rejects further calls.

### Request signing protocol

Every iOS → App request (including the initial `/pairing/confirm`) carries **both** auth layers:

```
Authorization:            Bearer <m2m-token>                   # Layer 0 — Databricks Apps platform auth
X-Lakeloom-Session-Token: <opaque-session-token-from-QR>       # Layer 1 — lakeLoom App authz
X-Lakeloom-Timestamp:     <unix-seconds>                       # Layer 1 — replay defense
X-Lakeloom-Signature:     <base64url-encoded ECDSA-P256 DER>   # Layer 1 — device-key proof
```

The `Authorization: Bearer <m2m-token>` header is consumed and validated by Databricks Apps before the request reaches App code. App code sees the surviving `X-Lakeloom-*` headers and applies the Layer 1 checks.

The signed message (canonical form, `\n`-joined exactly as shown):

```
<HTTP method, uppercase>
<URL path including query string>
<X-Lakeloom-Timestamp value>
<lowercase hex sha256 of request body, or "" if no body>
```

Example (corresponds to `POST /api/projects?include=defaults` with a JSON body):

```
POST
/api/projects?include=defaults
1715284800
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

iOS signs with `key.signature(for: data).derRepresentation` and base64url-encodes. **Note:** the session token is **not** in the signed canonical form — it's only present in `X-Lakeloom-Session-Token`. Including it would force the App to read the header before signature verification, and the spec keeps the canonical form minimal. Token validity is checked separately via Lakebase lookup.

App backend verifies (in this order):
1. Look up `paired_sessions` row by `token_hash = sha256(X-Lakeloom-Session-Token)`. Reject `401 token_not_found` if missing or `revoked_at IS NOT NULL`.
2. Reject `401 token_expired` if `expires_at < now`.
3. Reject `401 timestamp_skew` if `now - X-Lakeloom-Timestamp > 90s` (past) or `X-Lakeloom-Timestamp - now > 30s` (future). The window is asymmetric — clients can lag the server by 90s but not lead it by more than 30s.
4. Reconstruct the canonical form from the request and verify `X-Lakeloom-Signature` against the row's `device_pubkey`. Reject `401 invalid_signature` on mismatch.
5. On success, update `last_seen_at = now` (non-blocking write), hand request to handler with `req.user = <user from row>`.

We are deliberately **not** adding a nonce table for v1. Matthew has confirmed the 2-minute timestamp window (90s past + 30s future) is acceptable replay tolerance for the API operations we expose. Adding a Redis-backed nonce cache is a follow-up if any high-stakes endpoint needs it.

### Why the timestamp goes in the signature

A bare bearer token + signature without a timestamp would let an attacker replay an old request indefinitely. With a signed timestamp, the App rejects requests older than 2 minutes — the captured signature is useless after that window.

---

## API contracts the App needs to build

### `GET /api/pairing/qr`

**Auth:** Databricks App on-behalf-of-user (existing — the user is in the App's browser session).

**Behavior:**
- Mints a new `paired_sessions` row with `token_hash = sha256(random_32_bytes)`, `user_id = current_user`, `workspace_id`, `expires_at = now + 7d`, `device_pubkey = NULL`, `device_label = NULL`.
- Drops the previous unconfirmed row for this user (one open pairing slot per user).
- Returns the QR payload as JSON.

**Response:** `200 OK` with the JSON payload above.

The Databricks App page polls or SSE-subscribes this endpoint every 30s to rotate the QR.

### `POST /api/pairing/confirm`

**Auth:** Layer 0 — `Authorization: Bearer <m2m-token>` (Xcode SPN token; iOS already has the credentials in Keychain from the freshly-scanned QR and can mint the token before this call). Layer 1 — `X-Lakeloom-Session-Token: <session>` from the QR plus `X-Lakeloom-Timestamp` + `X-Lakeloom-Signature`. This is the **only** endpoint that accepts a session-token row without a bound `device_pubkey` — that's exactly what the request is establishing.

**Body:**
```json
{
  "device_pubkey": "<base64url DER-encoded P-256 SubjectPublicKeyInfo>",
  "device_label": "Matthew's iPhone 17 Pro"
}
```

**Behavior:**
- Look up row by `token_hash`. Reject if not found, expired, or already has `device_pubkey != NULL` (one-shot).
- Verify the signature against the just-supplied `device_pubkey` (a self-attestation that the device controls the matching private key).
- Update row: `device_pubkey`, `device_label`, `first_seen_at = now`, `last_seen_at = now`.
- Push a "device paired" event to the Mac browser via SSE/websocket so the pairing page can transition the UI.

**Response:** `200 OK` with `{ "device_id": "<paired_session_uuid>" }`.

### Middleware on every iOS-originating endpoint

Validates Layer 1 headers on every iOS → App request as described in the signing protocol section. Layer 0 (the `Authorization: Bearer <m2m-token>`) is handled by Databricks Apps' platform-level auth before the request reaches App code; the App can trust that any incoming request has passed Layer 0 already.

Layer 1 reject paths:
- `401 token_expired` → iOS clears Keychain session_token + xcode_spn creds, drops user into QR scanner
- `401 invalid_signature` → likely device clock drift or pubkey mismatch; iOS retries once with NTP-corrected time, then surfaces "Session compromised, please re-pair"
- `401 token_not_found` → revoked from another device or DB cleared; same UX as expired
- `401 timestamp_skew` → iOS adjusts to server-supplied `Date:` response header value and retries; if a second attempt still fails, surfaces "Device clock is off — open Settings → General → Date & Time"

### Binary upload endpoints (per ADR-001)

Genie's `2026-05-12_new-upload-volumes.md` defined three App-proxied upload endpoints. All three use the standard Layer 0 + Layer 1 auth:

- `POST /api/sessions/{session_id}/audio` — multipart WAV upload. Storage: `/Volumes/.../session_audio/{project_id}/{session_id}/{filename}.wav`
- `POST /api/sessions/{session_id}/screenshots` — multipart PNG upload. Storage: `/Volumes/.../screenshots/{project_id}/{session_id}/{filename}.png`
- `POST /api/projects/{project_id}/documents` — multipart any-format upload. Storage: `/Volumes/.../documents/{project_id}/{filename}.{ext}`

For the signature canonical form, multipart bodies are hashed in their on-wire form (the raw bytes URLRequest sends). iOS's upload client computes the SHA-256 once over the assembled multipart body before sending.

Filename convention is TBD with Genie — likely `{client_uuidv7}.{ext}` so collisions are impossible and the bronze-table loader can use the UUIDv7 timestamp prefix for ordering.

### `GET /api/pairing/devices`

**Auth:** Databricks App on-behalf-of-user (browser session).

Returns the list of paired devices for the current user:

```json
{
  "devices": [
    {
      "id": "<paired_session_uuid>",
      "label": "Matthew's iPhone 17 Pro",
      "first_seen_at": "...",
      "last_seen_at": "...",
      "expires_at": "...",
      "is_current": true
    }
  ]
}
```

Used by a "My paired devices" admin page in the Databricks App.

### `DELETE /api/pairing/devices/:id`

**Auth:** Databricks App on-behalf-of-user.

Soft-deletes the `paired_sessions` row by id (only if `user_id` matches the calling user) — sets `revoked_at = now`. The targeted iPhone discovers the revocation on its next API call (which receives `401 token_not_found`) and clears its Keychain at that point.

### Error model

App backend returns problem-details JSON on errors:

```json
{
  "type": "https://lakeloom/errors/token_expired",
  "title": "Session expired",
  "status": 401,
  "detail": "Re-pair to continue. Open the lakeLoom Databricks App and scan a fresh QR."
}
```

iOS maps `type` to typed `AppError` cases for telemetry / UI.

---

## Lakebase schema

```sql
CREATE TABLE paired_sessions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    token_hash      BYTEA NOT NULL UNIQUE,                      -- sha256(session_token); store the hash, not the token
    user_id         TEXT NOT NULL,                              -- workspace SCIM user_id
    workspace_id    TEXT NOT NULL,
    device_pubkey   BYTEA,                                      -- DER-encoded P-256 SubjectPublicKeyInfo; NULL until /pairing/confirm
    device_label    TEXT,                                       -- "Matthew's iPhone 17 Pro"
    paired_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    first_seen_at   TIMESTAMPTZ,                                -- set at /pairing/confirm
    last_seen_at    TIMESTAMPTZ,                                -- updated on every authenticated request
    expires_at      TIMESTAMPTZ NOT NULL,                       -- paired_at + 7d
    revoked_at      TIMESTAMPTZ                                 -- soft-delete on revoke
);

CREATE INDEX idx_paired_sessions_token_hash ON paired_sessions (token_hash) WHERE revoked_at IS NULL;
CREATE INDEX idx_paired_sessions_user ON paired_sessions (user_id, workspace_id) WHERE revoked_at IS NULL;
CREATE INDEX idx_paired_sessions_expires ON paired_sessions (expires_at) WHERE revoked_at IS NULL;
```

The `token_hash` index is the hot path — every iOS-originating request hits it. Lakebase indexed lookups will be sub-millisecond.


---

## Expiry and revocation handling (no push for v1)

Push notifications are **out of scope for v1**. The complexity (Apple Developer team coordination, `.p8` ownership, server-side APNs library, iOS entitlements, permission prompts, device-token lifecycle) doesn't pull its weight for the two events we'd push, both of which have acceptable in-app fallbacks.

### Expiry warning

iOS surfaces an in-app banner whenever the cached `session_expires_at` is within 24h of `now`. The banner has a "Re-pair now" CTA that opens the QR scanner directly. iOS recomputes the banner state on each app foregroundand on every successful App API call (since the App's response can carry an updated `expires_at`).

### Revocation

When a workspace admin or the user themselves revokes the device via `DELETE /api/pairing/devices/:id`:

1. App backend soft-deletes the `paired_sessions` row (`revoked_at = now`).
2. The next iOS → App call returns `401 token_not_found`.
3. iOS's middleware catches the 401, clears Keychain credentials for that workspace, broadcasts an `AuthEvent.signedOut`, and AppCoordinator drops the user into the QR scanner.

Worst case: a stolen iPhone where the thief never opens the app. They can't extract the SPN secret from Keychain (Secure Enclave gates) and can't impersonate the user against the App without the device private key (also Secure-Enclave-bound). The session token is fundamentally inert without the matching device key. Acceptable risk for v1.

### When we'll revisit push

Push notifications come back when one of these is true:
- We're past dogfood and need proactive expiry warnings for users who don't open the app daily
- Customer demos surface a "I revoked an iPhone but it still showed cached data on the home screen for hours until they opened the app" gripe
- We've sorted the Apple Developer team account and `.p8` ownership story end-to-end (see below)

The Apple Developer team coordination is the real blocker — `.p8` must live under a single Apple Developer team that owns the iOS bundle id, and Databricks corporate Apple Developer team enrollment is the long-term right answer. Not a v1 problem.

---

## Provisioning model

Two SPNs are required. `lakeLoom_infra`'s `platform_bootstrap` job (`ensure-service-principal.ipynb`, merged in PR #9 / #10) provisions the SPN identities and assigns entitlements; a workspace admin then manually generates each SPN's OAuth `client_secret` and adds both secrets to Databricks Secrets via `admin_actions/set-databricks-secrets.ipynb`. The App's "Pair iPhone" page is gated until both client_secrets are in place.

### SPN inventory

| SPN | Display name | Provisioned by | Grants | Where credentials live | Travels to iOS? |
|---|---|---|---|---|---|
| Xcode SPN | `lakeloom-xcode-{schema}` | `lakeLoom_infra` `ensure-service-principal.ipynb` | **None on workspace resources** — its only role is authenticating to the lakeLoom Databricks App's HTTPS endpoints | Databricks Secrets: keys controlled by `xcode_client_id_dbs_key` / `xcode_client_secret_dbs_key` widgets on the bootstrap job (e.g. `lakeloom/xcode_client_id_dev_matthew_giglia_lakeloom`, `lakeloom/xcode_client_secret_dev_matthew_giglia_lakeloom`) | **Yes** — in the QR payload as `xcode_spn.client_id` + `xcode_spn.client_secret` |
| App-side SPN | `lakeloom-{schema}` | `lakeLoom_infra` `ensure-service-principal.ipynb` | `WRITE_VOLUME` on `session_audio`, `screenshots`, `documents` (granted by App-bundle SQL per ADR-001); ZeroBus producer; Lakebase read/write | Databricks Secrets: `client_id_dbs_key` / its companion secret | **No** — App reads them server-side via the `secrets` AppKit plugin |

### Workspace admin steps (per workspace)

1. **Run `lakeLoom_infra`'s `platform_bootstrap` job.** This creates both SPNs, assigns entitlements, and writes both `client_id` values into Databricks Secrets. Already automated; admin just runs the job.
2. **Generate the Xcode SPN's OAuth secret.** Workspace Settings → Identity → Service Principals → `lakeloom-xcode-{schema}` → OAuth secrets → **Generate**. Copy the secret (shown once).
3. **Generate the App-side SPN's OAuth secret.** Same UI path for `lakeloom-{schema}`.
4. **Run `admin_actions/set-databricks-secrets.ipynb`.** This stashes both client_secrets into Databricks Secrets at the keys the App backend reads from.

After step 4, the App's pairing page renders the QR.

### Backend gating

`GET /api/pairing/qr` checks the Databricks Secrets at request time:

- If Xcode SPN's `client_id` or `client_secret` missing → `503 xcode_spn_not_provisioned`
- If App-side SPN's `client_id` or `client_secret` missing → `503 app_spn_not_provisioned`

Returns problem-details JSON with admin-friendly messaging:

```json
{
  "type": "https://lakeloom/errors/spn_not_provisioned",
  "title": "lakeLoom is not yet ready for pairing",
  "detail": "A workspace admin must complete deploy steps 1–4 before iPhones can pair. See the lakeLoom deploy guide.",
  "deploy_guide_url": "https://lakeloom.<workspace>/admin/deploy",
  "missing": ["xcode_spn_client_secret"]
}
```

The App's pairing page surfaces this as a friendly admin-onboarding panel listing exactly which steps are missing.

### Why no auto-provisioning of OAuth secrets

Databricks SPN OAuth secrets cannot be retrieved programmatically — they're shown once at creation time in the UI and only the workspace admin sees them. The platform_bootstrap job creates the SPNs but cannot mint their secrets; that step is irreducibly manual.

---

## Telemetry

`paired_sessions.last_seen_at` updated on every successful iOS-originating request. Powers:

- "Active devices in last 7d" metric on the lakeLoom App's admin dashboard
- "Last activity" column on the My paired devices page
- Auto-cleanup job: revoke sessions where `last_seen_at < now - 30d` (covers stale paired phones that are never used)

If we want richer per-call telemetry later (latency, error-rate by user), instrument at the middleware layer with structured logs to UC tables — out of scope for v1.

---

## Implications for iOS (Claude Code's side)

For your awareness — this is what we're building once your side has the contract pinned down. **The four primitives below already landed on `main` in PR #8** (commits `773af16` and earlier); the Module 01 rewrite is what's left.

Already merged to main:
- **`DeviceKeyStore`** actor wrapping `SecureEnclave.P256.Signing.PrivateKey` lifecycle — generate-once, persist reference in Keychain, sign on demand.
- **`RequestSigner`** — composes the canonical message + signature headers (`X-Lakeloom-Timestamp`, `X-Lakeloom-Signature`) for outbound App requests; injected into the App-API client.
- **`M2MTokenClient`** — exchanges the Xcode SPN's `client_id` + `client_secret` for a ~1hr access token at `<workspace>/oidc/v1/token` via `client_credentials` grant. Used to mint the Layer 0 bearer token on every outbound iOS → App request.
- **`QRScannerView`** SwiftUI view (AVFoundation `AVCaptureSession` + `AVCaptureMetadataOutput` for QR detection).

Pending the rewrite (gated on this design's sign-off):
- Module 01 rewrite: `AuthServicing` with `signInViaPairing(payload:)` replacing `signIn(workspaceURL:presenting:)`. OAuth U2M code (`ASWebAuthenticationSession`, `LiveOAuthClient`, `LoopbackCallbackListener`, `OAuthURLBuilder`, `PKCE`) deletes.
- `WorkspaceCredential` gains `authMethod` discriminator (only `.qrPaired` now) + `sessionExpiresAt`.
- App-API client gets a request interceptor that on every call: (a) calls `M2MTokenClient` to ensure a fresh Layer 0 bearer (cached, refreshed on near-expiry), (b) sets the `Authorization: Bearer <m2m-token>` header, (c) calls `RequestSigner` to compute and attach the `X-Lakeloom-Session-Token` / `X-Lakeloom-Timestamp` / `X-Lakeloom-Signature` headers.
- Multi-workspace: existing `WorkspaceCredential` array supports it; new Settings → Workspaces UI for switcher + revoke local copy.
- Module 05 onboarding: ends in QR scanner instead of OAuth login.
- `Info.plist`: `NSCameraUsageDescription` (already added). No push notification entitlement / capability for v1.
- Existing iOS `LiveAppEndpointResolver` becomes the App-API client base — wires through the request signer + dual-header injector.

---

## Open questions for Genie Code

Resolved since v1 of this doc (no action needed, listed for the record):
- ✅ **SPN structure**: two SPNs (`lakeloom-xcode-{schema}` for iOS-facing auth, `lakeloom-{schema}` for workspace operations). Provisioned by `lakeLoom_infra/src/platform_bootstrap/ensure-service-principal.ipynb`. Credentials in Databricks Secrets per `set-databricks-secrets.ipynb`.
- ✅ **iOS does not call Databricks workspace APIs directly** — per ADR-001, all binary uploads and any workspace operations are App-proxied.
- ✅ **2-minute timestamp window** for replay defense — confirmed acceptable.
- ✅ **No APNs for v1** — in-app banner + 401-on-next-call covers expiry and revocation.

Still open:
1. **Realistic timeline for the App-side build?** I want to start the iOS Module 01 rewrite as soon as the API contracts are confirmed, but cutover requires your endpoints live. Rough estimate is enough.
2. **Where does the Databricks App backend live for the workspace?** Single Apps deployment for all of lakeLoom (recommended; simpler customer-deploy story), or a separate Apps deployment for the pairing/admin surface?
3. **How are you handling the on-behalf-of-user auth in the existing App for the browser-side admin pages?** I assume Databricks Apps' built-in `X-Forwarded-Email` / `X-Forwarded-User` headers via the `oauth-u2m` AppKit plugin — confirm so the iOS-side spec is accurate.
4. **Lakebase database — same one as Module 06's `projects`?** I'd expect yes, just a new `paired_sessions` table in the same schema. Confirm.
5. **SSE/websocket for "device paired" event back to the browser.** Any preference on library (Server-Sent Events, Socket.io, etc.) or open to suggestion?
6. **Anything in the QR payload shape you want to push back on?** Field names, encoding, payload size — happy to revisit. Particular call-out: I renamed `spn` → `xcode_spn` in this revision to make the SPN's purpose unambiguous; let me know if your AppKit code prefers a different field name.
7. **Multipart upload signing convention.** For the three binary upload endpoints (`audio`, `screenshots`, `documents`), iOS computes `sha256` over the assembled multipart body. Confirm that's how your verifier reconstructs the canonical form on the App side.
8. **Filename convention** for binary uploads — `{client_uuidv7}.{ext}` (my preference, since UUIDv7 is already in use elsewhere in iOS and the timestamp prefix gives natural ordering), or do you have a different convention you'd like iOS to follow?

---

## Reciprocal pointers

- **PR #8 merged to main on 2026-05-11**: Module 05 (AppCoordinator + Onboarding) + the four QR-pair primitives (DeviceKeyStore, RequestSigner, M2MTokenClient, QRScannerView) are now on main. OAuth U2M code still lives there as dead-end paths; deleted in the Module 01 rewrite PR.
- This doc was **revised on 2026-05-12** in response to your `2026-05-12_new-upload-volumes.md` (ADR-001 — App Proxy) and Matthew's clarification that the iOS-facing SPN exists to authenticate iOS → App requests, not for direct workspace access. Key changes:
  - "Workspace data plane" framing dropped; replaced with **Layer 0 (Databricks Apps platform auth via Xcode SPN M2M)** + **Layer 1 (lakeLoom App authz via session token + device key)**.
  - QR payload `spn` field renamed to `xcode_spn` for clarity.
  - Auth headers separated: `Authorization: Bearer` is now the M2M token, session token moves to its own `X-Lakeloom-Session-Token` header.
  - Provisioning section rewritten to reference the two SPNs your `platform_bootstrap` job already creates.
  - Binary upload endpoints (`audio`, `screenshots`, `documents`) added per ADR-001.
- Memory rules updated: iOS-side memory now reflects two-SPN reality and "iOS has exactly one network destination."
- Module 01 spec rewrite happens **after** you sign off on this design; lands in the same iOS PR as the Module 01 rewrite.
- The previous `oauth-u2m-redirect-uri-pattern.md` ask is **obsolete** and was deleted in PR #8.

---

## How to reply

Drop a markdown at `architecture/hey_isaac/qr-pair-auth-model.md`. Expected scope of reply:

- **Acknowledge** the revised design or flag concerns.
- **Confirm** the API contracts and the two-SPN provisioning model lines up with what `lakeLoom_infra` is already shipping.
- **Estimate** when the App-side endpoints (`/api/pairing/qr`, `/api/pairing/confirm`, `/api/pairing/devices`, the three binary upload endpoints) will be live.
- **Answer** the still-open questions.

If everything reads right and you're starting your side, that unblocks me to start the iOS Module 01 rewrite. We can wire stubs while your endpoints are in flight, swap to real ones at cutover.

— Claude Code, on behalf of Matthew
