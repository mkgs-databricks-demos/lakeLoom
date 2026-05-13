# Hey Isaac — QR-pair auth model: Acknowledged & Implemented

**From:** Genie Code (Databricks App side)  
**Date:** 2026-05-13  
**Status:** Design accepted. App-side implementation complete. **iOS Module 01 rewrite is unblocked.**

> **NOTE:** Move this file to `lakeLoom/architecture/hey_isaac/qr-pair-auth-model.md` before Isaac reads it.

---

## TL;DR

The revised QR-pair auth design is accepted in full. The App-side implementation is done — all endpoints, middleware, Lakebase schema, and browser UI are built and the bundle validates cleanly. You can begin the iOS Module 01 rewrite immediately.

---

## Design Acknowledgment

The two-layer auth model (Layer 0: Xcode SPN M2M via sidecar; Layer 1: session token + ECDSA P-256 device key via App middleware) is confirmed and implemented exactly as specified. No modifications to the protocol, header names, signing canonical form, or verification order.

Key confirmations:

* Two-SPN model aligns perfectly with deployed infra (`lakeloom-xcode-{schema}` + `lakeloom-{schema}`).
* ADR-001 (App-Proxied Data Plane) is the absolute contract — iOS has one network destination.
* QR payload shape accepted as-is (including `xcode_spn` field name — good call on the rename from `spn`).
* Timestamp skew window: 90s past / 30s future — implemented exactly.
* Session token stored as `sha256(token)` — raw token never touches the DB.
* `REPLICA IDENTITY FULL` set on `paired_sessions` for Lakehouse Sync (SCD Type 2 CDC to UC).

---

## API Contracts — Implemented

All endpoints are live in source (pending deploy):

| Endpoint | Auth | Status |
| --- | --- | --- |
| `GET /api/pairing/qr` | Browser (on-behalf-of-user) | Done |
| `POST /api/pairing/confirm` | iOS (Layer 0+1, unbound OK) | Done |
| `GET /api/pairing/devices` | Browser (on-behalf-of-user) | Done |
| `DELETE /api/pairing/devices/:id` | Browser (on-behalf-of-user) | Done |
| `GET /api/pairing/events` | Browser SSE | Done |
| `POST /api/sessions/:id/audio` | iOS (Layer 0+1) | Done (stub) |
| `POST /api/sessions/:id/screenshots` | iOS (Layer 0+1) | Done (stub) |
| `POST /api/projects/:id/documents` | iOS (Layer 0+1) | Done (stub) |
| `POST /api/sessions/:id/events` | iOS (Layer 0+1) | Done |

---

## Answers to Open Questions

### 1. Realistic timeline for the App-side build?

**Done.** The server-side auth mechanism is fully implemented as of today (2026-05-13). What remains before the pairing page is end-to-end testable:

* Deploy to dev (`deploy.sh --target dev --app`)
* Verify admin has provisioned both `client_secret` values in scope
* Install a QR rendering library (`qrcode.react`) — currently a placeholder

Estimate: testable with real QR within 1 session. The upload endpoints are stubs (file write works, filename convention TBD).

### 2. Single App deployment or separate?

**Single.** All lakeLoom functionality (pairing, uploads, events, admin, future project CRUD) lives in `lakeloom-ai` — one AppKit app, one deployment, one URL. Simpler customer-deploy story.

### 3. On-behalf-of-user auth for browser admin pages?

Databricks Apps' auth sidecar provides `X-Forwarded-User` (SCIM user_id), `X-Forwarded-Email`, and `X-Forwarded-Preferred-Username` headers on every authenticated browser request. The App reads these directly — no OAuth U2M flow needed for browser-side pages. This is what `GET /api/pairing/qr` uses to identify the current user when minting sessions.

### 4. Lakebase database — same one as projects?

**Yes.** Single `app` Postgres schema in the existing Lakebase database (`databricks_postgres`). `paired_sessions` lives alongside future `projects`, `sessions`, etc. One Lakehouse Sync config syncs all tables from `app` schema to the UC catalog.schema. Migration runner auto-creates the schema and table on startup.

### 5. SSE/websocket preference?

**Server-Sent Events (native).** No library needed — Express supports `text/event-stream` natively with `res.write()`. In-memory `Map<userId, Set<Response>>` tracks connections. 30s keepalive prevents proxy timeouts. No Socket.io, no external deps.

The browser page opens `new EventSource('/api/pairing/events')` and listens for `device_paired` events. The App pushes the event when `/pairing/confirm` succeeds.

### 6. QR payload field names?

**Accepted as-is.** `xcode_spn` (not `spn`) is unambiguous and aligns with how the infra bundle names things. No changes requested.

### 7. Multipart upload signing convention?

**Confirmed.** iOS computes SHA-256 over the assembled multipart body bytes (the raw wire form of URLRequest). The App verifier does the same — `sha256Hex(rawRequestBody)` goes into the canonical form's body-hash position. For the current stub implementation, we're using raw binary bodies (not multipart yet) with `X-Lakeloom-Filename` header for the extension. Will switch to proper multipart when filename convention is finalized.

### 8. Filename convention?

**Deferred.** We're using `crypto.randomUUID() + ext` as a provisional placeholder. Once auth is tested end-to-end, we'll revisit this together. Your preference for `{client_uuidv7}.{ext}` makes sense (collision-free, timestamp-ordered) — we'll likely adopt it but want to confirm after the full flow is working.

---

## Implementation Architecture

```
server/
├── lib/
│   ├── errors.ts           — RFC 9457 problem-details, AppError class, factories
│   └── crypto.ts           — SHA-256, ECDSA P-256 verify, token gen, canonical msg
├── middleware/
│   └── ios-auth.ts         — Layer 1 verification (5-step chain)
├── migrations/
│   ├── migrate.ts          — Auto-migrate runner (app._migrations tracking)
│   └── 001_paired_sessions.ts — Table + 3 partial indexes + REPLICA IDENTITY
├── services/
│   ├── secrets-service.ts  — Reads Databricks Secrets, exposes readiness gates
│   ├── sse-service.ts      — In-memory SSE connection registry per user
│   └── zerobus-service.ts  — Stream pool (lazy, round-robin, graceful shutdown)
├── routes/
│   ├── pairing/
│   │   └── pairing-routes.ts — QR, confirm, devices, SSE events
│   ├── uploads/
│   │   └── upload-routes.ts  — Audio, screenshots, documents via UC Volumes
│   └── events/
│       └── event-routes.ts   — Transcript events via ZeroBus to bronze table
└── server.ts               — Startup: secrets → migrations → routes → serve
```

Key design choices:
* **Pure Node.js crypto** — no external deps for SHA-256 or ECDSA P-256
* **Express middleware pattern** — `iosAuth({ lakebase, allowUnboundSession })` factory
* **Non-blocking `last_seen_at` updates** — fire-and-forget so it doesn't add latency
* **Graceful shutdown** — ZeroBus streams flush then Lakebase pool closes then exit

---

## What You Can Rely On Now

For the iOS Module 01 rewrite, these contracts are stable:

1. **Layer 0:** `Authorization: Bearer <M2M>` — validated by sidecar before App code runs.
2. **Layer 1 headers:** `X-Lakeloom-Session-Token`, `X-Lakeloom-Timestamp`, `X-Lakeloom-Signature` — exactly as specified.
3. **Canonical form:** `METHOD\nPATH\nTIMESTAMP\nBODY_HASH` (newline-joined, body hash is lowercase hex SHA-256 or empty string).
4. **`POST /api/pairing/confirm`** accepts unbound sessions (device_pubkey IS NULL). Self-attestation: signature verified against the supplied pubkey.
5. **Error responses:** problem-details JSON (`application/problem+json`). Types at `https://lakeloom/errors/{code}`.
6. **401 codes:** `token_expired`, `token_not_found`, `invalid_signature`, `timestamp_skew` — map to your iOS `AppError` cases.

---

## Next Steps (my side)

1. Deploy to dev and smoke-test the pairing flow browser-side
2. Add `qrcode.react` for real QR SVG rendering (currently placeholder)
3. Test with a real Xcode SPN M2M token hitting the App sidecar
4. Finalize filename convention (post auth-complete)
5. Wire ZeroBus stream pool to real traffic

---

## You're Unblocked

Start the iOS Module 01 rewrite. The API contracts are pinned, endpoints are built, and the App will be deployed to dev within the next session. Wire stubs against the contract now; swap to the live URL when I confirm deployment.

— Genie Code, on behalf of Matthew
