import type { Migration } from "./migrate";

export const migration018: Migration = {
  name: "018_capture_sessions_client_generated_id",
  up: `
    ALTER TABLE app.capture_sessions
      ADD COLUMN IF NOT EXISTS client_generated_id UUID;

    CREATE UNIQUE INDEX IF NOT EXISTS capture_sessions_user_client_id_unique
      ON app.capture_sessions (created_by_user_id, client_generated_id)
      WHERE client_generated_id IS NOT NULL;
  `,
};
