# Lakeloom iOS App — Architecture Document

**Product:** Lakeloom
**Version:** 1.1
**Status:** Design — pre-implementation
**Last updated:** 2026-05-06

---

## 1. Project Overview

Lakeloom is an iOS application that captures spoken input — either from the user directly via a button tap, or eventually from ambient conversation — transcribes it on-device, and ships the resulting text to a **Databricks App** which forwards it to ZeroBus on the iPhone's behalf. A Spark Declarative Pipeline lands the data in silver and gold tables, where an Agent uses it to generate requirements, reference architectures, and Genie Code session plans for phased Databricks build engagements.

The iOS client speaks HTTPS to exactly one host: the Databricks App. The App is the network-boundary aggregator — it owns the ZeroBus TS SDK call, the Lakebase Postgres connection, and any other downstream Databricks integration. iOS does not speak gRPC to ZeroBus, does not connect directly to Lakebase, and does not call Databricks SQL Statement Execution. This single-network-boundary rule keeps iOS releases decoupled from server-side schema and backend choices, and constrains the iOS app's network/auth surface to a single OAuth-bearer-on-HTTPS pattern.

The name reflects the work the app does: pulling raw conversational threads (the *loom*) into structured material that flows into a Databricks lakehouse (the *lake*). Lakeloom is built primarily for Databricks Forward Deployed Engineers (FDEs) doing requirements gathering and rapid prototyping with customers in the field.

### 1.1 Target State

- Databricks Forward Deployed Engineers (FDEs) capture discovery conversations with customers in the field
- Captured content is structured into per-project knowledge in Databricks
- An Agent transforms that knowledge into actionable build artifacts (requirements docs, reference architectures, phased Genie Code session plans)
- The output drives faster, more consistent Databricks implementation engagements and rapid prototyping

### 1.2 Scope of This Document

This document covers the **iOS application only**. Downstream Databricks processing (Spark Declarative Pipeline, silver/gold layers, Agent design, Genie integration) is out of scope here but is the consumer of the data contract this document defines.

---

## 2. Key Design Decisions

A summary of the decisions locked in during design review:

| # | Decision | Rationale |
|---|---|---|
| 1 | Speech-to-text: Apple `SpeechAnalyzer` / `SpeechTranscriber` (iOS 26) on-device | Privacy first, free, low latency, offline-capable, no audio leaves device |
| 2 | Optional later re-transcription with WhisperKit (large model) | Higher fidelity for technical jargon; runs on uploaded audio in Databricks side or via background job |
| 3 | Chunking: layered triggers (silence ≥ 1.2s, speaker turn, 30s ceiling) | Maximizes downstream LLM reasoning quality; designed for Meeting Mode, applied trivially in Quick Capture |
| 4 | Quick Capture chunk = full press-and-hold duration (`trigger_reason: user_release`) | Simplest model for v1; same payload shape as Meeting Mode chunks |
| 5 | Transcript POSTed live as JSON to the Databricks App (which forwards to ZeroBus); audio uploaded post-session over Wi-Fi only directly to UC Volume Files API | Matches ZeroBus' event-stream design while preserving the single-network-boundary rule for iOS; audio bytes are large enough that a direct PUT is justified |
| 6 | Minimum iOS version: **iOS 26+** | Access to `SpeechAnalyzer` for native long-form transcription; eliminates restart-loop complexity |
| 7 | Capture modes: Quick Capture (v1) and Meeting Mode (v1.x); no wake word | Explicit user action keeps consent crisp; two clear modes cover both use cases |
| 8 | Identity: Databricks workspace OAuth U2M — workspace identity *is* the user identity | Single auth flow; same identity across devices; native joins to Databricks audit and Unity Catalog |
| 9 | Auth for App ingest endpoint + UC Volume audio upload: same OAuth U2M token | Single auth flow, no PAT pasting, refresh tokens for silent renewal |
| 10 | OAuth client: single published Databricks OAuth app, client_id baked into the iOS app, PKCE required | Standard mobile OAuth pattern |
| 11 | Projects: served by the Databricks App's REST API; iOS calls `GET/POST /api/v1/projects`. App owns whether storage is Lakebase or Delta | Decouples iOS releases from server-side schema; aligns with Lakebase rule of thumb |
| 12 | `project_id` is **NOT NULL** on every record | Forces project association at session start; enables per-project agent processing |
| 13 | Workspace details captured per session and selectable in app settings | Multi-workspace support (e.g., dev/prod, multi-customer consultants) |
| 14 | Records on the wire: JSON with VARIANT-shaped `headers` and `payload` nested objects; App serializes them to JSON strings before handing to the Zerobus TS SDK | Lets us add fields to headers/payload without iOS App Store updates while keeping Zerobus's bronze table contract stable |
| 15 | **Single network boundary on iOS**: HTTPS to the Databricks App for ingest, projects, and sync; HTTPS to UC Files API only for audio upload | One TLS surface to validate, one cookie/auth model, no gRPC tooling, no Postgres client on iOS |
| 16 | **Lakebase access via the App's REST API only** — never directly from iOS | Server owns Postgres connection management, credential rotation, and schema migrations; iOS sees only a versioned JSON contract |
| 17 | App-side Brickster edits surface back to iOS via a cursor-based polling endpoint (Module 11) | Polling in v1; APNs nudges + WebSocket in v1.x without changing the consumer contract |

---

## 3. Ingest Data Contract

The contract between the iOS app and the Databricks App's ingest endpoint. iOS POSTs records as JSON to the App; the App forwards them to ZeroBus, which lands them in the bronze table. The schema below is the iOS-visible shape, intentionally aligned with the bronze table's columns so the App's translation is mechanical.

The app emits records of four event types: `transcript_chunk`, `session_start`, `session_end`, and `audio_uploaded`.

### 3.1 Top-Level Columns (typed)

| Column | Type | Nullable | Description |
|---|---|---|---|
| `record_uuid` | STRING | NOT NULL | UUIDv7 from device — sortable by time, primary dedup key |
| `session_id` | STRING | NOT NULL | UUIDv7, groups all records from one capture session |
| `project_id` | STRING | NOT NULL | Required; foreign key to the project table |
| `workspace_id` | STRING | NOT NULL | Databricks workspace selected for this session |
| `username` | STRING | NOT NULL | Databricks SCIM `userName` (typically email) |
| `user_uuid` | STRING | NOT NULL | Databricks SCIM user `id` (stable across renames) |
| `device_timestamp` | TIMESTAMP | NOT NULL | When the chunk was finalized on device, microsecond precision |
| `chunk_start_offset_ms` | BIGINT | NOT NULL | Milliseconds from session start to chunk start |
| `chunk_end_offset_ms` | BIGINT | NOT NULL | Milliseconds from session start to chunk end |
| `ingest_timestamp` | TIMESTAMP | NOT NULL | Set by ZeroBus on receipt |
| `capture_mode` | STRING | NOT NULL | `quick_capture` or `meeting` |
| `sequence_number` | INT | NOT NULL | Monotonic per session, for gap detection |
| `event_type` | STRING | NOT NULL | `transcript_chunk`, `session_start`, `session_end`, `audio_uploaded` |
| `schema_version` | STRING | NOT NULL | Semver, e.g. `1.0.0` |
| `headers` | VARIANT | NOT NULL | Device, user, workspace, project, session, transcription, network metadata |
| `payload` | VARIANT | NOT NULL | Event-type-specific content |

### 3.2 Headers (VARIANT)

```json
{
  "device": {
    "model": "iPhone16,2",
    "os_version": "26.1",
    "app_version": "1.0.0",
    "app_build": "142",
    "locale": "en-US",
    "timezone": "America/Los_Angeles"
  },
  "user": {
    "user_uuid": "1234567890123456",
    "username": "jhammond@acme.com",
    "display_name": "Jeff Hammond",
    "auth_method": "oauth_u2m"
  },
  "workspace": {
    "workspace_id": "1234567890123456",
    "workspace_url": "https://acme-prod.cloud.databricks.com",
    "workspace_name": "ACME Production",
    "workspace_region": "us-west-2",
    "cloud": "aws",
    "selected_at": "2026-05-02T18:14:18.220Z"
  },
  "project": {
    "project_id": "proj_01975e4f3a7c",
    "project_name": "Customer 360 Lakehouse",
    "project_created_at": "2026-04-20T14:00:00.000Z"
  },
  "session": {
    "started_at": "2026-05-02T18:14:22.331Z",
    "capture_mode": "quick_capture",
    "expected_audio_upload": true,
    "audio_format": "opus",
    "audio_sample_rate": 16000,
    "consent_acknowledged_at": "2026-05-02T18:14:20.110Z",
    "consent_version": "1.0"
  },
  "transcription": {
    "engine": "SpeechTranscriber",
    "engine_version": "iOS26.1",
    "model_locale": "en-US",
    "on_device": true
  },
  "network": {
    "connection_type": "wifi",
    "is_constrained": false
  }
}
```

### 3.3 Payload — `event_type: transcript_chunk`

```json
{
  "event_type": "transcript_chunk",
  "transcript": {
    "text": "We need to land customer events in Unity Catalog with a CDC pattern off the operational Postgres.",
    "is_final": true,
    "confidence": 0.94,
    "language_detected": "en-US"
  },
  "speakers": [
    {
      "speaker_label": "user",
      "start_offset_ms": 0,
      "end_offset_ms": 6420,
      "confidence": 1.0,
      "diarization_source": "capture_mode_inferred"
    }
  ],
  "audio_reference": {
    "session_audio_pending": true,
    "chunk_start_in_audio_ms": 12340,
    "chunk_end_in_audio_ms": 18760
  },
  "vad": {
    "trigger_reason": "user_release",
    "silence_duration_ms": null,
    "energy_floor_db": -52.3
  },
  "context": {
    "prior_chunk_uuid": "01975e4f-3a7c-7890-b1c2-d4e5f6a7b8c9",
    "prior_chunk_tail": "...so given the schema we discussed,"
  },
  "annotations": {
    "user_marked_important": false,
    "user_tag": null
  }
}
```

`vad.trigger_reason` enumerates: `user_release` (Quick Capture), `silence_detected`, `speaker_turn`, `ceiling_30s`, `session_end`, `interrupted`.

`speakers` is always an array. In Quick Capture it has one entry with `speaker_label: "user"` and `diarization_source: "capture_mode_inferred"`. In Meeting Mode multiple entries with real diarization metadata. The Agent reads the same shape regardless.

`context.prior_chunk_tail` carries the last ~5 seconds of the previous chunk's transcript text (not duplicated audio) to aid coreference resolution downstream.

### 3.4 Payload — `event_type: session_start`

```json
{
  "event_type": "session_start",
  "expected_chunks_estimate": null,
  "device_battery_level": 0.78,
  "device_thermal_state": "nominal"
}
```

Sent immediately when capture begins. Lets the silver pipeline open a session window.

### 3.5 Payload — `event_type: session_end`

```json
{
  "event_type": "session_end",
  "total_duration_ms": 47820,
  "total_chunks": 1,
  "audio_upload_intent": "pending",
  "termination_reason": "user_stop"
}
```

`audio_upload_intent` values: `pending` (will upload when Wi-Fi available), `none` (audio capture disabled), `failed_local` (audio file corrupted or missing).

`termination_reason` values: `user_stop`, `app_backgrounded`, `interrupted`, `error`.

### 3.6 Payload — `event_type: audio_uploaded`

```json
{
  "event_type": "audio_uploaded",
  "audio_uri": "/Volumes/main/lakeloom/session_audio/2026/05/02/<session_id>.opus",
  "audio_duration_ms": 47820,
  "audio_size_bytes": 384512,
  "audio_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "uploaded_at": "2026-05-02T19:02:14.110Z",
  "upload_duration_ms": 1840,
  "upload_network": "wifi"
}
```

Sent after the post-session Wi-Fi audio upload completes. Silver pipeline uses this to enrich the session row and trigger any re-transcription job.

### 3.7 Forward Compatibility

Schema is versioned (`schema_version` column). Variant fields can grow without schema migration. Top-level columns require coordinated migration. Meeting Mode requires zero schema changes — the `speakers` array carries multiple entries, `capture_mode` flips to `"meeting"`, `vad.trigger_reason` reflects the actual trigger.

---

## 4. iOS Application Architecture

### 4.1 Layer Diagram

```
┌─────────────────────────────────────────────────────────┐
│  UI Layer (SwiftUI)                                     │
│  - Home (capture button, project/workspace chips)       │
│  - Onboarding (consent → workspace → OAuth → project)   │
│  - Settings (account, workspaces, projects, storage)    │
│  - Sessions list (history, audio upload status)         │
└─────────────────────────────────────────────────────────┘
                           │
┌─────────────────────────────────────────────────────────┐
│  App Coordinator (Observable, app-level state)          │
│  - Current user, workspace, project                     │
│  - Active session (if any)                              │
│  - Network/Wi-Fi state                                  │
└─────────────────────────────────────────────────────────┘
                           │
┌────────────┬─────────────┬─────────────┬───────────────┐
│   Auth     │  Capture    │   Ingest    │   Storage     │
│  Service   │   Engine    │   Service   │   Service     │
└────────────┴─────────────┴─────────────┴───────────────┘
                           │
┌─────────────────────────────────────────────────────────┐
│  Platform: AVFoundation, Speech (iOS 26 SpeechAnalyzer),│
│  Network, CryptoKit, Keychain, Core Data, URLSession    │
└─────────────────────────────────────────────────────────┘
```

### 4.2 Module Responsibilities

#### AuthService
- OAuth 2.0 U2M flow via `ASWebAuthenticationSession` with PKCE
- Token storage in Keychain (access token, refresh token, workspace metadata) with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- Silent token refresh on 401 responses
- Multi-workspace support: stores an array of `WorkspaceCredential` records, one active at a time
- Exposes `currentToken() async throws -> String` to other services
- Fetches user identity from `/api/2.0/preview/scim/v2/Me` post-login and caches it

#### CaptureEngine
The heart of the app — owns the audio capture pipeline.
- Owns `AVAudioEngine` and the audio session
- Configures audio session: category `.playAndRecord`, mode `.measurement`, options `[.allowBluetooth, .defaultToSpeaker]`
- Installs a tap on the input node at 16 kHz mono (downsampled if needed)
- Feeds audio to two parallel consumers:
  1. **SpeechTranscriber** (iOS 26 long-form on-device transcription)
  2. **Audio recorder** writing Opus-encoded chunks to a local file
- Owns the **ChunkAssembler** which decides when a chunk is "done" based on capture mode rules
- Emits `Chunk` and `SessionLifecycleEvent` values via an `AsyncStream` for the IngestService

#### ChunkAssembler
Sub-component of CaptureEngine. Where the chunking rules live.
- Quick Capture: chunk = entire press-and-hold duration. Trigger reason: `user_release`.
- Meeting Mode (future): silence ≥ 1.2s OR speaker turn OR 30s ceiling. Carries `prior_chunk_tail` context.
- Always assigns `sequence_number`, `chunk_start_offset_ms`, `chunk_end_offset_ms`, computes `vad.energy_floor_db`
- Builds the full payload + headers per the schema in §3

#### IngestService
- Consumes the chunk stream from CaptureEngine
- POSTs batches to the Databricks App's ingest endpoint with the OAuth token from AuthService; the App forwards to ZeroBus
- Maintains a local **outbox** (Core Data table) — every chunk is persisted first, then sent
- Send success → marked sent; send failure → exponential backoff retry
- Network-aware: pauses sending on no-connectivity, resumes when network returns
- Survives app termination — pending chunks in outbox are sent on next launch

#### StorageService
- Manages local audio files in Application Support directory, keyed by `session_id`
- Tracks upload state per session in Core Data: `pending`, `wifi_waiting`, `uploading`, `uploaded`, `failed`
- Watches `NWPathMonitor` for Wi-Fi availability; when Wi-Fi appears and there's pending audio, kicks off uploads
- Uses background `URLSession` with `isDiscretionary = true`, `allowsCellularAccess = false` so iOS handles queuing
- After successful upload + `audio_uploaded` event sent (via the App's ingest endpoint), deletes local audio (configurable grace period; default 7 days)

### 4.3 Concurrency Model

Swift 6 strict concurrency throughout.
- CaptureEngine, IngestService, StorageService are `@MainActor`-isolated coordinators that delegate to nonisolated background actors for hot-path work
- Audio tap callbacks → custom `AudioProcessingActor`
- HTTP ingest writes → `IngestActor` (Module 03)
- All cross-actor communication via `AsyncStream` / `AsyncChannel`

---

## 5. Data Flow — Quick Capture Session

Walking through a single press-and-hold capture from button-down to ingested.

### 5.1 Pre-flight (before button can be pressed)
- AppCoordinator confirms `currentProject != nil` and `currentWorkspace != nil`
- AuthService confirms a valid token (refreshes silently if needed)
- Microphone permission granted (prompted at first capture if not yet granted)

### 5.2 Button down
- `CaptureEngine.startSession(mode: .quickCapture)` called
- New `session_id` (UUIDv7) generated
- Audio session activated
- `SessionLifecycleEvent.sessionStart` emitted → IngestService persists + POSTs to the Databricks App's ingest endpoint
- Audio file opened: `<AppSupport>/sessions/<session_id>.opus`
- SpeechTranscriber stream started
- Visual feedback: button pulses, transcript starts appearing live on screen

### 5.3 While held
- Audio buffers flow continuously to both the file writer and SpeechTranscriber
- Partial transcript results render live for user feedback (not POSTed to the App — only finals)
- Energy floor and duration tracked in real time

### 5.4 Button up
- ChunkAssembler finalizes the chunk: text, timing, energy floor, `trigger_reason: .userRelease`
- `Chunk` emitted → IngestService persists in outbox → POSTs to the Databricks App's ingest endpoint
- Audio file finalized and closed
- `SessionLifecycleEvent.sessionEnd` emitted with `audio_upload_intent: .pending`
- StorageService marks the audio file as `wifi_waiting`
- Capture engine tears down audio session

### 5.5 Async, after Wi-Fi appears
- StorageService detects Wi-Fi, computes the deterministic Volume path, uploads directly to UC Files API via background URLSession
- On completion: `SessionLifecycleEvent.audioUploaded` is enqueued in IngestService's outbox; the drainer POSTs it to the Databricks App's ingest endpoint with audio URI, sha256, size
- Local audio file scheduled for deletion after grace period

---

## 6. Authentication Flow

### 6.1 First-Launch Flow

1. **Consent screen** — what the app records, where it goes, microphone permission rationale
2. **Workspace URL entry** — with validation
3. **OAuth login** via `ASWebAuthenticationSession` (PKCE)
4. App exchanges authorization code for access token + refresh token
5. App fetches identity from `/api/2.0/preview/scim/v2/Me` and caches user details
6. **Project picker** — lists existing projects via `GET {appBaseURL}/api/v1/projects?workspace_id=...` for that workspace + "Create New" option; user must select before reaching the capture screen
7. **Microphone permission** prompt (deferred to here so the user understands context)
8. **Home screen** — Quick Capture button, current project chip, current workspace chip

### 6.2 OAuth Configuration

- **Client type:** Public client, single registered Databricks OAuth app, client_id baked into the iOS app
- **Per-customer setup:** Workspace admin enables the published OAuth app's client_id in their workspace settings (one-time admin action, documented in onboarding guide)
- **PKCE:** Mandatory. Code verifier + challenge generated per flow using `CryptoKit`
- **Redirect URI:** Custom URL scheme `lakeloom://oauth/callback`, registered in `Info.plist`
- **Auth flow:** `ASWebAuthenticationSession` (uses system cookie jar; supports passkey/biometric login on Databricks side)
- **Token storage:** Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- **Refresh:** Refresh token typically valid 90 days; access token typically 1 hour. Auth layer transparently refreshes on 401.

### 6.3 Multiple Workspace Support

Users may have multiple workspaces (dev/prod, multiple customer engagements for consultants). Settings supports adding multiple workspaces. Each session pins to one workspace selected at session start. Tokens are stored per-workspace, keyed by `workspace_id`.

---

## 7. Project Management

### 7.1 Storage

Projects are served by the **Databricks App's REST API**. The App owns the underlying storage — Lakebase Postgres is the default per lakeLoom's "Lakebase as the rule of thumb" preference. iOS sees only the JSON contract; storage migrations server-side don't require iOS releases. Full design is in Module 06 (`module-06-project-service.md`).

The iOS-visible `ProjectMetadata` shape:

```swift
struct ProjectMetadata: Sendable, Equatable, Identifiable, Codable {
    let id: String                     // UUIDv7
    let name: String
    let description: String?
    let workspaceID: String
    let createdByUserID: String
    let createdByUsername: String
    let createdAt: Date
    let updatedAt: Date
    let archived: Bool
}
```

### 7.2 Access Pattern

The iOS app calls the Databricks App's REST endpoints directly with the user's OAuth U2M token:

- `GET    /api/v1/projects?workspace_id={ws}&q={query}&limit=200`
- `GET    /api/v1/projects/{project_id}?workspace_id={ws}`
- `POST   /api/v1/projects` (with `client_generated_id` UUIDv7 for idempotency)
- `PATCH  /api/v1/projects/{project_id}/archive`
- `PATCH  /api/v1/projects/{project_id}/restore`

The App is the security boundary — it validates the OAuth token, applies workspace-scoped authorization, and persists to its backing store. iOS never sees Postgres credentials, never issues SQL, never resolves a SQL warehouse.

### 7.3 App Project Flow

- **Session start:** ProjectService calls `GET /api/v1/projects?workspace_id=...` and renders the result. Cache: 5-minute TTL with stale-while-revalidate so the picker is instant most of the time.
- **Create new:** Modal collects name + description; iOS generates a UUIDv7 `client_generated_id` and POSTs. The App treats `(workspace_id, client_generated_id)` as the idempotency key, so retries are safe.
- **Duplicate name handling:** atomic on the App side — HTTP 409 with `existing_project_id` in the response body.

### 7.4 Default Visibility

For v1: all projects in a workspace are visible to all workspace users. The App enforces workspace scoping using the OAuth identity from the bearer token. Per-user filtering and row-level security can be added later server-side without iOS changes — that's the decoupling benefit of the REST API approach.

---

## 8. Local Persistence (Core Data)

### 8.1 Entities

**SessionRecord**
- `session_id`, `project_id`, `workspace_id`, `started_at`, `ended_at`, `chunk_count`
- `audio_local_path`, `audio_upload_state` (pending / wifi_waiting / uploading / uploaded / failed)
- `audio_uri_remote`, `audio_sha256`, `audio_duration_ms`, `audio_size_bytes` (after upload)

**OutboxRecord**
- `record_uuid`, `session_id`, `event_type`, `sequence_number`
- `payload_json`, `headers_json`, all top-level typed fields
- `state` (pending / sent / failed_permanent)
- `retry_count`, `last_error`, `created_at`

**WorkspaceCredential**
- `workspace_id`, `workspace_url`, `workspace_name`, `is_default`
- Encrypted token references (actual tokens stored in Keychain keyed by `workspace_id`)

### 8.2 Outbox State Machine

```
[created] → pending → sent              (success)
                  ↓
                  → retry (backoff: 1s, 2s, 4s, 8s, 30s cap)
                  ↓
                  → failed_permanent    (after 4xx other than 401)
```

Failure handling:
- Network error → outbox retry with exponential backoff
- 401 → AuthService refresh, retry once
- 4xx other than 401 → log, mark `failed_permanent`, surface in Settings
- 5xx → outbox retry indefinitely (with backoff)

### 8.3 Project Cache

Projects are **not** persisted long-term — they're cached in memory with a 5-min TTL and re-fetched. Source of truth is the Databricks table.

---

## 9. Ingest Client Implementation

iOS does **not** speak gRPC to ZeroBus directly. The ingest client (`IngestProxyClient`, see Module 03) is a thin `URLSession` wrapper that POSTs JSON batches to the Databricks App. The App owns the ZeroBus TS SDK call.

- **Transport:** HTTPS POST with `application/json` body
- **Endpoint:** `POST {appBaseURL}/api/v1/ingest/snippets`
- **Auth:** OAuth bearer in the `Authorization` header (`Bearer <token>`); `X-Databricks-Workspace-Id` for routing; `X-Lakeloom-Schema-Version` for fast-fail on incompatible client versions
- **Batch shape:** `{ schema_version, records: [...] }`. Each record carries the typed top-level fields and *nested JSON objects* (not strings) for `headers` and `payload`. The App serializes them to JSON strings before handing to the Zerobus SDK.
- **Response:** synchronous per-record acks — `{ accepted: [...], rejected: [{record_uuid, reason}], ingest_timestamp }`. HTTP 207 for partial accept, 200 for full accept.
- **Outbox:** strict — no record is ever held only in memory; persisted to Core Data before the network call
- **Retry:** exponential backoff with jitter; HTTP 401 → force-refresh + single retry; HTTP 429 honors `Retry-After`
- **Idempotency:** `record_uuid` (UUIDv7, client-generated) is the dedup key; the App and silver layer dedupe on `(session_id, record_uuid)` so retrying an entire batch is always safe

The full design lives in Module 03. Earlier drafts called this `ZeroBusClient` and used gRPC-Swift directly; that has been replaced by the proxy approach above to satisfy lakeLoom's single-network-boundary rule for iOS.

---

## 10. Audio Upload Implementation

### 10.1 Wi-Fi Gating

- `NWPathMonitor` with `.requiresInterfaceType(.wifi)` to gate the upload
- Upload only kicks off when Wi-Fi is confirmed and unconstrained (not a personal hotspot)
- User can override per-session in Settings (advanced toggle)

### 10.2 Background URLSession

- Configured with `isDiscretionary = true` and `allowsCellularAccess = false`
- iOS queues the upload and waits for Wi-Fi automatically, even if the app is suspended or the user is on cellular for days
- Don't roll a custom retry loop — rely on the platform primitive

### 10.3 Local Persistence Until Upload

- Audio sits in the app's Application Support directory
- `isExcludedFromBackup` flag set so files don't bloat iCloud backups
- Keyed by `session_id`
- Core Data table tracks upload state

### 10.4 User Visibility

A "Sessions" list shows pending audio uploads with their status, so a user who's been on cellular understands why their session audio hasn't synced yet. Manual "force upload over cellular" option available per session.

### 10.5 Retention

After successful upload + acknowledgment from Databricks:
- Local audio deleted after configurable grace period (default 7 days)
- Grace period exists in case the silver pipeline needs a re-pull

---

## 11. Permissions and Capabilities

### 11.1 Info.plist Required Keys

- `NSMicrophoneUsageDescription` — required, requested at first capture
- `NSSpeechRecognitionUsageDescription` — required for SpeechTranscriber
- `NSAppTransportSecurity` — configured to allow only TLS 1.3 to Databricks domains
- URL types: custom scheme `lakeloom://` for OAuth redirect

### 11.2 Background Modes

- `audio` — so capture survives backgrounding
- `processing` — for background URLSession audio uploads

### 11.3 Capabilities

- Keychain Sharing (single app group) — for cross-target token access if app extensions added later
- Associated Domains (optional, future) — universal links for shared project links

---

## 12. UI Surface — v1

### 12.1 Onboarding

Linear flow on first launch:
1. Welcome / consent
2. Workspace URL entry
3. OAuth login (system browser via `ASWebAuthenticationSession`)
4. Identity confirmation ("Logged in as [Display Name]")
5. Project picker (existing or create new)
6. Microphone permission prompt
7. Land on Home

### 12.2 Home Screen

- Large Quick Capture button (press and hold to record)
- Current project chip (tap to change)
- Current workspace chip (tap to change)
- Live transcript preview while held
- Recent sessions strip below

### 12.3 Settings

- **Account:** signed-in user (read-only), sign-out
- **Workspaces:** list, add/remove, set default
- **Projects:** browse/create/archive, set default
- **Capture:** default mode (Quick Capture only in v1), audio upload policy (Wi-Fi only default + override toggle)
- **Storage:** local audio retention period, manual purge, total local storage used
- **Privacy:** consent version acknowledged, link to privacy policy

### 12.4 Sessions List

- All sessions chronologically
- Per-session: duration, project, audio upload status (Pending / Waiting for Wi-Fi / Uploading / Uploaded / Failed), chunk count
- Tap to view session detail with transcript
- Manual "force upload over cellular" per session

---

## 13. v1 Scope vs. Forward-Looking

### 13.1 Ships in v1

- Onboarding (consent → workspace → OAuth → project)
- Quick Capture button with live transcript preview
- Background ingest via the Databricks App's REST endpoint with outbox + retry
- Wi-Fi-only audio upload with status visibility and manual override
- Settings (account, workspaces, projects, storage)
- Sessions list with upload status
- Sign-out and multi-workspace switching

### 13.2 Stubbed For Future (Meeting Mode in v1.x)

The schema, capture engine, and chunk assembler all support Meeting Mode — the UI just doesn't expose it. To enable later:
- Add a mode toggle to the Home screen
- Implement silence detection in ChunkAssembler (Silero VAD CoreML model recommended)
- Implement near/far-field speaker hint as crude diarization signal
- Add Live Activity for "● Recording" indicator on lock screen
- No schema or pipeline changes needed

### 13.3 Forward-Looking — Not in v1.x

- WhisperKit re-transcription (likely a Databricks-side job, not iOS)
- True on-device diarization (pyannote / Picovoice Falcon)
- iPad app sharing the same identity model
- Push notifications for "your build plan is ready" from the Agent
- Sharing/exporting generated artifacts

---

## 14. Open Items

Items intentionally left for later, with the decisions that remain to be made:

| # | Topic | Notes |
|---|---|---|
| 1 | Project visibility model | Default v1: all-workspace. Decide whether to add per-user / per-team filtering later. |
| 2 | OAuth scope narrowing | v1 uses `all-apis`. Narrow to App invocation scope + Volume write later. |
| 3 | Username editability | Source of truth is SCIM. If user updates display name in Databricks, when does the app refresh? Decide on TTL. |
| 4 | Audio retention default | Default 7 days. Make configurable in Settings; possibly tied to per-workspace policy. |
| 5 | Telemetry | App-side metrics (crashes, capture failures, ingest latency). Not designed yet. |
| 6 | Crash reporting | Choose framework (Sentry, Firebase Crashlytics, or first-party). |
| 7 | Localization | English-only in v1. Speech models support other locales; UI strings need extraction. |
| 8 | Re-transcription trigger | Decide Databricks-side: every session, low-confidence chunks only, or on-demand. |

---

## Appendix A — Glossary

| Term | Meaning |
|---|---|
| ZeroBus | Databricks low-latency streaming ingestion service |
| U2M | OAuth User-to-Machine flow (interactive login, refresh tokens) |
| SCIM | System for Cross-domain Identity Management — Databricks identity API |
| PKCE | Proof Key for Code Exchange — OAuth security extension for public clients |
| VARIANT | Databricks semi-structured data type, queryable with `variant_get()` |
| UUIDv7 | Time-ordered UUID variant; high bits encode millisecond timestamp |
| VAD | Voice Activity Detection |
| Genie | Databricks AI/BI Genie — natural language interface to data |
| Genie Code | Code-generation capability associated with Genie |
| Silver / Gold | Standard Databricks medallion-architecture layer names |
