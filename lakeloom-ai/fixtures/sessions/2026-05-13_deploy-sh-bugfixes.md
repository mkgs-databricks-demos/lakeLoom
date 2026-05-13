# 2026-05-13 deploy.sh Bugfixes

## Problems
`./deploy.sh --target dev --app` failed at multiple stages with cascading errors.

## Root Causes & Fixes

| # | Error | Root Cause | Fix |
|---|-------|-----------|-----|
| 1 | JSON parse error (char 0) in `resolve_infra_vars` | `2>&1` captured CLI stderr warnings into JSON variable | Changed to `2>/dev/null` (matches `resolve_app_name` pattern) |
| 2 | SyntaxError: unterminated f-string in `resolve_app_name` | `\\"` double-escaped — bash closed string prematurely | Fixed to `\"` (matches `resolve_infra_vars` pattern) |
| 3 | App status stuck at UNKNOWN for 300s | `databricks apps get --name` — `--name` flag doesn't exist; CLI uses positional args | Changed to `databricks apps get "${APP_NAME}"` (positional) |
| 4 | Still UNKNOWN after positional fix | API returns `compute_status.state: "ACTIVE"` not `status: "RUNNING"` | Rewrote `get_app_status()` to check `compute_status` first; added `is_compute_ready()` accepting ACTIVE/RUNNING |
| 5 | Invalid source code path (@ stripped) | `path_safe` regex `[^a-zA-Z0-9_.\-/]` excluded `@` from email in workspace path | Added `@` to allowed chars |

## Decisions
- `get_app_status()` checks fields in priority: `compute_status` > `status` > `app_status`
- `is_compute_ready()` helper accepts both ACTIVE (compute up, no source) and RUNNING (fully serving)
- All `apps get/start` commands use positional args (matching `apps deploy` which already did)

## Files Modified
- `/Users/matthew.giglia@databricks.com/lakeLoom/deploy.sh` (5 fixes)
