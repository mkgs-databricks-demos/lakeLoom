# Hey Isaac — QR Host Header Bug Fixed

**From:** Genie Code (Databricks side)
**Date:** 2026-05-14
**Status:** Patched. Deploying now. Will be live within minutes.

---

## Summary

Good catch. The `localhost:8000` issue in `app.base_url` is fixed in `pairing-routes.ts`. Root cause was exactly as you described — Express sees the container's loopback address because the platform proxy terminates TLS at the edge and forwards internally.

## What Changed

**File:** `lakeloom-ai/server/routes/pairing/pairing-routes.ts`

Before:
```typescript
app: {
  base_url: `https://${req.headers.host}`,
},
```

After:
```typescript
const forwardedHost = (req.headers['x-forwarded-host'] as string | undefined) ?? req.headers.host;
const forwardedProto = (req.headers['x-forwarded-proto'] as string | undefined) ?? 'https';

app: {
  base_url: `${forwardedProto}://${forwardedHost}`,
},
```

Fallback to `req.headers.host` preserves the local-dev / Simulator-on-Mac flow.

## Verification

Once the deploy completes:
- `GET /api/pairing/qr` will return `app.base_url = "https://lakeloom-ai-dev-7474657291520070.aws.databricksapps.com"`
- iOS confirm request hits the real endpoint instead of loopback
- No iOS-side change needed

## Also Deploying (Same Bundle Push)

Unrelated to your bug, but shipping in the same deploy:
- **Migration 004: `app.projects` table** — project management CRUD, cursor-based pagination, pg_trgm extension test
- **Project routes** (`/api/v1/projects/*`) — 6 endpoints with dualAuth (iOS + browser)
- **Browser auth middleware** — `x-forwarded-email` / `x-forwarded-user` identity extraction

None of these touch pairing. Your Module 01 rewrite can pair as soon as the deploy is green.

## Next Steps

Retry pairing from the iPhone once the app is back up. If it sails through to `.identityConfirmation`, we're unblocked for Module 02 integration testing. Let me know if anything else surfaces.

— Genie Code, on behalf of Matthew
