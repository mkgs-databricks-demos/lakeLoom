# New Upload Volumes Deployed — Screenshots & Documents

**Date:** 2026-05-12  
**From:** Genie (Databricks)  
**Status:** Deployed and validated on `dev`

---

## What's New

Two new **managed UC Volumes** are now provisioned alongside `session_audio`:

| Volume | UC Path | Purpose |
| --- | --- | --- |
| `screenshots` | `/Volumes/{catalog}/{schema}/screenshots` | Session screen captures (PNG) |
| `documents` | `/Volumes/{catalog}/{schema}/documents` | Project-level documents (any format) |

Dev values: `catalog` = `hls_fde_dev`, `schema` = `lakeloom`.

---

## Upload Pattern (ADR-001 — App Proxy)

Per the auth architecture decision, **all binary uploads route through the Databricks App endpoints**. The iOS app does NOT write directly to UC Volumes.

```
iOS App  →  App API endpoint (authenticated via Xcode SPN M2M)  →  App backend  →  UC Volume write (App SPN)
```

---

## Expected App Endpoints for iOS

Isaac — the App bundle needs to expose these upload endpoints (or similar):

### Screenshots
- **Endpoint:** `POST /api/sessions/{session_id}/screenshots`
- **Body:** multipart file upload (PNG)
- **Storage path:** `/Volumes/.../screenshots/{project_id}/{session_id}/{filename}.png`
- **Use case:** iOS captures screen during a session, uploads via this endpoint

### Documents
- **Endpoint:** `POST /api/projects/{project_id}/documents`
- **Body:** multipart file upload (any format — PDF, DOCX, etc.)
- **Storage path:** `/Volumes/.../documents/{project_id}/{filename}.{ext}`
- **Use case:** User attaches reference documents to a project

### Audio (existing)
- **Endpoint:** `POST /api/sessions/{session_id}/audio` (already planned)
- **Storage path:** `/Volumes/.../session_audio/{project_id}/{session_id}/{filename}.wav`

---

## Grants / Permissions

`WRITE_VOLUME` on all three volumes is **App-bundle responsibility** — the App's SPN needs the grant. The infra bundle creates the volumes but does NOT grant write access (separation of concerns).

The App bundle should include:
```sql
GRANT WRITE_VOLUME ON VOLUME {catalog}.{schema}.session_audio TO `app-spn`;
GRANT WRITE_VOLUME ON VOLUME {catalog}.{schema}.screenshots TO `app-spn`;
GRANT WRITE_VOLUME ON VOLUME {catalog}.{schema}.documents TO `app-spn`;
```

---

## Action Items for Isaac

1. **Design App API endpoints** for screenshots and documents uploads (patterns above)
2. **iOS upload service** — extend the networking layer to support these two new upload types
3. **App bundle grants** — ensure the App SPN gets `WRITE_VOLUME` on all three volumes
4. **Filename conventions** — confirm naming (timestamps? UUIDs?) so both sides agree on path structure

---

## Validation

The platform bootstrap job (`platform_bootstrap`) now validates all three volumes exist and are MANAGED. Run completed successfully 2026-05-12.
