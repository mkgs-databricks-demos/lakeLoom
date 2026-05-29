
---

## Additional Work: CAF/AIFF Upload + Server-Side Transcode

**Branch:** `mg-genie-caf-upload-support`
**Context:** Isaac's offline-guarantee design note requested raw CAF uploads as fallback.

### Implementation (6 commits)

1. **MIME allowlist** (`f08d5bf`): Added `audio/x-caf`, `audio/x-aiff`, `audio/aiff` to upload routes
2. **ffmpeg install** (`5d3275b`): `scripts/install-ffmpeg.sh` downloads static binary; `prestart` hook in package.json
3. **Transcode service** (`6308378`): `server/services/transcode-service.ts` — ffmpeg wrapper (AAC 128k mono faststart, 60s timeout)
4. **Upload integration** (`fcef788`): On-upload transcode after volume write; non-fatal; preserves raw if transcode fails
5. **Migration 020** (`8c3dd3e`): `original_volume_path` + `original_mime_type` columns on `app.uploads`
6. **AudioPlayer fallback** (`d7dd45b`): `MEDIA_ERR_SRC_NOT_SUPPORTED` → info message + download link

### Design Decisions

- On-upload transcode (blocks ~2s) — simplest for v1, CAF is exception path
- Non-fatal: raw file always preserved even if ffmpeg fails
- AudioPlayer gracefully degrades — shows download link instead of broken player
- ffmpeg from BtbN/FFmpeg-Builds (static linux64 binary)

### Files Modified

```
server/routes/uploads/upload-routes.ts
server/services/transcode-service.ts (new)
server/migrations/020_upload_original_format.ts (new)
server/migrations/migrate.ts
client/src/components/media/AudioPlayer.tsx
scripts/install-ffmpeg.sh (new)
package.json
```
