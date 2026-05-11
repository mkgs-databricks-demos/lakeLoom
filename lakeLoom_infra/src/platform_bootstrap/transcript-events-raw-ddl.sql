-- Databricks notebook source
-- Create the ZeroBus target table used by lakeLoom transcript/event ingestion.
--
-- This task is intentionally idempotent so the platform bootstrap job can be
-- re-run safely. It creates the expected bronze table contract before the
-- final validation step.

USE CATALOG IDENTIFIER(:catalog_use);
USE SCHEMA IDENTIFIER(:schema_use);

SELECT
  current_timestamp() AS ddl_started_at,
  current_catalog() AS active_catalog,
  current_schema() AS active_schema,
  CONCAT(:catalog_use, '.', :schema_use, '.transcript_events_raw') AS target_table_name;

CREATE TABLE IF NOT EXISTS IDENTIFIER(:catalog_use || '.' || :schema_use || '.transcript_events_raw')
(
  event_id STRING NOT NULL COMMENT 'Producer-generated idempotency key or event identifier',
  session_id STRING COMMENT 'Application session identifier associated with the transcript/event payload',
  project_id STRING COMMENT 'Application project identifier associated with the transcript/event payload',
  user_id STRING COMMENT 'End-user identifier carried in the event payload for attribution beyond the shared SPN actor',
  device_id STRING COMMENT 'Paired-device identifier or label when available',
  event_type STRING NOT NULL COMMENT 'Logical event type such as partial_transcript, final_transcript, audio_uploaded, or client_status',
  event_time TIMESTAMP COMMENT 'Event timestamp supplied by the producer when available',
  ingested_at TIMESTAMP NOT NULL COMMENT 'Server-side ingest timestamp written by the producer or connector',
  transcript_text STRING COMMENT 'Transcript text for transcript-bearing events',
  transcript_language STRING COMMENT 'Language code associated with the transcript text when available',
  source_platform STRING COMMENT 'Origin platform for the event, such as ios',
  workspace_id STRING COMMENT 'Workspace identifier embedded in the event payload when available',
  headers VARIANT COMMENT 'Captured request metadata and non-sensitive headers as semi-structured JSON',
  body VARIANT COMMENT 'Full raw ZeroBus event payload stored as VARIANT for flexible bronze retention',
  CONSTRAINT transcript_events_raw_pk PRIMARY KEY (event_id)
)
USING DELTA
COMMENT 'Bronze ZeroBus target for lakeLoom transcript and session event ingestion from paired iOS devices'
TBLPROPERTIES (
  'delta.enableChangeDataFeed' = 'true',
  'delta.enableDeletionVectors' = 'true',
  'delta.enableRowTracking' = 'true',
  'delta.enableVariantShredding' = 'true',
  'quality' = 'bronze',
  'pipeline' = 'lakeloom_platform_bootstrap',
  'description' = 'ZeroBus streaming target table for transcript and pairing-related session events'
);

SHOW CREATE TABLE IDENTIFIER(:catalog_use || '.' || :schema_use || '.transcript_events_raw');

SELECT
  'transcript_events_raw_ready' AS check_name,
  'created_or_confirmed' AS status,
  CONCAT(:catalog_use, '.', :schema_use, '.transcript_events_raw') AS target_table_name;