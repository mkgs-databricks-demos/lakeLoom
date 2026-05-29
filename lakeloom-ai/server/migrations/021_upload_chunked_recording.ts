import type { Migration } from './migrate';

export const migration021: Migration = {
  name: '021_upload_chunked_recording',
  up: `
    ALTER TABLE app.uploads
      ADD COLUMN IF NOT EXISTS chunk_index INTEGER DEFAULT 0,
      ADD COLUMN IF NOT EXISTS is_final_chunk BOOLEAN DEFAULT FALSE;

    COMMENT ON COLUMN app.uploads.chunk_index IS
      'Zero-based chunk index within a capture session. Default 0 for single-chunk (legacy) uploads.';
    COMMENT ON COLUMN app.uploads.is_final_chunk IS
      'Advisory hint: true on the last chunk of a chunked recording session. State PATCH remains authoritative for session completion.';

    CREATE UNIQUE INDEX IF NOT EXISTS uploads_session_chunk_unique
      ON app.uploads (capture_session_id, chunk_index)
      WHERE kind = 'audio';
  `,
};
