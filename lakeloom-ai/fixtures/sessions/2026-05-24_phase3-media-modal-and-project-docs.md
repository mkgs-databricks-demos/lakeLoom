# Phase 3 — Media Modal & Project-Level Documents

**Date:** 2026-05-24 18:09 UTC  
**Branch:** `gc-phase3-browser-ui`  
**Commits:** `7839e61`, `2839aa9`  

## Summary

Converted all media viewing from inline panels and new-tab links to a unified modal overlay pattern. Clicking any upload (audio, image, or document) now opens a centered `<dialog>` modal with the appropriate viewer. Also added `MediaModal` as a new reusable component.

## Problems Solved

1. **Inline MediaPanel below fold** — audio/image previews rendered inline below the upload list, requiring scroll to see. Auto-selected first upload on page load (uninvited UX).
2. **Project documents opened in new tab** — ProjectDetailPage used `<a href target="_blank">` for PDFs, breaking user's context by navigating away.
3. **Inconsistent preview behavior** — capture-level media was inline, project-level docs were new-tab. No unified pattern.

## Solution: MediaModal Component

New `client/src/components/media/MediaModal.tsx`:
- Uses native `<dialog>` with `hidden open:grid` pattern (matches ConfirmDialog fix from earlier in the session)
- Responsive sizing: 520px for audio, 900px for images/documents
- Header: filename + download + close buttons
- Footer: mime type, size, timestamp
- Dismiss: backdrop click, Escape key, or X button
- Scale-in entrance animation (`scaleIn 200ms`)
- Wraps existing `MediaPanel` (AudioPlayer, ImageViewer, DocumentViewer)

## Changes

| File | Change |
|------|--------|
| `client/src/components/media/MediaModal.tsx` | NEW — modal wrapper component |
| `client/src/components/media/index.ts` | Added `MediaModal` export |
| `client/src/pages/projects/CaptureDetailPage.tsx` | Replaced inline MediaPanel with MediaModal; removed auto-select behavior; click opens modal |
| `client/src/pages/projects/ProjectDetailPage.tsx` | Replaced `<a target=_blank>` document links with clickable cards that open MediaModal |

## Key Decisions

- **No auto-select on page load** — modal should only appear on explicit user click
- **Same component for both pages** — `MediaModal` accepts any `UploadItem` (audio, image, or document)
- **PDF renders inline in modal** — iframe with browser's native PDF viewer inside 900px modal; "Open in new tab" remains as optional convenience link in DocumentViewer footer
- **DOCX stays download-only** — no browser-native renderer; card with download button shown in modal

## Verification

- Audio: waveform + playback controls render in narrower modal ✅
- Image: thumbnail card with lightbox zoom accessible from modal ✅
- PDF: iframe renders inline in wider modal (no new tab) ✅
- Escape + backdrop click dismiss correctly ✅
- No file overlap with main branch (Isaac's PR #60 is all iOS) — clean merge path ✅

## Branch Status

19 commits ahead of main, 0 conflicts. Ready for PR.
