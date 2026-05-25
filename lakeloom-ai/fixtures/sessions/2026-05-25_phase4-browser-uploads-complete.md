# Session: Phase 4 Browser Uploads — Complete + Phase 5 Pipeline Groundwork

**Date:** 2026-05-25  
**Duration:** ~4 hours  
**Branch:** `mg-phase3-cleanup`

---

## Summary

Completed Phase 4 browser upload feature end-to-end: server streaming, client UI,
MIME-aware document cards, filename capture, and backfill. Also laid groundwork for
Phase 5 CDF pipeline by adding `updated_at` column and fixing the PUT handler to
compute SHA-256 on edits.

---

## Problems Encountered & Resolved

| Problem | Root Cause | Fix |
|---------|-----------|-----|
| Deploy failed (TS6133) | Unused `Download` import in ProjectDetailPage | Removed import (commit `6299507`) |
| `paired_session_id` NOT NULL violation | Browser uploads have no paired session | Migration 014: nullable column (commit `78c653f`) |
| Route handlers in wrong scope | String-replace edit injected code incorrectly | Re-verified file structure (commit `3aec2c7`) |
| Document cards show "Document" not filename | Server didn't capture `info.filename` from Busboy | Both parsers now read it (commit `6299507`) |
| Pre-fix uploads have null filename | Uploaded before filename capture fix | Migration 015: backfill by upload_id (commit `66ce4df`) |
| Markdown files show "Unsupported file type" | MediaPanel only routed PDF/officedocument to DocumentViewer | Added `text/markdown` to routing condition (commit `ad25ad7`) |
| PUT /content doesn't update Lakebase metadata | Only wrote to volume, not DB row | Now updates sha256_hex + updated_at (commit `36d21c6`) |

---

## Changes Made

### Server (`server/`)

| File | Change |
|------|--------|
| `routes/uploads/upload-routes.ts` | dualAuth, streaming, expanded MIME whitelist, capture `info.filename` |
| `routes/media/media-routes.ts` | DELETE endpoint, PUT /content with SHA-256 + updated_at, `createHash` import |
| `migrations/014_nullable_paired_session_id.ts` | Allow NULL paired_session_id |
| `migrations/015_backfill_upload_filenames.ts` | Backfill 9 browser uploads with known filenames |
| `migrations/016_uploads_updated_at.ts` | Add `updated_at TIMESTAMPTZ` column |
| `migrations/migrate.ts` | Register migrations 014–016 |

### Client (`client/src/`)

| File | Change |
|------|--------|
| `components/DragDropZone.tsx` | Created — drag/pick/upload zone |
| `components/UploadProgressItem.tsx` | Created — per-file progress |
| `components/MarkdownDocument.tsx` | Created — markdown viewer + editor |
| `components/index.ts` | Barrel exports |
| `components/media/MediaPanel.tsx` | Route text/markdown to DocumentViewer |
| `components/media/DocumentViewer.tsx` | Render markdown via MarkdownDocument |
| `hooks/useUpload.ts` | Created — XHR concurrency pool (3 slots) |
| `pages/projects/ProjectDetailPage.tsx` | Upload zone, MIME icons, filename display, delete |
| `pages/projects/CaptureDetailPage.tsx` | Upload zone for captures |
| `App.tsx` | Remove example pages/routes |
| `pages/analytics/AnalyticsPage.tsx` | Deleted |
| `pages/files/FilesPage.tsx` | Deleted |

### Config/Docs

| File | Change |
|------|--------|
| `package.json` | Added react-markdown, remark-gfm |
| `config/queries/hello_world.sql` | Deleted (deploy blocker) |
| `config/queries/mocked_sales.sql` | Deleted (deploy blocker) |
| `fixtures/phase4-browser-uploads-plan.md` | Updated throughout |
| `fixtures/phase5-document-edit-cdf-pipeline.md` | Created — CDF pipeline design |

---

## Commits (14 total)

| Hash | Description |
|------|-------------|
| `e1f8b37` | docs: session index + phase3 summary |
| `67ce7df` | docs: Phase 4 plan |
| `647697c` | feat: dualAuth + browser compatibility |
| `cc63c8e` | feat: streaming uploads |
| `d583148` | Phase 4: browser upload UI (Tasks 3–7) |
| `78c653f` | fix: nullable paired_session_id (migration 014) |
| `00d4571` | feat: expanded types, delete, markdown editing |
| `3aec2c7` | fix: media-routes.ts TS compile error |
| `6299507` | fix: MIME icons/labels + filename capture |
| `66ce4df` | fix: backfill filenames (migration 015) |
| `ad25ad7` | fix: route text/markdown in MediaPanel |
| `677230d` | docs: Phase 5 CDF pipeline design |
| `36d21c6` | feat: migration 016 + PUT sha256/updated_at |
| `2b2017f` | docs: update CDF design doc status |

---

## Decisions

1. **Streaming for browser, buffered for iOS** — Browser needs 5 GB support; iOS files are small.
2. **MIME-aware icons** — Image (blue), Markdown (lava), PDF (red), Document (amber).
3. **Filename from Content-Disposition** — `info.filename` fallback, no separate form field needed.
4. **CDF over Auto Loader for edits** — In-place overwrites invisible to Auto Loader; CDF on Lakehouse Sync table is the natural fit.
5. **updated_at + sha256_hex** — Both needed for reliable change detection (same-size edits, no-op saves).

---

## Testing Verified

- [x] PDF upload (project detail)
- [x] PNG upload (project detail, 1.7 MB)
- [x] Concurrent uploads (6 markdown files)
- [x] 5+ files queuing (pool drains correctly)
- [x] Delete document
- [x] Markdown render in modal
- [x] Markdown inline editing
- [x] Filename display in cards (post-fix)
- [x] Migration 015 backfill (filenames appear)
- [x] Migration 016 applied (updated_at column)
- [x] SHA-256 in edit response (confirmed in OTel)

---

## What's Next

- [ ] Open PR: `mg-phase3-cleanup` → `main`
- [ ] Verify CDF enabled on `lb_uploads_history`
- [ ] Phase 5: SDP pipeline (bronze/silver/gold for document content)
- [ ] Vector Search index for document embeddings
- [ ] Remaining manual QA (JPEG, DOCX, rejection cases, large file stress)
