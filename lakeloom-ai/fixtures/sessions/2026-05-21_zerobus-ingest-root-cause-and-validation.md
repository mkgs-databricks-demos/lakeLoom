# 2026-05-21 — ZeroBus Ingest Root Cause Fix & Full Validation

## Summary

Resolved the zero-write bug in ZeroBus ingest. Records were being silently dropped because `ingestRecordOffset()` received pre-stringified JSON (double-encoded) instead of plain objects. Fixed the type signatures and record construction. Validated with E2E, batch, and load tests — all 100% materialization, auto-scale to 3 streams confirmed.

## Root Cause

**Problem:** `event-routes.ts` called `JSON.stringify()` on each record object, then passed the resulting string to `zeroBusService.ingestRecord()`. The SDK wraps its argument in JSON for the wire protocol — so a pre-stringified record becomes double-encoded (`"\"{\\..\"}"`).

The ZeroBus server validates incoming records against the target table schema. A double-encoded string doesn't match any column types → **schema validation fails** → record silently dropped. The server still returns a valid offset (202 response), giving the false impression of success.

**Working pattern (from dbxW):**
```typescript
const record = { record_id: crypto.randomUUID(), body: JSON.stringify(payload), ... };
await stream.ingestRecordOffset(record); // Plain object
```

**Broken pattern (lakeLoom before fix):**
```typescript
const record = JSON.stringify({ record_id: randomUUID(), ... }); // String!
await zeroBusService.ingestRecord(record); // SDK double-encodes
```

## Fix Applied

| File | Change |
|------|--------|
| `server/routes/events/event-routes.ts` | Build records as plain objects; only `body` VARIANT column gets `JSON.stringify()` |
| `server/services/zerobus-service.ts` | Type signatures `string` → `unknown`; flush config (200 max inflight, 1000ms timeout); IngestMetrics tracking |
| `server/routes/zerobus/zerobus-routes.ts` | Health endpoint `ingest_metrics` section |
| `server/services/zerobus-history-service.ts` | `recordIngestMetrics()` + Lakebase persistence |
| `server/migrations/007_zerobus_ingest_metrics.ts` | DDL for `app.zerobus_ingest_metrics` |
| `server/server.ts` | Wire `onMetricsSnapshot` callback |

## Stream Configuration (Final)

```typescript
STREAM_MAX_INFLIGHT = 200;     // Backpressure trigger + auto-scale signal
STREAM_FLUSH_TIMEOUT_MS = 1000; // 1s guarantee even at low volume
```

Dual-purpose: at low volume (1 user), buffer never fills so timeout fires within 1s. At high volume (500+ users), buffer fills in <150ms triggering immediate batch commit.

## Validation Results (Full Test Suite)

| Test | Result |
|------|--------|
| 1. App health (`/healthz`) | PASS |
| 2. ZeroBus health (`/api/zerobus/health`) | PASS |
| 3. Event endpoint reachability | PASS (401 = iOS auth working) |
| 3.5. Full E2E ingest (iOS pair + ECDSA sign) | PASS — 202 in 42ms |
| 3.6. Batch ingest (5 events, single POST) | PASS — 202 in 248ms |
| 3.7. Load test (100 events, 10 sequential batches) | PASS — 53 events/sec, all materialized |
| 4. Bronze table query | PASS — 312 rows, correct schema |
| 5. Pool event history | PASS — 20 events in Lakebase |
| 6. Pool aggregate stats | PASS — peak 3 streams |
| Teardown | PASS — all test records removed |

## Auto-Scale Behavior Observed

| Time | Event | Duration |
|------|-------|----------|
| 08:35:13 | scale-up 1→2 | 358ms |
| 08:35:38 | scale-up 2→3 | 228ms |
| 08:35:53 | scale-down 3→2 | 10ms |
| 08:36:08 | scale-down 2→1 | 0ms |
| 08:36:48 | scale-up 1→2 | 179ms |
| 08:37:03 | scale-down 2→1 | 0ms |

Lifetime stats: 33 lifecycle events, 6 wakes, 13 scale-ups, peak pool size 3, avg wake 503ms.

## Performance Characteristics

* **Throughput:** 53–178 events/sec (sequential vs concurrent batches)
* **Ack latency:** 67ms min / 188ms avg / 203ms p95
* **Flush to Delta:** <8s total (1s flush timeout + server-side commit)
* **Auto-scale:** 228–358ms per stream addition
* **Scale-down:** 15s idle (3 checks × 5s interval)
* **Wake from cold:** ~200–500ms

## Investigation Path (Dead Ends)

1. **DDL schema mismatch** — recreated table with ZeroBus-compatible schema (nullable columns, `record_id` PK, epoch microseconds). Not the issue.
2. **Flush timeout too long** — reduced from 5min to 1s. Not the issue (but kept for latency).
3. **Permissions** — SPN grants correct (MODIFY + SELECT). Not the issue.
4. **Flush config** — maxInflightRequests 10000→200. Not the issue (but kept for auto-scale).

## Notebook Updates

* Fixed Test 4 column references (`_server_received_at` → `ingested_at`, `_session_id` → `session_id`)
* Fixed load test from concurrent (ThreadPoolExecutor) to sequential — concurrent ECDSA signing with same key causes timestamp collision/replay detection
* Added Teardown cell: deletes by `session_id = PAIRED_SESSION_ID` + `body:load_test::boolean IS TRUE`
* Updated Summary cell with performance numbers
* `APP_BASE_URL` discovery uses canonical URL (`*.aws.databricksapps.com`); old proxy URL (`fevm-hls-fde.dev.databricks.com`) went stale after redeployment

## Key Learnings

1. ZeroBus SDK expects **plain objects** — it handles serialization internally
2. VARIANT columns get `JSON.stringify()` — all other fields are typed values
3. Schema validation is strict and **silent** on failure (no error, offset still returned)
4. `record_id` and `ingested_at` are **app-generated** (not server-generated)
5. Canonical app URL format: `https://{app-name}-{principal-id}.aws.databricksapps.com`
