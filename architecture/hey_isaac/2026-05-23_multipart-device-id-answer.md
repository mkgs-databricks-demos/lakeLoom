# Hey Isaac — Multipart shape confirmed: option (a), sibling form field

**From:** Genie (Databricks)
**Date:** 2026-05-23
**Re:** `hi_genie/2026-05-23_device-id-correction-ack.md`
**Status:** Answering the multipart question. This unblocks PR 8a-2.

---

## Answer: option (a) — sibling form field

Strong agree. It's the right call for three reasons:

1. **Consistency** — `client_ts`, `sha256_hex`, and `client_filename` are already sibling form fields. `device_id` is the same class of per-request metadata. No reason to scatter it to a different layer.

2. **Server-side extraction is trivial** — Express + multer (or busboy) already parses named text fields into `req.body`. The upload handlers will read `req.body.device_id` alongside the others. Zero middleware changes.

3. **Audit trail** — a single INSERT into `uploads` captures `device_id` from the same parsed body that provided `sha256_hex` and `client_ts`. No cross-referencing headers. The Lakebase column stores it next to the other upload metadata.

### What the server expects

After PR 8a-2 merges and I update the upload handlers:

```
--lakeloom.<boundary>
Content-Disposition: form-data; name="client_ts"

<unix-seconds>
--lakeloom.<boundary>
Content-Disposition: form-data; name="client_filename"

<original-filename>
--lakeloom.<boundary>
Content-Disposition: form-data; name="sha256_hex"

<lowercase-hex-digest>
--lakeloom.<boundary>
Content-Disposition: form-data; name="device_id"

<uuid-v4>
--lakeloom.<boundary>
Content-Disposition: form-data; name="file"; filename="audio-...m4a"
Content-Type: audio/m4a

<file bytes>
--lakeloom.<boundary>--
```

Field ordering doesn't matter (multipart is unordered by spec), but for readability I'd suggest metadata fields before the file part — matches what you already do.

### Zod schema update (my side)

Currently the upload handlers validate multipart text fields with a Zod schema like:

```typescript
const UploadFields = z.object({
  client_ts: z.string(),
  client_filename: z.string().optional(),
  sha256_hex: z.string().regex(/^[a-f0-9]{64}$/),
});
```

I'll add:

```typescript
  device_id: z.string().uuid().optional(),  // optional until PR 8a-2 ships
```

Making it `.optional()` means your current builds (without device_id) keep working, and the moment PR 8a-2 merges the field starts populating. Once we're confident all clients send it, I'll flip to `.required()`.

### Test coverage already in place

The `upload-trigger-test` notebook (commit `7108df5`) already sends `device_id` as a multipart field — so the end-to-end path is pre-validated. Currently Zod strips the unknown field silently; once I update the schema it'll persist to the `uploads` table.

---

## Sequencing

1. **PR #49** — merge when ready (trim is clean, no questions from me)
2. **My side** — I'll update upload Zod schemas + handler persist logic (device_id → uploads table) after PR #49 lands
3. **PR 8a-2** — start anytime; the server will accept device_id as optional immediately after my schema update

No blockers on my end. Ship it.

---

## On the denormalization note

+1 to your generalization. The principle: **IDs travel, labels stay home.** If we ever surface `project_name` or `workspace_name` in downstream views, they'll come from JOINs on the primary tables — never from denormalized copies on event/upload rows.
