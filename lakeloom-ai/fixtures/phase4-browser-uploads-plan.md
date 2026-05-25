# Phase 4: Browser-Side Uploads — Implementation Plan

**Date:** 2026-05-25
**Status:** ✅ Complete (Tasks 1–9) — Task 10 (Playwright tests) deferred
**Estimated effort:** 2–3 days
**Dependencies:** Phase 2 (Capture Session Browser) ✅ + Phase 3 (Media Viewer) ✅

---

## Overview

Allow FDEs to upload screenshots, photos, and documents directly from the browser — no iPhone required. The upload backend already exists (iOS paths); we need to:
1. Open those routes to browser auth
2. Build client-side drag-and-drop + file picker UI
3. Show upload progress with cancel
4. Integrate into existing pages

---

## Design Decisions (Resolved)

| # | Question | Decision |
|---|----------|----------|
| 1 | Upload to completed sessions? | **YES** — FDEs often add reference photos post-session |
| 2 | Max file size | **5 GB** — large video/audio reference files are common |
| 3 | Concurrent uploads | **Parallel** — multiple files upload simultaneously |

---

## Architecture Decision: Shared Routes with `dualAuth`

**Approach:** Switch existing upload endpoints from `iosAuth()` to `dualAuth()` and dynamically determine `clientType` from the auth context.

**Rationale:**
- `upload-routes.ts` already has the `ClientType` discriminator (`'ios' | 'web'`)
- `createUploadHandler` factory already accepts `clientType` — we just need to derive it from `req.user` instead of hardcoding
- `dualAuth()` middleware already exists and handles iOS vs browser detection
- Avoids duplicating routes, handlers, and MIME logic
- Both paths write to the same `app.uploads` table with full traceability

**Key difference from iOS:** Browser requests don't include `device_id` or `client_ts` (no hardware clock sync needed). Server uses `new Date().toISOString()` as timestamp.

---

## Architecture Decision: Streaming Upload for Large Files

The existing iOS handler buffers the entire file into memory (`Buffer.concat(chunks)`) before writing to UC Volume. This is acceptable for iOS uploads (typically < 100 MB audio/photos) but **will not work for 5 GB browser uploads**.

**Approach:** Stream-through architecture for browser uploads.

**Design:**
1. Busboy streams file chunks directly to a `PassThrough` stream
2. Two consumers tee off the stream:
   - UC Volume write (via AppKit files plugin with `ReadableStream`)
   - Incremental SHA-256 hash computation (`crypto.createHash('sha256').update(chunk)`)
3. No full-file buffering — memory usage stays bounded regardless of file size
4. Size tracking via byte counter on each chunk

**Implementation pattern:**
```typescript
// Stream-through: Busboy → tee → [Volume write, SHA-256 hash]
const hash = createHash('sha256');
let sizeBytes = 0;

busboy.on('file', (_fieldname, stream, info) => {
  const passthrough = new PassThrough();
  stream.pipe(passthrough);

  stream.on('data', (chunk: Buffer) => {
    hash.update(chunk);
    sizeBytes += chunk.length;
  });

  // Convert Node stream to Web ReadableStream for AppKit files plugin
  const webStream = Readable.toWeb(passthrough) as ReadableStream;
  volumeWritePromise = appkitFiles(volumeKey).upload(relativePath, webStream, { overwrite: false });
});
```

**Fallback for iOS:** Keep the existing buffer approach for iOS uploads (simpler, already proven, files are small). Detection: `clientType === 'ios'` → buffer path, `clientType === 'web'` → stream path.

**AppKit files plugin compatibility:** Verify that `appkitFiles().upload()` accepts a `ReadableStream` (not just `Buffer`). The type definition shows `ReadableStream | Buffer | string` — streaming is supported.

---

## Implementation Tasks

### Task 1: Server — Make Upload Routes Browser-Compatible ✅

**Commit:** `647697c`
**File:** `server/routes/uploads/upload-routes.ts`

**Changes:**

1. **Modify `UploadHandlerOpts`** — Remove hardcoded `clientType`, derive it dynamically:
   ```typescript
   // Before: clientType is fixed per route registration
   { kind: 'screenshot', clientType: 'ios', ... }
   
   // After: detect from auth context inside the handler
   function detectClientType(req: Request): ClientType {
     return req.headers['x-lakeloom-session-token'] ? 'ios' : 'web';
   }
   ```

2. **Switch middleware** on screenshot, photo, and document routes:
   ```typescript
   // Before:
   app.post('/api/captures/:capture_session_id/screenshots', iosAuth({ lakebase }), handler);
   
   // After:
   app.post('/api/captures/:capture_session_id/screenshots', dualAuth({ lakebase }), handler);
   ```

3. **Keep audio as `iosAuth` only** — audio recording is iOS-exclusive per spec.

4. **Handle missing `sessionId` for browser** — Browser `req.user.sessionId` is `''`. The INSERT must handle `paired_session_id = NULL` for web uploads:
   ```typescript
   const pairedSessionId = req.user!.sessionId || null;  // '' → null for browser
   ```

5. **Relax capture state check for browser** — Allow uploads to both `active` and `completed` from browser (not `cancelled`):
   ```typescript
   // Before:
   WHERE id = $1::uuid AND state = 'active'
   
   // After (browser path):
   WHERE id = $1::uuid AND state IN ('active', 'completed')
   ```
   iOS retains `state = 'active'` only (no behavioral change for existing clients).

**Migration 014:** `paired_session_id` column relaxed to nullable (`ALTER COLUMN paired_session_id DROP NOT NULL`). Commit `78c653f`.

---

### Task 2: Server — Streaming Upload Path for Browser ✅

**Commit:** `cc63c8e`
**File:** `server/routes/uploads/upload-routes.ts`

The existing `parseMultipart` → buffer → write pattern stays for iOS. For browser, implement a streaming path:

**New function: `streamMultipartToVolume`**
```typescript
interface StreamUploadResult {
  sizeBytes: number;
  sha256Hex: string;
  fileMimeType: string;
  clientFilename?: string;
}

async function streamMultipartToVolume(
  req: Request,
  volumeHandle: VolumeHandle,
  relativePath: string,
  allowedMimes: string[],
  maxSizeBytes: number,
): Promise<StreamUploadResult>
```

**Key behaviors:**
- Rejects files > 5 GB via byte counter (aborts stream + deletes partial file)
- Rejects invalid MIME early (from Busboy `info.mimeType` before any writing)
- Computes SHA-256 incrementally
- If client-provided `sha256_hex` doesn't match → delete uploaded file, return 400
- Emits structured log events at same points as existing handler

**Max size enforcement:**
```typescript
const MAX_UPLOAD_BYTES = 5 * 1024 * 1024 * 1024; // 5 GB

stream.on('data', (chunk: Buffer) => {
  sizeBytes += chunk.length;
  if (sizeBytes > MAX_UPLOAD_BYTES) {
    stream.destroy(new Error('File exceeds maximum upload size (5 GB)'));
  }
});
```

**Verify/test:**
- Browser `FormData` with `file` field works with current Busboy config
- No `client_ts` field → server fallback (already handled by `normalizeClientTimestamp`)
- No `sha256_hex` field → skip verification (already handled)
- No `device_id` field → null (already handled)
- AppKit body-parsing middleware: existing `getBufferedRequestBody` fallback handles pre-consumed bodies

---

### Task 3: Client — `DragDropZone` Reusable Component ✅

**Commit:** `d583148`
**File:** `client/src/components/DragDropZone.tsx`

**Props interface:**
```typescript
interface DragDropZoneProps {
  /** Accepted MIME types (used for client-side validation + <input accept>) */
  accept: string[];
  /** Max file size in bytes (default: 5 GB) */
  maxSizeBytes?: number;
  /** Whether multiple files can be dropped at once */
  multiple?: boolean;
  /** Upload endpoint URL (fully resolved, e.g., /api/captures/:id/screenshots) */
  uploadUrl: string;
  /** Called on successful upload with server response */
  onUploadComplete: (response: UploadResponse) => void;
  /** Called when all uploads in a batch complete */
  onAllComplete?: () => void;
  /** Optional label override (default derives from MIME) */
  label?: string;
  /** Compact mode for inline use (smaller height) */
  compact?: boolean;
  /** Max parallel uploads (default: 3) */
  concurrency?: number;
}
```

**Behavior:**
- Drag-over visual feedback (dashed border → solid Lava 600, background tint)
- File picker `<input type="file">` as fallback button
- Client-side MIME validation (instant reject with error toast)
- Client-side size validation (reject > maxSizeBytes with friendly message)
- Progress tracking via `XMLHttpRequest` (fetch doesn't support upload progress)
- Per-file progress bars with cancel (via `xhr.abort()`)
- **Parallel uploads** — up to `concurrency` files in flight simultaneously (default: 3)
- Error state per file (retry button)
- Success state with file thumbnail/icon

**Design (Databricks brand):**
- Rounded-xl container, dashed 2px border `--border-default`
- Upload icon (lucide `Upload`) centered, `--text-secondary`
- Primary text: "Drop files here" (DM Sans Medium, 16px)
- Secondary text: "or click to browse • PNG, JPEG up to 5 GB" (DM Sans Regular, 14px, `--text-secondary`)
- Active drop state: border solid `--accent-primary`, bg `rgba(255, 54, 33, 0.04)`
- Error state: border `--accent-error`, error icon + message
- Motion: `--motion-fast` border transition, `--motion-normal` for progress bar

---

### Task 4: Client — `UploadProgressItem` Component ✅

**Commit:** `d583148`
**File:** `client/src/components/UploadProgressItem.tsx`

**States:**
- **Queued** — file icon + name, "Waiting..." text
- **Uploading** — progress bar (0–100%), file name, size, cancel button (X)
- **Success** — green checkmark, file name, size, "View" link (opens MediaModal)
- **Error** — red icon, error message, "Retry" button

**Progress bar spec:**
- Height: 4px, rounded-full
- Background: `--surface-tertiary`
- Fill: `--accent-primary` (Lava 600), transition width `--motion-fast`
- On complete: brief flash to `--accent-success` then fade

---

### Task 5: Client — Upload Hook ✅

**Commit:** `d583148`
**File:** `client/src/hooks/useUpload.ts`

**Interface:**
```typescript
interface UseUploadOptions {
  url: string;
  /** Max concurrent uploads (default: 3) */
  concurrency?: number;
  onSuccess?: (response: UploadResponse) => void;
  onError?: (error: Error, file: File) => void;
}

interface UploadItem {
  id: string;           // client-generated UUID
  file: File;
  status: 'queued' | 'uploading' | 'success' | 'error';
  progress: number;     // 0–100
  response?: UploadResponse;
  error?: string;
  abort: () => void;
}

function useUpload(options: UseUploadOptions): {
  items: UploadItem[];
  upload: (files: File[]) => void;
  retry: (itemId: string) => void;
  cancel: (itemId: string) => void;
  cancelAll: () => void;
  clearCompleted: () => void;
  activeCount: number;
}
```

**Implementation notes:**
- Uses `XMLHttpRequest` for `upload.onprogress` events (fetch lacks this)
- **Parallel uploads** with configurable concurrency (default: 3)
- Pool management: when a slot opens (success/error/cancel), next queued file starts
- `xhr.abort()` for per-item cancel, `cancelAll()` for batch abort
- No auto-clear — user dismisses completed items (large files take long; user wants to verify)

**Concurrency pool pattern:**
```typescript
// Track active upload count
const activeSlots = useRef(0);

function startNext() {
  while (activeSlots.current < concurrency && queue has items) {
    activeSlots.current++;
    startUpload(nextQueuedItem);
  }
}

// On finish/error/cancel:
activeSlots.current--;
startNext();
```

---

### Task 6: Client — Integrate into `CaptureDetailPage` ✅

**Commit:** `d583148`
**File:** `client/src/pages/projects/CaptureDetailPage.tsx`

**Placement:** Below the upload timeline, above the empty state. Only visible when session state is `active` or `completed` (not `cancelled`).

**UI:**
```
┌─────────────────────────────────────────────┐
│  Upload Timeline (existing)                  │
│  ┌─────────────────────────────────────────┐│
│  │ [upload items...]                       ││
│  └─────────────────────────────────────────┘│
│                                              │
│  ┌─────────────────────────────────────────┐│
│  │ ┌───────────────────────────────────┐   ││
│  │ │   📤 Drop screenshots or photos   │   ││
│  │ │   or click to browse              │   ││
│  │ │   PNG, JPEG • up to 5 GB          │   ││
│  │ └───────────────────────────────────┘   ││
│  └─────────────────────────────────────────┘│
└─────────────────────────────────────────────┘
```

**Props for this instance:**
- `accept`: `['image/png', 'image/jpeg']`
- `maxSizeBytes`: 5 * 1024 * 1024 * 1024 (5 GB)
- `multiple`: true
- `concurrency`: 3
- `uploadUrl`: `/api/captures/${captureId}/screenshots`
- `onUploadComplete`: Refresh upload list / append new upload to timeline
- `compact`: true (inline within the existing layout)

---

### Task 7: Client — Integrate into `ProjectDetailPage` ✅

**Commit:** `d583148`
**File:** `client/src/pages/projects/ProjectDetailPage.tsx`

**Placement:** In the "Documents" section, below the existing document list.

**UI:**
```
┌─────────────────────────────────────────────┐
│  📄 Project Documents                        │
│  ┌─────────────────────────────────────────┐│
│  │ proposal.pdf          2.4 MB  5 min ago ││
│  │ requirements.docx     1.1 MB  2 hr ago  ││
│  └─────────────────────────────────────────┘│
│                                              │
│  ┌─────────────────────────────────────────┐│
│  │   📤 Drop PDF or DOCX documents here    ││
│  │   or click to browse • up to 5 GB       ││
│  └─────────────────────────────────────────┘│
└─────────────────────────────────────────────┘
```

**Props for this instance:**
- `accept`: `['application/pdf', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document']`
- `maxSizeBytes`: 5 * 1024 * 1024 * 1024
- `multiple`: true
- `concurrency`: 3
- `uploadUrl`: `/api/projects/${projectId}/documents`
- `onUploadComplete`: Refresh project uploads list

---

### Task 8: Client — MIME + Size Validation UX ✅

**Included in Task 3 implementation (DragDropZone).**

**Client-side validation (instant, before upload starts):**

1. **MIME check:** Compare `file.type` against `accept` list. If no match:
   - Show inline error below the drop zone: "❌ {filename} — file type not supported. Accepted: PNG, JPEG"
   - Do NOT send to server
   - File remains in error state with dismiss button

2. **Size check:** Compare `file.size` against `maxSizeBytes`. If over:
   - Show inline error: "❌ {filename} — file too large ({formatted size}). Maximum: 5 GB"
   - Do NOT send to server

3. **Empty file check:** Reject 0-byte files.

4. **Extension fallback:** Some browsers report `file.type` as `''` for DOCX. Fallback: check extension against a map:
   ```typescript
   const EXT_TO_MIME: Record<string, string> = {
     '.pdf': 'application/pdf',
     '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
     '.png': 'image/png',
     '.jpg': 'image/jpeg',
     '.jpeg': 'image/jpeg',
   };
   ```

---

### Task 9: Accessibility & Keyboard Support ✅

**Included in Task 3 implementation (DragDropZone).**

- Drop zone is focusable (`tabIndex={0}`), Enter/Space opens file picker
- Progress items are `role="status"` with `aria-live="polite"`
- Cancel button has `aria-label="Cancel upload for {filename}"`
- Error messages use `role="alert"`
- Drag-and-drop is enhanced — file picker is always available as the primary path
- All interactive elements meet 44px minimum tap target

---

### Task 10: Testing (Deferred)

**Playwright smoke test additions** (`tests/smoke.spec.ts`):
1. Navigate to a project, verify drop zone is visible
2. Upload a small PNG via file input (programmatic)
3. Verify progress bar appears and completes
4. Verify new upload appears in the timeline
5. Verify MIME rejection for an invalid file type

**Manual testing checklist:**
- [x] Drag PDF onto project detail → uploads successfully (verified via OTel, 201 response)
- [x] Drag PNG onto project detail → uploads successfully (lakeloom-ios-icon.png, 1.7 MB)
- [ ] Drag JPEG onto capture detail → uploads successfully
- [ ] Drag DOCX onto project detail → uploads successfully
- [ ] Drag MP3 onto capture detail → rejected with friendly error
- [ ] Drag 6 GB file → rejected client-side with size error
- [ ] Cancel mid-upload → upload aborts, file removed from queue
- [ ] Upload to cancelled session → drop zone hidden
- [ ] Upload to completed session → succeeds (browser-only behavior)
- [x] Multiple files dropped → parallel upload with concurrent progress bars (6 .md files concurrent)
- [x] 5+ files dropped → 3 active + 2 queued, queue drains as slots open (6 files, all succeeded)
- [ ] Network error mid-upload → error state with retry button
- [ ] Uploaded file appears in MediaModal when clicked
- [ ] Large file (500 MB+) → progress bar updates smoothly, server doesn't OOM
- [x] Delete document → removed from list (confirmed via UI)
- [x] Markdown uploads → accepted and typed correctly (MARKDOWN label shown)

**Known UX issue (follow-up):**
- Document cards show generic "Document" title instead of original filename (e.g., "01-PRD.md"). The `original_filename` is stored in the DB but not displayed in the ProjectDetailPage document list.

---

## File Inventory (New & Modified)

| File | Action | Purpose |
|------|--------|---------|
| `server/routes/uploads/upload-routes.ts` | Modified | Switch screenshot/photo/document routes to `dualAuth`, derive `clientType` dynamically, add streaming path, expand MIME whitelist |
| `server/routes/media/media-routes.ts` | Modified | Add `DELETE /api/media/:id` (soft-delete) and `PUT /api/media/:id/content` (markdown editing) |
| `server/migrations/014_nullable_paired_session_id.ts` | Created | Allow NULL `paired_session_id` for browser uploads |
| `server/migrations/migrate.ts` | Modified | Register migration 014 |
| `client/src/components/DragDropZone.tsx` | Created | Reusable drag-and-drop upload zone (PDF, DOCX, PPTX, Markdown, PNG, JPEG) |
| `client/src/components/UploadProgressItem.tsx` | Created | Per-file upload progress display |
| `client/src/components/MarkdownDocument.tsx` | Created | Rendered markdown viewer with inline edit mode |
| `client/src/hooks/useUpload.ts` | Created | Upload queue management hook with concurrency pool |
| `client/src/components/index.ts` | Modified | Export new components (DragDropZone, UploadProgressItem, MarkdownDocument) |
| `client/src/components/media/DocumentViewer.tsx` | Modified | Route markdown to MarkdownDocument, images to inline viewer, add PPTX type label |
| `client/src/pages/projects/CaptureDetailPage.tsx` | Modified | Add DragDropZone below timeline |
| `client/src/pages/projects/ProjectDetailPage.tsx` | Modified | Add DragDropZone (expanded types), delete button per document |
| `client/src/App.tsx` | Modified | Remove example Analytics/Files pages + nav links |
| `package.json` | Modified | Add react-markdown + remark-gfm dependencies |
| `config/queries/hello_world.sql` | Deleted | Removed example query (caused deploy failures) |
| `config/queries/mocked_sales.sql` | Deleted | Removed example query (caused deploy failures) |
| `client/src/pages/analytics/AnalyticsPage.tsx` | Deleted | Removed example page |
| `client/src/pages/files/FilesPage.tsx` | Deleted | Removed example page |

---

## Commits

| Hash | Description |
|------|-------------|
| `647697c` | Task 1: dualAuth + browser compatibility |
| `cc63c8e` | Task 2: streaming uploads |
| `d583148` | Tasks 3–7: browser upload UI + page integrations + example cleanup |
| `78c653f` | Fix: nullable paired_session_id (migration 014) |
| `00d4571` | Expand documents: PPTX/PNG/JPEG/Markdown types, delete, markdown editing |
| `3aec2c7` | Fix: media-routes.ts TS compile error (misplaced route handlers) |

---

## Implementation Order (Actual)

```
1. Server changes (Task 1–2)              ✅ commits 647697c, cc63c8e
2. useUpload hook (Task 5)                 ✅ commit d583148
3. DragDropZone + ProgressItem (Task 3–4)  ✅ commit d583148
4. CaptureDetailPage integration (Task 6)  ✅ commit d583148
5. ProjectDetailPage integration (Task 7)  ✅ commit d583148
6. Validation polish (Task 8–9)            ✅ included in Task 3
7. Migration fix (discovered at runtime)   ✅ commit 78c653f
8. Expanded types + delete + md editing    ✅ commit 00d4571
9. TS compile fix (media-routes)           ✅ commit 3aec2c7
10. Testing (Task 10)                      ⏳ deferred (manual PDF verified)
```

---

## Risks & Mitigations

| Risk | Likelihood | Mitigation | Status |
|------|-----------|-------------|--------|
| AppKit body parser interferes with Busboy streaming | Low (existing `getBufferedRequestBody` fallback) | Test early with browser FormData | ✅ Verified working |
| Large file uploads (multi-GB) timeout on AppKit container | Medium | Streaming path avoids memory pressure; verify AppKit has no request timeout < file transfer time | ⚠️ Untested with GB-scale files |
| AppKit files plugin doesn't stream ReadableStream for large files | Medium | Test with 1 GB file early. Fallback: chunked upload via REST API directly | ⚠️ Untested |
| CORS issues on multipart from browser | None (same-origin — browser hits App directly) | N/A | ✅ Confirmed |
| Progress events not firing (chunked encoding) | Low (XHR upload progress is reliable for multipart) | Fallback: indeterminate progress bar | ⚠️ Untested |
| Memory pressure from parallel 5 GB uploads | Medium | Server streams (no buffer). Client limited to 3 concurrent. Monitor container memory. | ⚠️ Untested |
| UC Volume write timeout for very large files | Low | AppKit plugin handles chunked writes internally; verify no SDK-level timeout | ⚠️ Untested |
| NULL paired_session_id constraint on uploads table | **Hit** | Migration 014 drops NOT NULL | ✅ Fixed |
| Route handler code injected into wrong scope during edit | **Hit** | Re-verified file structure after string-replace edits | ✅ Fixed |
