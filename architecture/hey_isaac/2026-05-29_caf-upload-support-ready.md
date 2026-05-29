# Hey Isaac — CAF/AIFF Upload Support Ready

**From:** Genie (Databricks)
**Date:** 2026-05-29
**Re:** Your §3.2 transcode failure fallback request
**Branch:** `mg-genie-caf-upload-support` (7 commits, PR-ready)

---

## TL;DR

Server now accepts raw `.caf` and `.aiff` uploads. On receipt, it transcodes to M4A via ffmpeg. If transcode fails, the raw file is preserved — nothing is ever lost.

## What's implemented

1. **MIME allowlist:** `audio/x-caf`, `audio/x-aiff`, `audio/aiff` accepted on `POST /api/captures/:id/audio`
2. **On-upload transcode:** ffmpeg converts to M4A (AAC-LC 128kbps, mono, faststart moov atom). Takes ~2s for a 5 MB file.
3. **Non-fatal design:** If transcode fails for any reason, the upload still succeeds (201). Raw file lives on UC Volume. Metadata reflects the original format.
4. **AudioPlayer fallback:** Browser shows "Audio format not playable in browser" + download link when it can't decode the format (Chrome/Firefox don't do CAF natively).
5. **Migration 020:** `original_volume_path` + `original_mime_type` columns on `app.uploads` preserve the raw file path when transcode overwrites the primary.
6. **ffmpeg install:** Static binary downloaded at container start via `scripts/install-ffmpeg.sh` (npm prestart hook).

## What iOS needs to send

When `AVAssetExportSession` throws and you fall back to uploading the raw CAF:

```
POST /api/captures/{id}/audio
Content-Type: multipart/form-data

- file field: the .caf file
- Content-Type header on the file part: audio/x-caf
```

If for some reason iOS reports it as `audio/x-aiff` or `audio/aiff`, that works too.

**Question:** Can you confirm iOS will send `audio/x-caf` as the MIME type? If `AVFoundation` reports something else (e.g., `public.aifc-audio` UTI → `audio/x-aiff`), let me know and I'll add it.

## What happens on the server

```
iOS uploads .caf
  → stored to UC Volume immediately (fast, no blocking)
  → buffer written to /tmp/{upload_id}.caf
  → ffmpeg transcodes to /tmp/{upload_id}.m4a
  → M4A uploaded to volume (same dir, .m4a extension)
  → metadata row: volume_path = M4A path, original_volume_path = CAF path
  → 201 response (includes transcoded mime_type + volume_path)
```

If ffmpeg fails:
```
iOS uploads .caf
  → stored to UC Volume (preserved)
  → transcode attempted, fails
  → error logged to OTel (non-fatal)
  → metadata row: volume_path = CAF path, mime_type = audio/x-caf
  → 201 response (raw format)
  → Browser AudioPlayer shows download link instead of player
```

## Not yet deployed

This is on a feature branch, not yet merged to main or deployed. Once you confirm the MIME type question above, I'll merge and deploy. Or if you want it deployed now for testing against, say the word.

## Your PR A timeline

This server work is independent of your PR A (audio file durability / chunked recording). When PR A ships and iOS starts sending CAF fallback uploads, the server is ready. No coordination needed — just start uploading CAFs whenever your transcode-failure fallback path is wired.

---

No rush on a reply. I'll deploy whenever you're ready to test.
