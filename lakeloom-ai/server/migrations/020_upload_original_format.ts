import type { Migration } from './migrate';

export const migration020: Migration = {
  name: '020_upload_original_format',
  up: `
    ALTER TABLE app.uploads
      ADD COLUMN IF NOT EXISTS original_volume_path TEXT,
      ADD COLUMN IF NOT EXISTS original_mime_type TEXT;

    COMMENT ON COLUMN app.uploads.original_volume_path IS
      'Preserved raw file path (CAF/AIFF) when server-side transcode overwrites volume_path with the M4A.';
    COMMENT ON COLUMN app.uploads.original_mime_type IS
      'Original MIME type before transcode (e.g. audio/x-caf). NULL when no transcode occurred.';
  `,
};
