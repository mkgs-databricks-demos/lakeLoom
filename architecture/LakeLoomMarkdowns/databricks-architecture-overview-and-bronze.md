# Lakeloom — Databricks Architecture: Overview and ZeroBus Target Table

**Product:** Lakeloom
**Version:** 1.0
**Status:** Design — pre-implementation
**Last updated:** 2026-05-02
**Companion to:** `ios-app-architecture.md` (the iOS side)

---

## 1. Project Overview — Databricks Side

The Lakeloom iOS app captures conversations and streams structured records to Databricks via ZeroBus. This document covers what happens after the records arrive: how they are landed, processed, refined, and ultimately turned into actionable build artifacts (requirements, reference architectures, phased Genie Code session plans) by an Agent.

This is the first architecture document for the Databricks side. It establishes the overall pipeline shape and drills into the **ZeroBus target table** specifically — the bronze landing zone that all downstream processing depends on.

Subsequent documents will cover silver/gold transformations, the Spark Declarative Pipeline definition, the Agent's design, and the Genie Code session plan generation.

---

## 2. End-to-End Flow

```
┌─────────────┐     ┌──────────┐     ┌──────────────────────────────────┐
│  iOS App    │────►│ ZeroBus  │────►│  Bronze: transcript_events_raw   │
│  (Capture)  │     │ Ingestion│     │  (this document's focus)         │
└─────────────┘     └──────────┘     └──────────┬───────────────────────┘
                                                │
                                                ▼
                              ┌──────────────────────────────────────────┐
                              │  Spark Declarative Pipeline              │
                              │  (silver layer)                          │
                              │  • dedup by record_uuid                  │
                              │  • parse VARIANT into typed columns      │
                              │  • join audio_uploaded events to chunks  │
                              │  • assemble per-session views            │
                              └──────────┬───────────────────────────────┘
                                         │
                                         ▼
                              ┌──────────────────────────────────────────┐
                              │  Gold layer                              │
                              │  • session_summary                       │
                              │  • session_transcript_full               │
                              │  • project_knowledge_base                │
                              └──────────┬───────────────────────────────┘
                                         │
                                         ▼
                              ┌──────────────────────────────────────────┐
                              │  Agent                                   │
                              │  • requirements generation               │
                              │  • reference architecture generation     │
                              │  • Genie Code phased session plans       │
                              └──────────┬───────────────────────────────┘
                                         │
                                         ▼
                              ┌──────────────────────────────────────────┐
                              │  Outputs (per project):                  │
                              │  • Markdown requirements docs            │
                              │  • Architecture diagrams (Mermaid)       │
                              │  • Phased build session plans (JSON)     │
                              │  • Genie Code workspace setup            │
                              └──────────────────────────────────────────┘
```

Each layer has a clear responsibility and a clear contract to the next.

---

## 3. Architectural Principles for the Databricks Side

1. **Bronze is immutable, append-only, raw.** The ZeroBus target table receives whatever the iOS app sends, with no transformation. Schema is stable; semantics live in silver.
2. **VARIANT for variability, typed columns for stability.** Top-level identifiers, timestamps, and enums are strongly typed. Headers and payload are VARIANT — flexible enough to evolve without table migrations.
3. **Idempotent processing throughout.** The iOS outbox is at-least-once; the silver layer dedupes on `record_uuid`. Re-processing the same bronze row produces the same silver state.
4. **Forward-compatible schema versioning.** Every record carries `schema_version`. The pipeline branches on version. Old data remains queryable forever.
5. **Audio is referenced, not stored in the table.** Audio bytes live in Unity Catalog Volumes. The bronze table records the URI; silver joins to the volume metadata when needed.
6. **Per-workspace isolation, per-project access control.** Unity Catalog grants govern who can read/write what. The data model is multi-tenant by `workspace_id`.
7. **Sessions are the unit of analysis.** Bronze rows are events; silver assembles them into sessions; gold organizes sessions into project knowledge.
8. **Separation of "what was said" from "what we do with it."** Silver/gold are evidence — pure derivations from captured material. The Agent operates on gold and produces interpretations; interpretations live in their own gold tables, clearly labeled.
9. **Time travel and audit are first-class.** Delta time travel covers correctness investigations; audit columns (ingest timestamps, processing timestamps) cover provenance.
10. **The pipeline is explainable.** Every silver/gold row can be traced back to its source bronze rows via record_uuids and processing metadata.

---

## 4. The Medallion Layout

### 4.1 Bronze (this document)

A single table: `transcript_events_raw`. Receives all ZeroBus records — transcript chunks, session lifecycle events, and audio_uploaded events — across all workspaces, projects, and users. Append-only. Partitioned for efficient scans.

### 4.2 Silver (next document)

Multiple tables derived from bronze:
- `transcript_events` — deduped, typed columns extracted from variant
- `sessions` — one row per session, lifecycle stitched together
- `session_chunks` — chunks ordered within session, with audio reference enriched
- `session_transcripts` — concatenated transcript per session
- `audio_files` — audio metadata joined from audio_uploaded events + Volume listing

### 4.3 Gold (third document)

Project-oriented aggregates:
- `project_knowledge_base` — all session content for a project, organized for Agent consumption
- `session_summary` — auto-summarized content per session
- `project_topics` — topic clustering across a project's sessions

### 4.4 Agent Outputs (fourth document)

Per-project artifacts produced by the Agent:
- `project_requirements` — versioned requirements docs
- `project_architecture` — reference architectures with Mermaid diagrams
- `project_session_plans` — phased Genie Code session plans

These are also Delta tables (versioned, queryable) but their content is generated, not derived.

---

## 5. Catalog and Schema Layout

### 5.1 Naming Convention

```
{catalog}.{schema}.{table}
```

Default for v1:

```
main.lakeloom.transcript_events_raw
main.lakeloom.transcript_events
main.lakeloom.sessions
main.lakeloom.session_chunks
main.lakeloom.session_transcripts
main.lakeloom.audio_files
main.lakeloom.project_knowledge_base
main.lakeloom.session_summary
main.lakeloom.project_topics
main.lakeloom.project_requirements
main.lakeloom.project_architecture
main.lakeloom.project_session_plans
main.lakeloom.projects                  -- read/written by iOS app
```

### 5.2 Volume

Audio files live in a Unity Catalog Volume:

```
/Volumes/main/lakeloom/session_audio/
```

Path layout per file (set by iOS StorageService):

```
/Volumes/main/lakeloom/session_audio/{yyyy}/{mm}/{dd}/{session_id}.opus
```

### 5.3 Per-Customer / Multi-Tenant Considerations

For v1, all customers share `main.lakeloom`. Workspace isolation is enforced by Unity Catalog grants and by `workspace_id` filtering in every silver/gold view.

For larger deployments, the catalog could become per-customer (`acme_lakeloom.lakeloom.*`), with a per-catalog deployment of the pipeline. This is a forward-looking option, not a v1 decision.

### 5.4 Permissions Model (v1)

| Principal | Catalog | Schema | Table | Privilege |
|---|---|---|---|---|
| iOS app users (group) | main | lakeloom | projects | SELECT, INSERT, UPDATE |
| iOS app users (group) | main | lakeloom | transcript_events_raw | INSERT (via ZeroBus) |
| iOS app users (group) | main | session_audio (volume) | — | WRITE |
| Pipeline service principal | main | lakeloom | * | ALL |
| Agent service principal | main | lakeloom | (gold tables) | SELECT |
| Agent service principal | main | lakeloom | (agent output tables) | ALL |
| Workspace admins | main | lakeloom | * | ALL |
| Solutions architects | main | lakeloom | (gold + agent outputs) | SELECT |

iOS app users get **only** what they need: write to bronze, read/write the projects table, write audio to the volume. They do not see other users' data because silver/gold access is gated.

---

## 6. The Bronze Target Table — `transcript_events_raw`

### 6.1 Purpose

The single landing point for everything ZeroBus delivers from the iOS app. Designed for:

- **High write throughput** — many events per session, many sessions per minute at scale
- **Schema stability** — VARIANT absorbs application-level evolution
- **Fast partition scans** — silver pipeline reads recent windows
- **Long retention** — bronze is the source of truth; nothing is deleted

### 6.2 Full DDL

```sql
CREATE TABLE main.lakeloom.transcript_events_raw (
  -- ============================================================
  -- TYPED TOP-LEVEL COLUMNS — set by the iOS app
  -- ============================================================

  record_uuid             STRING       NOT NULL COMMENT 'UUIDv7 generated on device; primary dedup key',
  session_id              STRING       NOT NULL COMMENT 'UUIDv7 grouping all records of one capture session',
  project_id              STRING       NOT NULL COMMENT 'FK to main.lakeloom.projects',
  workspace_id            STRING       NOT NULL COMMENT 'Databricks workspace ID',
  username                STRING       NOT NULL COMMENT 'Databricks SCIM userName, typically email',
  user_uuid               STRING       NOT NULL COMMENT 'Databricks SCIM user id (stable across renames)',

  device_timestamp        TIMESTAMP    NOT NULL COMMENT 'When the chunk was finalized on device, microsecond precision',
  chunk_start_offset_ms   BIGINT       NOT NULL COMMENT 'Milliseconds from session start to chunk start',
  chunk_end_offset_ms     BIGINT       NOT NULL COMMENT 'Milliseconds from session start to chunk end',

  capture_mode            STRING       NOT NULL COMMENT 'quick_capture | meeting',
  sequence_number         INT          NOT NULL COMMENT 'Monotonic per session, for gap detection',
  event_type              STRING       NOT NULL COMMENT 'transcript_chunk | session_start | session_end | audio_uploaded',
  schema_version          STRING       NOT NULL COMMENT 'Semver, e.g. 1.0.0',

  -- ============================================================
  -- VARIANT FIELDS — application-level structured data
  -- ============================================================

  headers                 VARIANT      NOT NULL COMMENT 'device, user, workspace, project, session, transcription, network metadata',
  payload                 VARIANT      NOT NULL COMMENT 'event-type-specific content',

  -- ============================================================
  -- INGESTION METADATA — set by ZeroBus
  -- ============================================================

  ingest_timestamp        TIMESTAMP    NOT NULL COMMENT 'Set by ZeroBus on receipt; UTC',
  ingest_date             DATE         GENERATED ALWAYS AS (CAST(ingest_timestamp AS DATE))
                                       COMMENT 'Generated partition column'

)
USING DELTA
PARTITIONED BY (ingest_date)
CLUSTER BY (workspace_id, session_id, sequence_number)
TBLPROPERTIES (
  'delta.enableChangeDataFeed'        = 'true',
  'delta.columnMapping.mode'          = 'name',
  'delta.feature.allowColumnDefaults' = 'supported',
  'delta.feature.variantType-preview' = 'supported',
  'delta.minReaderVersion'            = '3',
  'delta.minWriterVersion'            = '7',
  'delta.deletedFileRetentionDuration' = 'interval 30 days',
  'delta.logRetentionDuration'         = 'interval 90 days',
  'delta.tuneFileSizesForRewrites'    = 'true',

  -- Application metadata
  'app.owner'             = 'lakeloom-team',
  'app.purpose'           = 'Bronze landing zone for iOS-captured transcript events',
  'app.schema_version'    = '1.0.0',
  'app.created_for_app_version' = '1.0.0'
)
COMMENT 'Bronze landing zone for transcript events streamed from the Lakeloom iOS app via ZeroBus.

Each row is one event from a capture session: a transcript chunk, a session lifecycle marker, or an audio upload acknowledgement. Records are append-only and at-least-once delivered.

Downstream consumers should read via the silver views, which dedup on record_uuid and parse VARIANT fields into typed columns. Direct queries against this table are appropriate for debugging and for CDC streaming.';
```

### 6.3 Why These Choices

#### Top-level columns vs. VARIANT

Promoted to typed columns:
- Anything used in WHERE clauses by the silver pipeline (workspace_id, session_id, event_type)
- Anything needed for ordering (sequence_number, device_timestamp)
- Anything that defines the row's identity or routing (record_uuid, project_id)

Left in VARIANT:
- Device metadata (model, OS version) — useful but not query-critical
- App version, locale, timezone — diagnostic
- Per-event-type details — vary by event_type and evolve over time
- Anything the iOS app might add later without coordinated table migration

This split is deliberate: the typed surface is a contract; VARIANT is a flex zone. We can add fields to VARIANT freely; promoting a VARIANT field to typed requires coordination.

#### Partitioning by `ingest_date`

Partitioning on the date a record arrives (not the device timestamp) ensures:
- Recent records cluster together — the silver pipeline's incremental window benefits
- Out-of-order arrivals (e.g., a record sent days late from offline outbox) land in the partition for *now*, not for *when it was captured*. This makes incremental processing correct without complex watermark logic.

`device_timestamp` is also a candidate for partitioning, but the operational realities favor ingest time: stragglers happen, and we want them processed when they arrive, not when they were captured. Silver-layer queries can still filter on device_timestamp for time-of-event analysis.

#### Liquid Clustering on `(workspace_id, session_id, sequence_number)`

`CLUSTER BY` (Liquid Clustering) is preferred over `PARTITIONED BY` for these dimensions because:
- A session has all its events near each other on disk, so silver's "all events for session X" query is fast
- workspace_id is the multi-tenant boundary; clustering colocates a workspace's data
- sequence_number ordering means in-partition reads are also in-order, which helps streaming consumers

We can't `PARTITION BY (workspace_id)` in addition to ingest_date because Delta supports a single partition strategy. Liquid Clustering layers on top.

#### `delta.enableChangeDataFeed = true`

The silver pipeline reads bronze incrementally. CDF gives us efficient "what's new since last checkpoint" semantics with `_change_type` markers. This is the cleanest way to implement incremental Spark Declarative Pipeline reads.

#### `delta.columnMapping.mode = 'name'`

Future-proofs the table. Renames and reorderings work without rewriting data.

#### File size and retention tuning

- `tuneFileSizesForRewrites = true` — Delta automatically targets file sizes appropriate for the table's write pattern (lots of small writes from ZeroBus → larger files after compaction)
- `deletedFileRetentionDuration = 30 days` — supports time travel for 30 days
- `logRetentionDuration = 90 days` — keeps Delta log entries for 90 days for audit

#### Generated partition column

`ingest_date` is generated from `ingest_timestamp`. This means the iOS app and ZeroBus don't have to worry about computing the partition value — Delta does. ZeroBus writes `ingest_timestamp`, Delta writes the partition column.

---

## 7. Schema Variant Definitions

Even though VARIANT is schemaless at the table level, the iOS app populates known shapes. Documenting them here is the contract between iOS and the silver pipeline.

### 7.1 `headers` Variant

Common across all event types:

```json
{
  "device": {
    "model": "iPhone16,2",
    "os_version": "26.1",
    "app_version": "1.0.0",
    "app_build": "142",
    "locale": "en-US",
    "timezone": "America/Los_Angeles"
  },
  "user": {
    "user_uuid": "1234567890123456",
    "username": "jhammond@acme.com",
    "display_name": "Jeff Hammond",
    "auth_method": "oauth_u2m"
  },
  "workspace": {
    "workspace_id": "1234567890123456",
    "workspace_url": "https://acme-prod.cloud.databricks.com",
    "workspace_name": "ACME Production",
    "workspace_region": "us-west-2",
    "cloud": "aws",
    "selected_at": "2026-05-02T18:14:18.220Z"
  },
  "project": {
    "project_id": "proj_01975e4f3a7c",
    "project_name": "Customer 360 Lakehouse",
    "project_created_at": "2026-04-20T14:00:00.000Z"
  },
  "session": {
    "started_at": "2026-05-02T18:14:22.331Z",
    "capture_mode": "quick_capture",
    "expected_audio_upload": true,
    "audio_format": "opus",
    "audio_sample_rate": 16000,
    "consent_acknowledged_at": "2026-05-02T18:14:20.110Z",
    "consent_version": "1.0"
  },
  "transcription": {
    "engine": "SpeechTranscriber",
    "engine_version": "iOS26.1",
    "model_locale": "en-US",
    "on_device": true
  },
  "network": {
    "connection_type": "wifi",
    "is_constrained": false
  }
}
```

### 7.2 `payload` Variant — `event_type = 'transcript_chunk'`

```json
{
  "event_type": "transcript_chunk",
  "transcript": {
    "text": "We need to land customer events in Unity Catalog with a CDC pattern off the operational Postgres.",
    "is_final": true,
    "confidence": 0.94,
    "language_detected": "en-US"
  },
  "speakers": [
    {
      "speaker_label": "user",
      "start_offset_ms": 0,
      "end_offset_ms": 6420,
      "confidence": 1.0,
      "diarization_source": "capture_mode_inferred"
    }
  ],
  "audio_reference": {
    "session_audio_pending": true,
    "chunk_start_in_audio_ms": 12340,
    "chunk_end_in_audio_ms": 18760
  },
  "vad": {
    "trigger_reason": "user_release",
    "silence_duration_ms": null,
    "energy_floor_db": -52.3
  },
  "context": {
    "prior_chunk_uuid": "01975e4f-3a7c-7890-b1c2-d4e5f6a7b8c9",
    "prior_chunk_tail": "...so given the schema we discussed,"
  },
  "annotations": {
    "user_marked_important": false,
    "user_tag": null
  }
}
```

### 7.3 `payload` Variant — `event_type = 'session_start'`

```json
{
  "event_type": "session_start",
  "expected_chunks_estimate": null,
  "device_battery_level": 0.78,
  "device_thermal_state": "nominal"
}
```

### 7.4 `payload` Variant — `event_type = 'session_end'`

```json
{
  "event_type": "session_end",
  "total_duration_ms": 47820,
  "total_chunks": 1,
  "audio_upload_intent": "pending",
  "termination_reason": "user_stop"
}
```

`audio_upload_intent`: `pending` | `none` | `failed_local`
`termination_reason`: `user_stop` | `user_release` | `app_backgrounded` | `interrupted` | `error`

### 7.5 `payload` Variant — `event_type = 'audio_uploaded'`

```json
{
  "event_type": "audio_uploaded",
  "audio_uri": "/Volumes/main/lakeloom/session_audio/2026/05/02/01975e4f-3a7c-7890-b1c2-d4e5f6a7b8c9.opus",
  "audio_duration_ms": 47820,
  "audio_size_bytes": 384512,
  "audio_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "uploaded_at": "2026-05-02T19:02:14.110Z",
  "upload_duration_ms": 1840,
  "upload_network": "wifi"
}
```

### 7.6 Variant Field Access in SQL

Querying the variant fields uses Databricks' VARIANT functions:

```sql
-- Get the transcript text from a chunk
SELECT
  record_uuid,
  variant_get(payload, '$.transcript.text', 'STRING') AS transcript_text,
  variant_get(payload, '$.transcript.confidence', 'DOUBLE') AS confidence
FROM main.lakeloom.transcript_events_raw
WHERE event_type = 'transcript_chunk'
  AND session_id = '01975e4f-...'
ORDER BY sequence_number;

-- Get the device model
SELECT
  workspace_id,
  variant_get(headers, '$.device.model', 'STRING') AS device_model,
  COUNT(*) AS event_count
FROM main.lakeloom.transcript_events_raw
WHERE ingest_date >= current_date() - INTERVAL 7 DAYS
GROUP BY workspace_id, device_model;
```

The silver pipeline does this extraction once and writes typed columns to the silver table, so most queries don't need `variant_get`.

---

## 8. Write Path — How Records Land

### 8.1 ZeroBus Write Stream

The iOS app's gRPC client opens a streaming write to ZeroBus. Each record carries:

- All NOT NULL top-level columns
- `headers` and `payload` as JSON strings (Variant ingestion typically accepts JSON-string input which Databricks parses to VARIANT on write)
- Does **not** carry `ingest_timestamp` or `ingest_date` — both are server-set

ZeroBus performs minimal validation:
- All NOT NULL columns are present and non-null
- `event_type` is one of the four known values
- `schema_version` matches a registered version (initially `1.0.0`)
- VARIANT JSON parses

Validation failures return gRPC `INVALID_ARGUMENT`; the iOS outbox dead-letters those records.

### 8.2 Delivery Semantics

ZeroBus is at-least-once. Duplicates are inevitable under retry. The bronze table accepts duplicates without error; silver dedupes.

**Why not enforce uniqueness on `record_uuid` at the bronze level?** Because:
- Delta doesn't enforce unique constraints at write time
- Even if it did, MERGE-on-write adds latency that defeats the streaming use case
- Silver dedup is cheap (a window function) and correct

### 8.3 Schema Evolution Path

When the iOS app adds a new field:

| Change type | Action |
|---|---|
| Add a field inside `headers` or `payload` VARIANT | No table change. iOS bumps `schema_version` minor. Silver branches on version when interpreting. |
| Add a new top-level column | Coordinated change: `ALTER TABLE ADD COLUMN` first, then iOS app and ZeroBus IDL updated. Old iOS clients keep working (they don't write the new column; it's NULL). |
| Rename a top-level column | Avoided. Use VARIANT or add new column + deprecate old. |
| Change a top-level column's type | Treat as breaking. Bump major schema_version. Add new typed column; deprecate old. |
| Add a new event_type | No schema change. iOS emits new event_type; silver pipeline learns to route it. |

The lesson: typed column changes are coordinated; VARIANT changes are unilateral. We bias toward VARIANT for application-level evolution.

---

## 9. Read Patterns

### 9.1 Silver Pipeline (Primary Consumer)

The Spark Declarative Pipeline reads bronze incrementally via Change Data Feed:

```sql
SELECT *
FROM table_changes('main.lakeloom.transcript_events_raw',
                   :start_version, :end_version)
WHERE _change_type = 'insert'
```

Or, equivalently, via Auto Loader-style cloudFiles — but CDF is more native to Delta and gives exactly-once semantics with checkpointing.

### 9.2 Operational Queries

Common operational patterns documented for support engineers:

#### "What did session X look like in the last hour?"

```sql
SELECT
  record_uuid,
  event_type,
  sequence_number,
  device_timestamp,
  ingest_timestamp,
  variant_get(payload, '$.transcript.text', 'STRING') AS text,
  variant_get(payload, '$.event_type', 'STRING') AS lifecycle_event_type
FROM main.lakeloom.transcript_events_raw
WHERE session_id = '01975e4f-...'
ORDER BY sequence_number;
```

#### "How much data is workspace X producing?"

```sql
SELECT
  workspace_id,
  ingest_date,
  COUNT(DISTINCT session_id) AS sessions,
  COUNT(*) AS events,
  COUNT_IF(event_type = 'transcript_chunk') AS chunks,
  COUNT_IF(event_type = 'audio_uploaded') AS audio_uploads
FROM main.lakeloom.transcript_events_raw
WHERE ingest_date >= current_date() - INTERVAL 30 DAYS
GROUP BY workspace_id, ingest_date
ORDER BY ingest_date DESC;
```

#### "What schema versions are in flight?"

```sql
SELECT
  schema_version,
  COUNT(DISTINCT workspace_id) AS workspaces,
  COUNT(*) AS events,
  MIN(ingest_timestamp) AS earliest,
  MAX(ingest_timestamp) AS latest
FROM main.lakeloom.transcript_events_raw
WHERE ingest_date >= current_date() - INTERVAL 7 DAYS
GROUP BY schema_version;
```

### 9.3 Don't Query Bronze for Application Logic

Application reads (Sessions list display, transcript reconstruction) go through silver views. Bronze is for ingestion plumbing, debugging, and audit. The silver pipeline materializes everything an application would want.

---

## 10. Operational Concerns

### 10.1 Sizing and Cost

Per session, expected event counts:
- Quick Capture: ~3 records (session_start, 1 chunk, session_end, optionally + audio_uploaded = 4)
- Meeting Mode (future): ~15-30 chunks for a 10-15 minute meeting + 3 lifecycle = ~20-35 records

Per record size (JSON-encoded for ZeroBus):
- transcript_chunk: ~1–4 KB depending on transcript length
- session_start, session_end: ~500 bytes
- audio_uploaded: ~600 bytes

Storage estimate for 1000 active users at 5 sessions/day, average 10 chunks per session:
- 50,000 sessions/day × 13 records/session ≈ 650K records/day
- ≈ 1.5 GB/day uncompressed → ~300 MB/day after Delta compression
- ≈ 110 GB/year

Cheap by Databricks standards. Compute cost dominated by silver/gold processing, not bronze storage.

### 10.2 Retention

Bronze retention: **forever** for v1. The volume is low and the value of replayability is high. Revisit if costs become material.

If retention becomes necessary:
- Time-based deletion via `DELETE FROM ... WHERE ingest_date < ...`
- VACUUM to reclaim storage
- Document the policy and apply uniformly

### 10.3 Backfill and Reprocessing

If the silver pipeline is broken and reprocessing is needed:
- Stream from a specific Delta version: `STREAMING TABLE ... AS SELECT * FROM STREAM(... WHERE _commit_version >= N)`
- Or full reprocess: drop silver tables, replay bronze from beginning, idempotent dedup ensures correctness

This is why bronze is immutable and append-only: replays are always safe.

### 10.4 Observability

Key metrics to monitor (via Databricks Lakehouse Monitoring or a custom dashboard):

| Metric | Threshold | Why |
|---|---|---|
| Records inserted per minute | >0 during business hours | Confirms ZeroBus is working |
| Distinct workspace_ids active per day | (varies) | Customer engagement signal |
| Records with schema_version < current | <5% | Migration health |
| Records where session_start has no matching session_end (1h window) | <2% | Session completeness |
| Audio_uploaded records as % of session_end with intent=pending | >95% within 7 days | Wi-Fi gating not stuck |
| Average ingest_timestamp - device_timestamp | <30 minutes typical | Outbox health |

Alerts route to the `lakeloom-team` channel.

### 10.5 Disaster Recovery

Bronze is the source of truth. As long as the bronze table and the audio Volume survive, everything downstream can be recomputed.

Backup strategy:
- Delta time travel covers 30 days (deletedFileRetentionDuration)
- Periodic deep clones to a DR region for catastrophic recovery: `CREATE TABLE ... DEEP CLONE ...` weekly

---

## 11. Validation Strategy

The bronze table is permissive. Validation happens at two layers:

### 11.1 Wire-Level (ZeroBus)

What ZeroBus enforces:
- All NOT NULL columns present
- VARIANT fields parse as JSON
- `event_type` ∈ enumerated values
- `schema_version` is a registered value

This is fast, fails the iOS write immediately, and the iOS outbox dead-letters.

### 11.2 Silver-Level (Pipeline)

What silver enforces:
- `record_uuid` uniqueness (dedup)
- `sequence_number` monotonicity within session
- Reference integrity: every transcript_chunk has a session_start with the same session_id (eventually; tolerates out-of-order arrival)
- Variant field shape conformance per `schema_version`

Failures route to a quarantine table (`silver_quarantine`) with reason codes. Operational dashboards surface quarantine rates.

### 11.3 No CHECK Constraints in Bronze

Tempting to add `CHECK (event_type IN (...))` etc. Avoided because:
- ZeroBus already validates
- CHECK constraints reject writes; we'd rather land everything and quarantine bad data in silver
- Schema evolution (new event_type) would require dropping/adding constraints

---

## 12. Out of Scope for This Document

- Silver pipeline implementation — separate document
- Gold layer schema — separate document
- Agent design — separate document
- Genie Code session plan generation — separate document
- ZeroBus configuration / table registration — operational doc
- Cross-region replication — operational concern, future
- Per-customer catalog deployment — future scaling option

---

## 13. Open Items

| # | Item | Resolution Path |
|---|---|---|
| 1 | Whether `workspace_id` should be the iOS app's discovered SCIM-derived ID or something simpler like the workspace host | Confirm during iOS implementation; bronze accepts whatever string the app sends |
| 2 | VARIANT preview feature dependency — verify the target Databricks runtime version supports it | Check the latest DBR LTS; fall back to `STRING` JSON if unavailable, with `parse_json()` in silver |
| 3 | ZeroBus IDL specifics — exact proto field numbers and wire format | Get the proto file from Databricks, align iOS gRPC client and silver schema |
| 4 | Whether `ingest_date` partitioning at daily granularity is right vs hourly | v1: daily. Revisit if scale warrants hourly. |
| 5 | Whether to enable Delta UniForm (Iceberg compatibility) on bronze | v1: no. Add later if external readers require it. |
| 6 | Liquid Clustering vs Z-Order on `workspace_id, session_id, sequence_number` | v1: Liquid Clustering (auto-tuning). Z-ORDER as fallback if clustering unsupported on the runtime. |
| 7 | Catalog choice — `main` vs a dedicated `lakeloom` catalog | v1 default: `main.lakeloom`. Forward-compatible to dedicated catalog later. |
| 8 | Whether to require a per-workspace approval / governance gate before iOS app can write | Out of scope; governance lives in workspace OAuth app config and UC grants |
| 9 | Schema registration mechanism — Delta tags, a registry table, or just docs | v1: Delta TBLPROPERTIES carry the version. Add registry table in v1.x if useful. |

---

## 14. What's Next

Following documents will cover:

1. **Silver pipeline** — Spark Declarative Pipeline reading bronze, dedup, VARIANT parsing, session assembly
2. **Gold layer** — project knowledge base, session summaries, topic clustering
3. **Agent design** — how the LLM agent consumes gold and produces requirements, architecture, and Genie Code session plans
4. **Genie Code session plan format** — the JSON schema and execution semantics for phased build sessions

Each will reference back to this document for the bronze contract.
