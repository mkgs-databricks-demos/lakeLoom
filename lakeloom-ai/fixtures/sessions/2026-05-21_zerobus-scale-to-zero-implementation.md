# 2026-05-21 — ZeroBus Scale-to-Zero Stream Pool Implementation

## Summary

Rewrote the ZeroBus stream pool service from a fixed-size static pool (16 streams, always open) to an adaptive scale-to-zero architecture. Added Lakebase event persistence, health/diagnostics endpoints, and a validation notebook. Modeled after dbxW_zerobus_app best practices.

## Problem

The original `zerobus-service.ts` opened 16 gRPC streams on first request and kept them open forever — wasteful for lakeLoom's bursty usage pattern (short capture sessions with long idle periods between whiteboard meetings).

## Solution: Scale-to-Zero Pool

| State | Behavior |
|-------|----------|
| Cold (0 streams) | Request arrives → wake to 1 stream (~200-500ms) |
| Warm (1 stream) | Load increases → scale up by 1 |
| Hot (N streams) | Sustained idle → scale down by 1 |
| Warm (1 stream) | 20 min idle → scale to zero |

### Key Design Decisions

1. **Scale step = 1** in both directions (dbxW uses +2/-1)
2. **Scale-to-zero** with 20-minute idle timeout at 1 stream (dbxW minimum is 2)
3. **Lazy initialization** — pool starts cold, wakes on first ingest request
4. **Class-based singleton** (adopted from dbxW) with encapsulated state
5. **In-flight tracking** enables both graceful shutdown and autoscale decisions
6. **Resize history ring buffer** (50 events) for in-memory diagnostics
7. **Lakebase persistence** — all pool lifecycle events written to `app.zerobus_pool_events`
8. **onResize callback** pattern decouples service from persistence layer

## Files Created

| File | Purpose |
|------|--------|
| `server/services/zerobus-service.ts` | Complete rewrite — ZeroBusService class with scale-to-zero |
| `server/services/zerobus-history-service.ts` | Fire-and-forget Lakebase persistence for resize events |
| `server/migrations/006_zerobus_pool_events.ts` | Lakebase table (BIGSERIAL PK, indexes, REPLICA IDENTITY FULL) |
| `server/routes/zerobus/zerobus-routes.ts` | `/api/zerobus/health`, `/history`, `/stats` endpoints |
| `src/tests/validate-zerobus-ingest.ipynb` | 11-cell validation notebook (auth, health, bronze table, history) |

## Files Modified

| File | Change |
|------|--------|
| `server/server.ts` | New imports (zeroBusService, setLakebaseClient, recordPoolEvent, setupZerobusRoutes), Lakebase binding after migrations, route registration, shutdown uses `.close()` |
| `server/migrations/migrate.ts` | Added migration006 to registry |
| `server/routes/events/event-routes.ts` | Uses new `zeroBusService.ingestRecord()`/`ingestBatch()` API |
| `resources/post_deploy_validation.job.yml` | Added `zerobus_validation` task (depends on `api_endpoint_tests`) with parameterized notebook |

## Build Fix

First deploy failed due to TypeScript `noUnusedParameters` error:
```
server/routes/zerobus/zerobus-routes.ts(108,42): error TS6133: 'req' is declared but its value is never read.
```
Fixed by renaming `req` → `_req` in the `/api/zerobus/stats` handler. Diagnosed via OTel logs table (`lakeloom_ai_otel_logs`, `app.log_source = 'BUILD'`).

## Auto-Scale Logic

```
Check interval: 5s
Cooldown between resizes: 10s
Scale-up trigger: peak in-flight ≥ stream count OR call rate ≥ stream count
Scale-down trigger: 3 consecutive idle checks (0 calls + 0 in-flight)
Scale-to-zero trigger: at 1 stream, 20 min since last activity
```

## Health Endpoint Response Shape

```json
{
  "status": "ok",
  "service": "zerobus-transcript-ingest",
  "env_configured": true,
  "target_table": "hls_fde_dev.dev_matthew_giglia_lakeloom.transcript_events_raw",
  "pool": { "active_streams": 0, "cold": true, "last_activity_at": null },
  "auto_scale": { "enabled": false, "max_size": 16, "idle_before_zero_ms": 1200000 },
  "resize_history_count": 0,
  "recent_resizes": []
}
```

## Validation Notebook Structure

1. SDK install + restart
2. Parameters (app_name, catalog, schema)
3. Audience-scoped token exchange (same pattern as pairing-api-test)
4. App health (`/healthz`)
5. ZeroBus health (`/api/zerobus/health`) — env, pool cold/warm, auto-scale
6. Event endpoint reachability (expects 401 from iOS auth)
7. Bronze table query (`transcript_events_raw`)
8. Pool event history (`/api/zerobus/history`)
9. Pool aggregate stats (`/api/zerobus/stats`)
10. Summary

## Post-Deploy Validation Job

Now runs 2 tasks sequentially:
1. `api_endpoint_tests` — pairing-api-test (existing)
2. `zerobus_validation` — validate-zerobus-ingest (new, depends on task 1)

Parameters injected from bundle variables: `${var.app_name}`, `${var.catalog}`, `${var.schema}`

## Reference: dbxW_zerobus_app Patterns Adopted

- Class-based singleton with encapsulated state
- `ensurePool()` with single-promise guard (prevents concurrent init)
- Stored credentials for `resize()` without re-reading env
- `poolStatus()` + `autoScaleStatus()` + `checkEnv()` diagnostic methods
- Drain-before-close shutdown (guarantees durability)
- `DRAIN_TIMEOUT_MS` + `DRAIN_POLL_INTERVAL_MS` constants
- Resize history ring buffer with trigger attribution
- Health endpoint exposing full operational state

## Next Steps

- Redeploy app with the TS6133 fix and validate
- Run the validation notebook to confirm all endpoints respond
- Monitor first iOS capture session to verify wake behavior
- Consider removing `@databricks/sdk-experimental` from package.json (no longer used since AppKit files plugin migration)
