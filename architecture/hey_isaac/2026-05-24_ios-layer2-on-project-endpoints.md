# 2026-05-24 — iOS Must Send Layer 2 on ALL /api/v1/ Endpoints

## TL;DR

iOS's `ProjectService` is using only the M2M Bearer token (Layer 0) when calling `/api/v1/projects*` endpoints. This causes all iOS-created projects to be attributed to the Xcode SPN identity instead of the human user. **Fix: send Layer 2 headers on ALL `/api/v1/` calls, same as captures and uploads already do.**

**⚠️ BREAKING: The server now returns 401 for bare SPN requests.** After deploy, iOS project calls without Layer 2 headers will fail immediately with a clear error message. This is intentional — see "Server-Side Enforcement" below.

---

## Problem

When iOS calls project endpoints with only M2M (Layer 0):
1. The auth sidecar resolves the token to the **Xcode SPN's SCIM ID** (`71833269206346@7474657291520070`)
2. `dualAuth` sees no `X-Lakeloom-Session-Token`, falls through to `browserAuth`
3. `browserAuth` rejects — no `X-Forwarded-Email` header (SPNs never get email)
4. Projects were being created with `created_by_user_id = SPN` instead of the human
5. Browser (which resolves to human SCIM ID `1081964970114387@...`) couldn't see these projects

**Result:** 55 iOS-created projects were invisible in the browser UI.

---

## Server-Side Enforcement (deployed)

`browserAuth` now uses `X-Forwarded-Email` as the hard gate for human identity. The sidecar only sets this header for human browser sessions — SPNs only get `X-Forwarded-User`.

**Detection matrix:**

| Request has | Result |
| --- | --- |
| `X-Lakeloom-Session-Token` + Layer 2 headers | iosAuth → resolves human from `paired_sessions` ✅ |
| `X-Forwarded-Email` (human browser) | browserAuth → uses SCIM ID ✅ |
| Only `X-Forwarded-User` (SPN, no email) | **401 REJECTED** |
| Nothing | **401 REJECTED** |

**The 401 response body when SPN is detected:**
```json
{
  "type": "https://lakeloom/errors/unauthenticated",
  "title": "Unauthenticated",
  "status": 401,
  "detail": "Service principal identity detected without Layer 2 auth. iOS must send X-Lakeloom-Session-Token."
}
```

This means after next deploy, iOS will start getting 401s on any `/api/v1/` or `dualAuth` endpoint where Layer 2 headers are missing. The error message is actionable and tells you exactly what's wrong.

---

## Required iOS Fix

**All endpoints under `/api/v1/` require Layer 2 headers when called from iOS.**

Every iOS request to any of these endpoints MUST include:
- `X-Lakeloom-Session-Token` (the session token from QR pairing)
- `X-Lakeloom-Timestamp` (unix seconds)
- `X-Lakeloom-Signature` (ECDSA P-256 DER, base64url)

This is the same pattern already used by `CaptureService` (POST/PATCH captures) and `UploadService` (audio/screenshots/photos/documents). `ProjectService` needs to follow suit.

### Affected iOS endpoints (all use `dualAuth` — will 401 without Layer 2):

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

### Endpoints already correct (use `iosAuth` directly — no change needed):

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

`dualAuth` is designed for endpoints callable from BOTH iOS and browser. The contract requires:
- iOS → send Layer 2 headers (session token + timestamp + signature)
- Browser → sidecar provides human identity headers automatically

`ProjectService` was implemented with only M2M, likely because project CRUD felt like a "basic" operation. But without Layer 2, the server cannot distinguish the SPN from a human — and now explicitly refuses to try.

---

## Data Remediation

Genie deployed a one-time Lakebase migration (012) to reassign the 55 affected projects:
```sql
UPDATE app.projects
SET created_by_user_id = '1081964970114387@7474657291520070',
    created_by_username = 'matthew.giglia@databricks.com',
    updated_at = now()
WHERE created_by_user_id = '71833269206346@7474657291520070';
```

Auto-applies on next server restart. No iOS action needed for the data fix.

---

## Verification

After the iOS fix ships:
1. Create a project from iOS — should succeed (no 401)
2. Check `created_by_user_id` in Lakebase — should be `1081964970114387@...`
3. Verify project appears in browser UI
4. Verify `GET /api/v1/projects` from iOS returns all projects (including browser-created ones)
5. Verify the 401 error message is NOT seen in iOS logs

---

## Timeline

- **Deployed (server):** `browserAuth` now rejects bare SPN requests with 401
- **Deployed (server):** Migration 012 remediates 55 misattributed projects
- **Blocking Isaac:** iOS project calls will 401 until Layer 2 headers are added to `ProjectService`
- **Priority:** HIGH — project list/create from iOS is broken until fixed
