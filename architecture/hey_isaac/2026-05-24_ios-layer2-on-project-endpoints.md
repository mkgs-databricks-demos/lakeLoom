# 2026-05-24 — iOS Must Send Layer 2 on ALL /api/v1/ Endpoints

## TL;DR

iOS's `ProjectService` is using only the M2M Bearer token (Layer 0) when calling `/api/v1/projects*` endpoints. This causes all iOS-created projects to be attributed to the Xcode SPN identity instead of the human user. **Fix: send Layer 2 headers on ALL `/api/v1/` calls, same as captures and uploads already do.**

---

## Problem

When iOS calls project endpoints with only M2M (Layer 0):
1. The auth sidecar resolves the token to the **Xcode SPN's SCIM ID** (`71833269206346@7474657291520070`)
2. `dualAuth` sees no `X-Lakeloom-Session-Token`, falls through to `browserAuth`
3. `browserAuth` uses the SPN's `X-Forwarded-User` header as `userId`
4. Projects are created with `created_by_user_id = SPN` instead of the human
5. Browser (which resolves to human SCIM ID `1081964970114387@...`) can't see these projects

**Result:** 55 iOS-created projects are invisible in the browser UI.

---

## Required iOS Fix

**All endpoints under `/api/v1/` require Layer 2 headers when called from iOS.**

Every iOS request to any of these endpoints MUST include:
- `X-Lakeloom-Session-Token` (the session token from QR pairing)
- `X-Lakeloom-Timestamp` (unix seconds)
- `X-Lakeloom-Signature` (ECDSA P-256 DER, base64url)

This is the same pattern already used by `CaptureService` (POST/PATCH captures) and `UploadService` (audio/screenshots/photos/documents). `ProjectService` needs to follow suit.

### Affected iOS endpoints (all use `dualAuth`):

| Method | Path | iOS Usage |
| --- | --- | --- |
| GET | `/api/v1/projects` | List projects |
| GET | `/api/v1/projects/:id` | Fetch single project |
| POST | `/api/v1/projects` | Create project |
| PATCH | `/api/v1/projects/:id` | Edit name/description |
| PATCH | `/api/v1/projects/:id/archive` | Archive project |
| PATCH | `/api/v1/projects/:id/restore` | Restore project |
| POST | `/api/v1/projects/:id/devices` | Associate device |
| GET | `/api/v1/projects/:id/devices` | List assigned devices |
| PATCH | `/api/v1/captures/:id/state` | Transition state (v1 path) |
| PATCH | `/api/v1/captures/:id/label` | Update label (new) |
| GET | `/api/captures/:id` | Capture detail |
| GET | `/api/projects/:pid/captures` | List captures for project |

### Endpoints already correct (use `iosAuth` directly):

| Method | Path | Status |
| --- | --- | --- |
| POST | `/api/projects/:pid/captures` | ✅ `iosOnly` |
| PATCH | `/api/captures/:id` | ✅ `iosOnly` |
| POST | `/api/captures/:id/audio` | ✅ `iosOnly` |
| POST | `/api/captures/:id/screenshots` | ✅ `iosOnly` |
| POST | `/api/captures/:id/photos` | ✅ `iosOnly` |
| POST | `/api/projects/:pid/documents` | ✅ `iosOnly` |
| POST | `/api/sessions/:id/events` | ✅ `iosAuth` |
| POST | `/api/pairing/confirm` | ✅ `iosAuth` |

---

## Why This Happened

`dualAuth` was designed for endpoints callable from BOTH iOS and browser. The assumption was that iOS would always send Layer 2 headers. But `ProjectService` on iOS was implemented to use only the M2M token — likely because project CRUD felt like a "basic" operation that didn't need the full auth chain.

The distinction matters because `dualAuth` uses header detection:
```
if (X-Lakeloom-Session-Token present) → iosAuth → resolves human from paired_sessions
else → browserAuth → uses X-Forwarded-User header directly
```

Without the session token header, the request looks like a "browser" request to `dualAuth`, and `X-Forwarded-User` contains the SPN identity (the M2M token's subject).

---

## Data Remediation

Genie will run a one-time Lakebase migration to reassign the 55 affected projects:
```sql
UPDATE app.projects
SET created_by_user_id = '1081964970114387@7474657291520070',
    created_by_username = 'matthew.giglia@databricks.com'
WHERE created_by_user_id = '71833269206346@7474657291520070';
```

This will be applied server-side. No iOS action needed for the data fix.

---

## Verification

After the iOS fix ships:
1. Create a project from iOS
2. Check `created_by_user_id` in Lakebase — should be `1081964970114387@...`
3. Verify project appears in browser UI
4. Verify `GET /api/v1/projects` from iOS returns all projects (including browser-created ones)

---

## Timeline

- **Blocking:** iOS-created projects are invisible in browser now
- **Genie:** Data remediation deployed today (migration + verify)
- **Isaac:** Ship Layer 2 on ProjectService in next iOS build
