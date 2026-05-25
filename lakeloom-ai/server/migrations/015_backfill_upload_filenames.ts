/**
 * Migration 015: Backfill original_filename for pre-fix browser uploads.
 *
 * Before commit 6299507, the streaming upload parser did not capture
 * info.filename from Busboy's file event. This left 9 browser uploads
 * with NULL original_filename. We know the correct filenames from the
 * upload progress UI and can match by upload_id.
 */

import type { Migration } from './migrate';

export const migration015: Migration = {
  name: '015_backfill_upload_filenames',
  up: `
    UPDATE app.uploads SET original_filename = 'Rx Coverage Analysis.pdf'
      WHERE id = '019e5f9a-44e4-70d8-a6c5-1beee89d2b01' AND original_filename IS NULL;
    UPDATE app.uploads SET original_filename = '03-schema.md'
      WHERE id = '019e5fc6-c028-71ae-a997-66b810163937' AND original_filename IS NULL;
    UPDATE app.uploads SET original_filename = '01-PRD.md'
      WHERE id = '019e5fc6-c03a-744a-9574-732b784e2601' AND original_filename IS NULL;
    UPDATE app.uploads SET original_filename = '02-architecture.md'
      WHERE id = '019e5fc6-c02b-762e-9084-b91a76974a5c' AND original_filename IS NULL;
    UPDATE app.uploads SET original_filename = '04-mcp-spec.md'
      WHERE id = '019e5fc6-c27c-723b-80db-03e6ec560dbc' AND original_filename IS NULL;
    UPDATE app.uploads SET original_filename = 'README.md'
      WHERE id = '019e5fc6-c2b1-75ee-9f3c-d01d524dbc84' AND original_filename IS NULL;
    UPDATE app.uploads SET original_filename = '05-ui-design.md'
      WHERE id = '019e5fc6-c28a-75ab-a88f-fb288b86dbff' AND original_filename IS NULL;
    UPDATE app.uploads SET original_filename = 'lakeloom-ios-icon.png'
      WHERE id = '019e5fc9-deac-70df-a5d6-5bcd9d41812d' AND original_filename IS NULL;
    UPDATE app.uploads SET original_filename = 'lakeloom-banner.png'
      WHERE id = '019e5fd9-44c4-7179-9b32-1fad7aad3a80' AND original_filename IS NULL;
  `,
};
