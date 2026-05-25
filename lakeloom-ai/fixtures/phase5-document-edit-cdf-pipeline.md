# Document Edit Ingestion — CDF on Lakebase Sync Table

> **Status:** Design (not yet implemented)  
> **Depends on:** Phase 5 pipeline work  
> **Author:** Genie Code  
> **Date:** 2026-05-25

---

## Problem

When a user edits a markdown document in the browser (via `PUT /api/media/:id/content`),
the file is overwritten in-place on the UC Volume. Auto Loader tracks files by path and
only processes **new** files — an in-place overwrite at the same path is invisible to it.

We need a mechanism that:
1. Detects that a document's content has changed
2. Re-reads the updated bytes from the volume
3. Triggers downstream reprocessing (re-embedding, re-indexing, summarization)

---

## Solution: CDF on `lb_uploads_history`

Lakehouse Sync already mirrors the Lakebase `app.uploads` table into Delta:

```
hls_fde_dev.dev_matthew_giglia_lakeloom.lb_uploads_history
```

When the `PUT /api/media/:id/content` endpoint fires, it updates columns in Lakebase:
- `size_bytes` (new file size after edit)
- `sha256_hex` (new content hash)
- `updated_at` (timestamp of edit)

Lakehouse Sync propagates this UPDATE to the Delta table. With **Change Data Feed (CDF)**
enabled on that table, a streaming pipeline can read only the changed rows.

---

## Architecture

```
┌─────────────┐    PUT /content    ┌──────────────┐    Lakehouse Sync    ┌─────────────────────┐
│   Browser   │ ──────────────────▶│   Lakebase   │ ───────────────────▶ │  lb_uploads_history │
│  (edit MD)  │                    │ app.uploads  │                      │     (Delta + CDF)   │
└─────────────┘                    └──────────────┘                      └──────────┬──────────┘
                                                                                    │
                                          ┌─────────────────────────────────────────┘
                                          │  readStream.option("readChangeFeed", "true")
                                          ▼
                                   ┌──────────────────┐
                                   │  SDP Bronze:     │
                                   │  document_edits  │
                                   │  (streaming tbl) │
                                   └────────┬─────────┘
                                            │
                                            ▼
                                   ┌──────────────────┐     read_files()     ┌───────────────┐
                                   │  SDP Silver:     │ ◀───────────────────▶│  UC Volume    │
                                   │  document_content│                      │  /documents/  │
                                   │  (enriched)      │                      └───────────────┘
                                   └────────┬─────────┘
                                            │
                                            ▼
                                   ┌──────────────────┐
                                   │  SDP Gold:       │
                                   │  document_embeds │
                                   │  (vector index)  │
                                   └──────────────────┘
```

---

## Implementation Steps

### Step 1: Enable CDF on lb_uploads_history

```sql
ALTER TABLE hls_fde_dev.dev_matthew_giglia_lakeloom.lb_uploads_history
SET TBLPROPERTIES (delta.enableChangeDataFeed = true);
```

> **Note:** Lakehouse Sync tables may already have CDF enabled by default.
> Verify with `DESCRIBE TABLE EXTENDED` before altering.

### Step 2: Add `updated_at` column to Lakebase (migration)

The `PUT /api/media/:id/content` endpoint should set `updated_at = NOW()` on each edit.
This gives the CDF stream a reliable change signal. Migration:

```sql
ALTER TABLE app.uploads ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ;
```

The PUT handler update:
```sql
UPDATE app.uploads
SET size_bytes = $1, sha256_hex = $2, updated_at = NOW()
WHERE id = $3;
```

### Step 3: SDP Bronze — `document_edits` streaming table

```python
from pyspark import pipelines as dp

@dp.table(
    name="document_edits",
    comment="CDC stream of document content changes from Lakebase sync"
)
@dp.expect_or_drop("has_volume_path", "volume_path IS NOT NULL")
def document_edits():
    return (
        spark.readStream
        .option("readChangeFeed", "true")
        .option("startingVersion", "latest")
        .table("hls_fde_dev.dev_matthew_giglia_lakeloom.lb_uploads_history")
        .filter("_change_type IN ('update_postimage', 'insert')")
        .filter("kind = 'document'")
        .select(
            "id",
            "kind",
            "mime_type",
            "original_filename",
            "volume_path",
            "size_bytes",
            "sha256_hex",
            "updated_at",
            "_commit_version",
            "_commit_timestamp",
            "_change_type",
        )
    )
```

### Step 4: SDP Silver — `document_content` (enriched with file bytes)

```python
from pyspark.sql import functions as F

@dp.table(
    name="document_content",
    comment="Document content re-read from volume on each edit"
)
def document_content():
    edits = spark.readStream.table("LIVE.document_edits")

    # For text types (markdown), read content as string
    # For binary types (PDF, images), read as raw bytes
    return (
        edits
        .withColumn("content_text",
            F.when(
                F.col("mime_type").isin("text/markdown"),
                F.expr("cast(read_files(volume_path, format => 'text') as STRING)")
            )
        )
        .withColumn("content_bytes",
            F.when(
                ~F.col("mime_type").isin("text/markdown"),
                F.expr("read_files(volume_path, format => 'binaryFile')")
            )
        )
        .withColumn("processed_at", F.current_timestamp())
    )
```

> **Alternative (simpler):** Use a foreachBatch approach if `read_files()` doesn't work
> cleanly in streaming context. Read the volume path per-row in a UDF.

### Step 5: SDP Gold — `document_embeddings` (for vector search)

```python
import mlflow

@dp.table(
    name="document_embeddings",
    comment="Chunked + embedded document content for vector search"
)
def document_embeddings():
    docs = spark.readStream.table("LIVE.document_content")

    # Chunk markdown into ~512 token segments
    # Embed with foundation model endpoint
    # Store chunk_id, document_id, chunk_text, embedding vector
    return (
        docs
        .filter("content_text IS NOT NULL")  # Only text documents
        .select(
            "id",
            "original_filename",
            F.explode(chunk_text_udf("content_text")).alias("chunk"),
        )
        .withColumn("embedding", embed_udf("chunk.text"))
    )
```

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| CDF over Auto Loader | Auto Loader can't detect in-place overwrites; CDF captures the metadata change |
| Lakehouse Sync as trigger | Already running; no additional infra. Latency: ~1 min (sync interval) |
| `updated_at` as change signal | More reliable than `size_bytes` alone (edits could produce same size) |
| `sha256_hex` for dedup | Skip reprocessing if hash unchanged (e.g., no-op save) |
| Bronze/Silver/Gold medallion | Standard lakeLoom pipeline pattern |
| `read_files()` in Silver | Re-reads actual bytes from volume; decouples detection from content |

---

## What Needs to Exist First

| Prerequisite | Status |
|---|---|
| `PUT /api/media/:id/content` endpoint | ✅ Implemented (media-routes.ts) |
| OTel event `[media] content.updated` | ✅ Emitted on each edit (now includes sha256_hex) |
| `lb_uploads_history` Delta table | ✅ Exists (Lakehouse Sync) |
| CDF enabled on sync table | ❓ Verify / enable |
| `updated_at` column in Lakebase | ✅ Migration 016 (commit `36d21c6`) |
| `sha256_hex` updated on edit | ✅ PUT handler fixed (commit `36d21c6`) |
| SDP pipeline (bronze/silver/gold) | ⏳ Phase 5 work |
| Vector Search index | ⏳ Phase 5+ work |

---

## Open Questions

1. **Lakehouse Sync latency** — Default sync interval is ~60s. Is this acceptable for
   edit → re-index latency, or do we need a faster signal (e.g., direct Delta write
   from the PUT handler)?

2. **Chunking strategy** — For markdown, chunk by heading (`##`) or by token count?
   Heading-based preserves semantic boundaries but produces variable-size chunks.

3. **Embedding model** — Use workspace Foundation Model (`databricks-bge-large-en`)
   or external? Workspace model avoids egress but has throughput limits.

4. **Backfill** — On first pipeline run, should we process all existing documents
   (full table scan of lb_uploads_history) or only future edits?

5. **Delete handling** — The `DELETE /api/media/:id` endpoint sets `revoked_at`.
   CDF will emit an update_postimage. Pipeline should detect `revoked_at IS NOT NULL`
   and remove from the vector index.

---

## Migration (DONE — commit `36d21c6`)

```typescript
// Migration 016: add updated_at to uploads, update PUT handler
export const migration016: Migration = {
  name: '016_uploads_updated_at',
  up: `ALTER TABLE app.uploads ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ;`,
};
```

The PUT handler in `media-routes.ts` now does (commit `36d21c6`):
```typescript
const newHash = createHash('sha256').update(newContent).digest('hex');
await lakebase.query(
  `UPDATE app.uploads SET size_bytes = $1, sha256_hex = $2, updated_at = NOW() WHERE id = $3`,
  [newContent.length, newHash, uploadId]
);
```

✅ This is the critical link for CDF to detect the change — now implemented.
