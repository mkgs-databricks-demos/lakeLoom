-- Validation task for lakeLoom platform bootstrap.
--
-- This SQL file validates the post-bootstrap platform contract. It:
--   1. Verifies the SQL warehouse is operating in the expected catalog/schema.
--   2. Asserts the deployed Unity Catalog schema exists.
--   3. Asserts the managed session_audio volume exists and is MANAGED.
--   4. Asserts the bronze transcript_events_raw table now exists after the
--      dedicated DDL task has run.

USE CATALOG IDENTIFIER(:catalog_use);
USE SCHEMA IDENTIFIER(:schema_use);

SELECT
  current_timestamp() AS validated_at,
  current_catalog() AS active_catalog,
  current_schema() AS active_schema,
  current_user() AS executed_as,
  :secret_scope_name AS secret_scope_name,
  :client_id_dbs_key AS client_id_dbs_key,
  :client_secret_dbs_key AS client_secret_dbs_key,
  :zerobus_stream_pool_size AS zerobus_stream_pool_size,
  CONCAT(:catalog_use, '.', :schema_use, '.transcript_events_raw') AS expected_target_table_name,
  CONCAT('/Volumes/', :catalog_use, '/', :schema_use, '/session_audio') AS expected_volume_path;

SELECT
  assert_true(
    current_catalog() = :catalog_use,
    CONCAT('Active catalog mismatch. Expected ', :catalog_use, ' but session is using ', current_catalog())
  ) AS catalog_context_valid,
  assert_true(
    current_schema() = :schema_use,
    CONCAT('Active schema mismatch. Expected ', :schema_use, ' but session is using ', current_schema())
  ) AS schema_context_valid;

WITH schema_match AS (
  SELECT *
  FROM system.information_schema.schemata
  WHERE catalog_name = :catalog_use
    AND schema_name = :schema_use
)
SELECT
  assert_true(
    COUNT(*) = 1,
    CONCAT('Required schema not found: ', :catalog_use, '.', :schema_use)
  ) AS schema_exists,
  MAX(schema_owner) AS schema_owner,
  MAX(created) AS schema_created_at,
  MAX(created_by) AS schema_created_by,
  MAX(comment) AS schema_comment
FROM schema_match;

WITH volume_match AS (
  SELECT *
  FROM system.information_schema.volumes
  WHERE volume_catalog = :catalog_use
    AND volume_schema = :schema_use
    AND volume_name = 'session_audio'
),
volume_summary AS (
  SELECT
    COUNT(*) AS matching_volume_count,
    COALESCE(MAX(CASE WHEN volume_type = 'MANAGED' THEN 1 ELSE 0 END), 0) AS has_managed_volume,
    MAX(volume_type) AS detected_volume_type,
    MAX(storage_location) AS storage_location,
    MAX(comment) AS volume_comment,
    MAX(created) AS volume_created_at,
    MAX(created_by) AS volume_created_by
  FROM volume_match
)
SELECT
  assert_true(
    matching_volume_count = 1,
    CONCAT('Required volume not found: ', :catalog_use, '.', :schema_use, '.session_audio')
  ) AS session_audio_volume_exists,
  assert_true(
    has_managed_volume = 1,
    CONCAT('Volume exists but is not MANAGED: ', :catalog_use, '.', :schema_use, '.session_audio')
  ) AS session_audio_volume_is_managed,
  detected_volume_type AS volume_type,
  storage_location,
  volume_comment,
  volume_created_at,
  volume_created_by,
  CONCAT('/Volumes/', :catalog_use, '/', :schema_use, '/session_audio') AS expected_volume_files_api_path
FROM volume_summary;

WITH target_table_match AS (
  SELECT *
  FROM system.information_schema.tables
  WHERE table_catalog = :catalog_use
    AND table_schema = :schema_use
    AND table_name = 'transcript_events_raw'
)
SELECT
  assert_true(
    COUNT(*) = 1,
    CONCAT('Required target table not found: ', :catalog_use, '.', :schema_use, '.transcript_events_raw')
  ) AS transcript_events_raw_exists,
  MAX(table_type) AS target_table_type,
  MAX(data_source_format) AS data_source_format,
  MAX(storage_path) AS storage_path,
  'Required: transcript_events_raw must exist because the bootstrap job now creates it before this validation step.' AS notes
FROM target_table_match;

SELECT
  'platform_bootstrap_validation_complete' AS check_name,
  'schema, managed volume, and transcript_events_raw assertions passed' AS status,
  CONCAT(:catalog_use, '.', :schema_use) AS validated_schema,
  CONCAT('/Volumes/', :catalog_use, '/', :schema_use, '/session_audio') AS validated_volume_path,
  CONCAT(:catalog_use, '.', :schema_use, '.transcript_events_raw') AS validated_target_table_name;