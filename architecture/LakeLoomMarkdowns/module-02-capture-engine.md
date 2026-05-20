# Module 02 — CaptureEngine + ChunkAssembler

**Product:** lakeLoom
**Status:** File-upload pipeline shipped (PRs #24, #26, #27, #28). Live transcription + chunk streaming still in design phase. See §1.5 for the implementation-status map.
**Last updated:** 2026-05-16
**Depends on:** AppCoordinator (for current project + workspace + user); AuthService + `LakeloomAppClient` (transport + signing); permissions (mic; speech when transcription lands)
**Depended on by:** IngestService (consumes the chunk stream), StorageService (consumes audio file events), Module 08 UI (subscribes to `CaptureService.stateUpdates()`)

---

## 1. Purpose

CaptureEngine owns the audio capture pipeline. It converts a button press (Quick Capture v1) or a recording session (Meeting Mode v1.x) into:

1. A stream of finalized **transcript chunks** with timing, confidence, and trigger metadata (ZeroBus path)
2. A single **session audio file** persisted locally and uploaded to a UC Volume at the end of the session (multipart-upload path)
3. A pair of **session lifecycle events** (`sessionStart`, `sessionEnd`) bound to a server-side `app.capture_sessions` row
4. (PRs 5–6, in flight) **Screenshots** and **photos** as additional artifacts attached to the same capture session

ChunkAssembler is a sub-component of CaptureEngine. It is the policy layer that decides when an in-flight transcript becomes a finalized chunk. The split exists because the audio plumbing (AVAudioEngine, SpeechAnalyzer, file writer) is platform mechanics, while chunking rules are business logic that will evolve as Meeting Mode lands and as we tune it.

CaptureEngine does **not** know about ZeroBus directly, Core Data, or the network. The transcript-chunk path emits `AsyncStream<CaptureEvent>` (IngestService consumes it); the file-upload path emits `PendingUpload` onto the `UploadCoordinator` queue. Both paths share the same `app.capture_sessions` lifecycle on the server.

---

## 1.5 Implementation Status

The module spans two parallel pipelines, both feeding the same server-side capture session:

```
                 ┌────────────────────────────────────────────────┐
                 │  user taps Record  →  CaptureService.start...  │
                 └────────────────────┬───────────────────────────┘
                                      │
                  ┌───────────────────┴───────────────────┐
                  ▼                                       ▼
    ┌───────────────────────────┐         ┌────────────────────────────┐
    │  Live transcription path  │         │   File-upload path         │
    │   (§§2–13, still design)  │         │  (§§17–20, shipped)        │
    │                           │         │                            │
    │  AVAudioEngine tap        │         │  AVAudioRecorder writes    │
    │    ↓                      │         │  M4A/AAC to disk           │
    │  TranscriberFeed →        │         │    ↓                       │
    │    SpeechAnalyzer         │         │  on stop:                  │
    │    ↓                      │         │    FileSHA256 → multipart  │
    │  ChunkAssembler builds    │         │    → UploadCoordinator     │
    │    TranscriptChunk        │         │    → POST .../audio        │
    │    ↓                      │         │                            │
    │  IngestService → ZeroBus  │         │  uploads land in UC Volume │
    └───────────────────────────┘         │  rows in app.uploads       │
                                          └────────────────────────────┘
```

| Component | Status | Section |
|-----------|--------|---------|
| `CaptureService` orchestration + state machine | **shipped (PR #28)** | §20 |
| `CaptureAPIClient` (4 session lifecycle endpoints) | **shipped (PR #24)** | §17 |
| `AudioRecorder` (M4A/AAC to disk) | **shipped (PR #26)** | §7 + §18 |
| `UploadCoordinator` (persistent queue + multipart + retry) | **shipped (PR #27)** | §19 |
| `FileSHA256` streaming hasher | **shipped (PR #28)** | §19.1 |
| Camera photo capture | **in flight (PR 5)** | §18.5 (TBD) |
| Screen broadcast capture | **planned (PR 6)** | — |
| Module 08 UI integration | **planned (PR 7)** | Module 08 doc |
| `AVAudioEngine` dual-tap architecture | **design only** | §5 |
| `TranscriberFeed` + `SpeechAnalyzer` integration | **design only** | §6 |
| `ChunkAssembler` policy + `TranscriptChunk` emission | **design only** | §8 |
| Live `PartialTranscript` stream | **design only** | §3.2 |

§§2–16 below describe the **transcription pipeline** that's still to build. §§17–20 (appended after the original design) document the **file-upload pipeline** as built.

The two pipelines coexist by design: when the transcription pipeline lands, `AVAudioEngine` will tap the mic input twice — one tap feeds `AVAudioRecorder` (or its `AVAudioFile`-based replacement) for the M4A file, the other feeds `SpeechAnalyzer` for live transcription. The file-upload path stays unchanged; chunks emit in parallel via the existing `CaptureEvent` stream contract.

### 1.5.1 Backend dependencies

| Backend asset | Status (as of 2026-05-16) | Blocks iOS-side work? |
|---------------|----------------------------|------------------------|
| `app.capture_sessions` table + 4 lifecycle routes | live on dev | ✓ no — file pipeline shipped against it |
| `app.uploads` table + `/api/captures/:id/audio` route | live on dev (iosAuth fix shipped 2026-05-16; downstream 500 with Genie) | partial — audio uploads currently failing 500 after auth |
| UC Volumes for audio / screenshots / documents | provisioned | ✓ no |
| ZeroBus target table in Unity Catalog | **provisioned 2026-05-16** | — needed only when transcription pipeline (§§2–16) lands |
| ZeroBus producer streams | **not wired** | — needed only when transcription pipeline lands |

The ZeroBus target table being ready without producers is the correct ordering: iOS won't have anything to publish until `SpeechAnalyzer` + `ChunkAssembler` land on this side. When that work starts, Genie will need to wire up the producer pipeline so the existing target table starts receiving rows.

---

## 2. Design Principles

1. **One session at a time.** No concurrent capture sessions. Starting a new one while one is active is a programming error (precondition failure in debug, graceful no-op in release with a warning).
2. **Audio plumbing is independent of transcription.** The audio file is written from the raw input tap. SpeechAnalyzer runs in parallel, fed from the same buffers. If transcription fails mid-session, audio is still preserved and can be re-transcribed later.
3. **Chunks are events, not state.** ChunkAssembler emits a finalized chunk and immediately resets — it never holds a "current chunk" view that callers can poll.
4. **Live transcript preview is separate from the finalized chunk stream.** The UI gets a separate `AsyncStream<PartialTranscript>` for the pulsing live text. Only finals go to the chunk stream.
5. **Schema-complete chunks.** ChunkAssembler builds the full payload defined in the architecture doc (§3 of `ios-app-architecture.md`), including `vad.trigger_reason`, `prior_chunk_tail`, `audio_reference`, and `speakers`. IngestService never has to enrich a chunk.
6. **Quick Capture is a degenerate Meeting Mode.** Same code path, different policy. The mode parameter selects ChunkAssembler behavior; everything below ChunkAssembler is identical.
7. **Failure surfaces, never swallows.** Audio session interruptions, route changes, transcription engine errors, and recording errors all surface as typed events on the stream. The UI is responsible for showing them; the engine just reports.
8. **Tear-down is symmetric and idempotent.** `stopSession()` can be called multiple times safely. Crashes mid-session leave a recoverable file on disk.

---

## 3. Public Surface

### 3.1 Protocol

```swift
protocol CaptureEngineProtocol: Sendable {
    /// Stream of finalized capture events. One stream per CaptureEngine instance,
    /// shared across all subscribers. Events arrive in strict per-session order.
    var events: AsyncStream<CaptureEvent> { get }

    /// Stream of partial transcripts for live UI display. Not persisted, not sent.
    /// Resets to empty between sessions.
    var partials: AsyncStream<PartialTranscript> { get }

    /// True while a session is active.
    var isCapturing: Bool { get async }

    /// Begin a new capture session. Throws if a session is already active or
    /// preconditions fail (no mic permission, no speech permission, audio session error).
    func startSession(_ request: CaptureRequest) async throws -> SessionHandle

    /// Finalize the active session. Flushes any in-flight chunk, closes the audio
    /// file, emits sessionEnd, and tears down the audio engine. Idempotent.
    func stopSession(reason: SessionTerminationReason) async

    /// Quick Capture only: a press-and-hold UI calls this when the user releases
    /// the button. Equivalent to stopSession(reason: .userStop) but signals the
    /// chunk assembler that the trigger reason for the final chunk is .userRelease.
    func releaseQuickCaptureButton() async
}
```

### 3.2 Value Types

```swift
struct CaptureRequest: Sendable {
    let mode: CaptureMode
    let projectID: String
    let workspaceID: String
    let userIdentity: UserIdentity        // from AuthService
    let workspaceMetadata: WorkspaceMetadata
    let consentVersion: String
    let consentAcknowledgedAt: Date
}

enum CaptureMode: String, Sendable, Codable {
    case quickCapture = "quick_capture"
    case meeting = "meeting"
}

struct SessionHandle: Sendable, Equatable {
    let sessionID: String                 // UUIDv7
    let mode: CaptureMode
    let startedAt: Date
}

enum CaptureEvent: Sendable {
    case sessionStarted(SessionStartedEvent)
    case chunkFinalized(TranscriptChunk)
    case sessionEnded(SessionEndedEvent)
    case audioFileFinalized(AudioFileEvent)   // local file ready for upload pickup
    case warning(CaptureWarning)              // non-fatal (e.g., route change)
    case error(CaptureError)                  // fatal for the session
}

struct PartialTranscript: Sendable {
    let sessionID: String
    let text: String                      // best-so-far text, may grow or shrink
    let asOfOffsetMs: Int64               // ms since session start
}

enum SessionTerminationReason: String, Sendable {
    case userStop = "user_stop"
    case userRelease = "user_release"     // Quick Capture button released
    case appBackgrounded = "app_backgrounded"
    case interrupted = "interrupted"      // phone call, Siri, etc.
    case error = "error"
}

enum CaptureWarning: Sendable {
    case routeChanged(newRoute: String)   // headphones plugged/unplugged
    case mediaServicesReset
    case lowConfidence(threshold: Double)
    case batteryLow(level: Float)
}

enum CaptureError: Error, Sendable, Equatable {
    case sessionAlreadyActive
    case microphonePermissionDenied
    case speechPermissionDenied
    case audioSessionFailed(reason: String)
    case engineFailed(reason: String)
    case transcriberFailed(reason: String)
    case recorderFailed(reason: String)
    case fileSystemFailed(reason: String)
    case invalidRequest(reason: String)
}
```

### 3.3 The TranscriptChunk Type

Mirrors the ZeroBus schema exactly (top-level columns + variant `headers` + variant `payload`). IngestService serializes this directly:

```swift
struct TranscriptChunk: Sendable, Codable, Equatable {
    // Top-level columns
    let recordUUID: String                // UUIDv7
    let sessionID: String
    let projectID: String
    let workspaceID: String
    let username: String
    let userUUID: String
    let deviceTimestamp: Date
    let chunkStartOffsetMs: Int64
    let chunkEndOffsetMs: Int64
    let captureMode: CaptureMode
    let sequenceNumber: Int32
    let eventType: EventType              // .transcriptChunk for this struct
    let schemaVersion: String             // "1.0.0"

    // Variant fields, fully populated
    let headers: ChunkHeaders
    let payload: ChunkPayload
}

enum EventType: String, Sendable, Codable {
    case transcriptChunk = "transcript_chunk"
    case sessionStart = "session_start"
    case sessionEnd = "session_end"
    case audioUploaded = "audio_uploaded"
}
```

The full shape of `ChunkHeaders` and `ChunkPayload` follows the architecture doc §3.2–3.6. Defined in a shared `ZeroBusSchema.swift` so IngestService and CaptureEngine reference identical types.

---

## 4. Internal Architecture

```
                              CaptureEngine (actor)
                                     │
        ┌────────────────────────────┼────────────────────────────┐
        │                            │                            │
        ▼                            ▼                            ▼
┌─────────────────┐         ┌─────────────────┐         ┌─────────────────┐
│ AudioGraph      │         │ TranscriberFeed │         │ AudioRecorder   │
│ (AVAudioEngine, │         │ (SpeechAnalyzer,│         │ (Opus encoder + │
│  session, tap)  │         │  SpeechTrans-   │         │  file writer)   │
│                 │         │  criber)        │         │                 │
└────────┬────────┘         └────────┬────────┘         └────────┬────────┘
         │                           │                           │
         │     PCM buffers           │                           │
         ├──────────────────────────►│                           │
         │                           │                           │
         ├───────────────────────────┼──────────────────────────►│
         │                           │                           │
         │                           ▼                           │
         │                  ┌─────────────────┐                  │
         │                  │ ChunkAssembler  │                  │
         │                  │ (policy: mode-  │                  │
         │                  │  driven, chunk  │                  │
         │                  │  finalization)  │                  │
         │                  └────────┬────────┘                  │
         │                           │                           │
         ▼                           ▼                           ▼
                          AsyncStream<CaptureEvent>
```

### 4.1 Concurrency

- `CaptureEngine` is a Swift `actor`. Public methods serialize through it.
- `AudioGraph` runs the AVAudioEngine on the platform's real-time audio thread (Apple's choice; we don't control it). The tap closure hops buffers onto a custom `AudioProcessingActor` for downstream handoff.
- `TranscriberFeed` runs as a background `Task` that consumes from the audio actor and feeds `SpeechAnalyzer.AnalyzerInputSequence`. Output (a `SpeechTranscriber.ResultSequence`) is consumed by ChunkAssembler.
- `AudioRecorder` runs on its own background `Task`, consuming from the audio actor and writing Opus frames to disk via a streaming encoder.
- `ChunkAssembler` is an actor. It receives transcriber results, decides chunk boundaries, builds `TranscriptChunk` values, and yields them to the engine's event continuation.
- The events stream is a single `AsyncStream` with a multicast adapter — any number of subscribers can listen. Backpressure is bounded buffer (100 events; if exceeded, oldest dropped with a warning event emitted).

### 4.2 Session Lifecycle

```
Idle ──► startSession() ──► Configuring ──► Capturing ──► Finalizing ──► Idle
            │                    │              │              │
            │                    │              │              └─ flush + emit
            │                    │              │                 sessionEnded +
            │                    │              │                 audioFileFinalized
            │                    │              │
            │                    │              └─ chunks stream out
            │                    │
            │                    └─ emit sessionStarted
            │
            └─ permissions, audio session, engine prepare
```

The state machine is enforced inside the actor; transitions are atomic with respect to caller calls. Mid-state crashes (e.g., the app being killed during Capturing) are handled at the next launch by a recovery pass — see §10.

---

## 5. AudioGraph — Capture Pipeline

### 5.1 AVAudioSession Configuration

```swift
let session = AVAudioSession.sharedInstance()
try session.setCategory(
    .playAndRecord,
    mode: .measurement,
    options: [.allowBluetooth, .defaultToSpeaker, .duckOthers]
)
try session.setPreferredSampleRate(16_000)
try session.setPreferredIOBufferDuration(0.02)   // ~20ms buffers
try session.setActive(true, options: [])
```

Choices and rationale:

- **`.playAndRecord`** rather than `.record` so the app could later play back audio (e.g., review a session); also more permissive for route handling.
- **`.measurement`** mode disables AGC and other voice-processing effects. This is intentional: SpeechTranscriber's own front-end is better, and meeting-mode diarization (future) needs unprocessed audio. The trade-off is louder background noise on raw audio; we'll tune in v1.x if it hurts STT quality in practice.
- **`.allowBluetooth`** so users on AirPods get good capture.
- **`.defaultToSpeaker`** so playback (if any) goes to the speaker not earpiece.
- **`.duckOthers`** so background music dims while recording.
- **16 kHz preferred** because that's SpeechTranscriber's expected rate and our chosen Opus encode rate. The system may not honor 16 kHz on all devices; if not, we resample on tap.

### 5.2 Engine and Tap

```swift
let engine = AVAudioEngine()
let inputNode = engine.inputNode
let inputFormat = inputNode.inputFormat(forBus: 0)

// Target format: 16 kHz, mono, Float32 PCM
let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false
)!

let converter = AVAudioConverter(from: inputFormat, to: targetFormat)

inputNode.installTap(
    onBus: 0,
    bufferSize: 4_096,
    format: inputFormat
) { [weak self] buffer, time in
    // Hop off the audio thread immediately.
    let converted = self?.convert(buffer, using: converter, to: targetFormat)
    Task { [weak self] in
        await self?.audioActor.ingest(buffer: converted, time: time)
    }
}

try engine.start()
```

The tap closure is the only place we touch the real-time audio thread. We do the format conversion synchronously (it's cheap) but everything else is hopped off with a Task into the audio actor.

### 5.3 AudioProcessingActor

```swift
actor AudioProcessingActor {
    private var subscribers: [AsyncStream<AudioBuffer>.Continuation] = []

    func subscribe() -> AsyncStream<AudioBuffer> {
        AsyncStream { continuation in
            subscribers.append(continuation)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(continuation) }
            }
        }
    }

    func ingest(buffer: AVAudioPCMBuffer?, time: AVAudioTime) {
        guard let buffer else { return }
        let stamped = AudioBuffer(pcm: buffer, time: time, ingestedAt: Date())
        for sub in subscribers {
            sub.yield(stamped)
        }
    }
}
```

TranscriberFeed and AudioRecorder each call `subscribe()` once at session start. They consume in parallel without blocking each other. If one consumer falls behind (e.g., disk write stall), it sees gaps via timestamps but doesn't slow the other.

### 5.4 Route Change and Interruption Handling

Two `NotificationCenter` observers, registered at session start and removed at end:

- `AVAudioSession.routeChangeNotification` — emit `.warning(.routeChanged(...))`. We do not stop the session on route changes; AirPods unplugged mid-meeting should fall back to the built-in mic seamlessly.
- `AVAudioSession.interruptionNotification` — `.began` triggers `stopSession(reason: .interrupted)`. `.ended` is logged but we don't auto-resume — the user must explicitly restart. This matches Voice Memos' behavior and keeps consent crisp.

`AVAudioSession.mediaServicesWereResetNotification` is the nuclear case: we tear down everything, emit a warning + error, and require the user to start a new session.

---

## 6. TranscriberFeed — SpeechTranscriber Integration

iOS 26's `SpeechAnalyzer` is the long-form transcription API. We use `SpeechTranscriber` (the speech-to-text module) configured for our locale.

### 6.1 Setup

```swift
import Speech

actor TranscriberFeed {
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AnalyzerInputSequence.Continuation?
    private var resultsTask: Task<Void, Never>?

    func start(locale: Locale, mode: CaptureMode) async throws {
        // Authorize
        let auth = await SFSpeechRecognizer.requestAuthorization()
        guard auth == .authorized else {
            throw CaptureError.speechPermissionDenied
        }

        // Configure transcriber module
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: mode == .meeting ? .progressiveTranscription : .offlineTranscription
        )

        // Ensure the on-device model is downloaded. iOS 26 lazy-downloads model
        // assets per locale; the first session for a new locale may stall here.
        try await SpeechAnalyzer.AssetInventory.ensure(modules: [transcriber])

        analyzer = SpeechAnalyzer(modules: [transcriber])
        let (sequence, continuation) = AnalyzerInputSequence.makeStream()
        inputBuilder = continuation
        try await analyzer?.start(input: sequence)

        // Drain results in a background task.
        resultsTask = Task { [weak self] in
            guard let results = await self?.analyzer?.results(for: transcriber) else { return }
            for try await result in results {
                await self?.handleResult(result)
            }
        }
    }
}
```

Notes:

- **Preset choice.** `.offlineTranscription` is tuned for batch quality; `.progressiveTranscription` for live captioning latency. Quick Capture chunks are short and we want best-in-class accuracy → use offline preset. Meeting Mode prioritizes live preview → use progressive preset.
- **Asset download.** iOS 26 ships the SpeechTranscriber model on demand. First-launch UX must show "Preparing speech model..." with a determinate progress spinner if download is needed. The `AssetInventory.ensure` call is async and reports progress.
- **Locale.** v1 is `en-US`. The mechanism supports any locale SpeechTranscriber supports.

### 6.2 Feeding Audio

TranscriberFeed subscribes to `AudioProcessingActor` and forwards buffers:

```swift
func runFeedLoop(audioStream: AsyncStream<AudioBuffer>) async {
    for await buffer in audioStream {
        guard let inputBuilder else { return }
        let input = AnalyzerInput(buffer: buffer.pcm, time: buffer.time)
        inputBuilder.yield(input)
    }
    inputBuilder?.finish()
}
```

### 6.3 Result Handling

```swift
private func handleResult(_ result: SpeechTranscriber.Result) async {
    if result.isFinal {
        // Forward to ChunkAssembler with timing and confidence.
        await chunkAssembler.acceptFinal(
            text: result.bestTranscription.formattedString,
            startOffsetMs: result.range.lowerBound.toMilliseconds(),
            endOffsetMs: result.range.upperBound.toMilliseconds(),
            confidence: result.confidence
        )
    } else {
        // Forward to partials stream for UI preview.
        partialsContinuation.yield(PartialTranscript(
            sessionID: currentSessionID,
            text: result.bestTranscription.formattedString,
            asOfOffsetMs: result.range.upperBound.toMilliseconds()
        ))
    }
}
```

> **Note on the SpeechAnalyzer API surface:** the exact type names above (`AnalyzerInputSequence`, `SpeechTranscriber.Result`, `range`) are the conceptual shape from the iOS 26 API. The first implementation pass should be against the actual SDK; this design will be refined to match the precise type names. Behavior is correct; nominal types may differ.

### 6.4 Stopping

`SpeechAnalyzer.finalize()` flushes any pending partial as a final result. We `await` it during session teardown so ChunkAssembler sees the last final before we emit `sessionEnded`. Then `analyzer?.stop()` and the results task is cancelled.

---

## 7. AudioRecorder — Opus Encoding to Disk

> **As-built (2026-05-16):** v1 shipped with **M4A/AAC** (the "fallback" described in §7.2 below). The current `LiveAudioRecorder` wraps `AVAudioRecorder` with iOS defaults rather than libopus. The Opus path remains the design target for v1.1+ when compression matters at scale; the file-upload pipeline is content-type-agnostic past the `MultipartFormBuilder` so the encoder swap is contained. See §18 for what's actually running.

Runs in parallel with TranscriberFeed, consuming the same audio actor stream. Writes a single Ogg-Opus file per session.

### 7.1 File Layout

```
<AppSupport>/sessions/<session_id>/
├── audio.opus            # main file, written incrementally
├── audio.opus.tmp        # being-written file; renamed on close
└── meta.json             # written on session start; updated on close
```

`meta.json` carries enough info to recover after a crash: `sessionID`, `startedAt`, `mode`, `projectID`, `workspaceID`, `userUUID`, and a `state` field (`writing`, `closed`, `aborted`).

### 7.2 Encoder

We use **libopus** via a thin Swift wrapper. Apple's AVAudioConverter cannot output Opus directly. Two implementation options:

1. **libopus + ogg muxer** statically linked. Mature, ~200KB binary cost, proven.
2. **AVAudioFile with .m4a / AAC** as a fallback if Opus integration is delayed. Works out of the box, slightly larger files (~25 KB/sec vs ~16 KB/sec Opus at 16 kbps mono speech).

v1 ships with Opus. AAC fallback is the contingency if libopus integration becomes a schedule risk.

Encoding parameters:

- 16 kHz mono input
- 16 kbps target bitrate (sufficient for speech, very small files)
- Frame size 20 ms (matches our buffer cadence)
- VBR with constrained ceiling

### 7.3 Streaming Write

```swift
actor AudioRecorder {
    private var encoder: OpusEncoder?
    private var oggMuxer: OggMuxer?
    private var fileHandle: FileHandle?
    private var bytesWritten: Int64 = 0
    private var samplesEncoded: Int64 = 0
    private var sha256 = SHA256Digest.builder()

    func runWriteLoop(audioStream: AsyncStream<AudioBuffer>) async {
        for await buffer in audioStream {
            do {
                let oggPages = try encoder!.encode(buffer.pcm)
                for page in oggPages {
                    try fileHandle!.write(contentsOf: page)
                    bytesWritten += Int64(page.count)
                    sha256.update(data: page)
                }
                samplesEncoded += Int64(buffer.pcm.frameLength)
            } catch {
                await reportError(.recorderFailed(reason: error.localizedDescription))
                return
            }
        }
        await close()
    }
}
```

### 7.4 Close and Finalize

On session end:

1. Drain any encoder-buffered samples (`encoder.finish()` returns final Opus frames)
2. Write Ogg trailer pages
3. Sync the file to disk (`fileHandle.synchronize()`)
4. Compute final SHA-256
5. Rename `audio.opus.tmp` → `audio.opus`
6. Update `meta.json` to `state: closed` with final size, duration, sha256
7. Emit `.audioFileFinalized(AudioFileEvent)` on the events stream

The `AudioFileEvent`:

```swift
struct AudioFileEvent: Sendable, Equatable {
    let sessionID: String
    let localPath: URL
    let durationMs: Int64
    let sizeBytes: Int64
    let sha256: String
    let format: AudioFormat              // .opus, .aac (fallback)
    let sampleRate: Int                  // 16000
    let bitrate: Int                     // 16000
}
```

StorageService picks this up and adds it to the upload queue.

---

## 8. ChunkAssembler — The Policy Layer

ChunkAssembler is the only place where chunking rules live. CaptureEngine constructs it with a `CaptureMode` and a session-scoped context, then forwards SpeechTranscriber finals to it.

### 8.1 Inputs

```swift
struct AssemblerContext: Sendable {
    let sessionID: String
    let mode: CaptureMode
    let sessionStartedAt: Date
    let projectID: String
    let workspaceID: String
    let user: UserIdentity
    let workspace: WorkspaceMetadata
    let project: ProjectMetadata
    let device: DeviceMetadata
    let consentVersion: String
    let consentAcknowledgedAt: Date
    let audioFormat: AudioFormat
    let audioSampleRate: Int
}

actor ChunkAssembler {
    private let context: AssemblerContext
    private var sequenceNumber: Int32 = 0
    private var lastChunkUUID: String?
    private var lastChunkTail: String?            // last ~5s of prior chunk
    private var pendingFinals: [TranscriberFinal] = []
    private var lastFinalEndOffsetMs: Int64 = 0

    private struct TranscriberFinal {
        let text: String
        let startOffsetMs: Int64
        let endOffsetMs: Int64
        let confidence: Double
        let arrivedAt: Date
    }
}
```

### 8.2 Quick Capture Policy

**Rule:** A Quick Capture session emits exactly one chunk per press-and-hold. The chunk's text is the concatenation of all SpeechTranscriber finals received between button-down and button-up. The trigger reason is `user_release`.

```swift
func acceptFinal(_ final: TranscriberFinal) async {
    pendingFinals.append(final)
    lastFinalEndOffsetMs = max(lastFinalEndOffsetMs, final.endOffsetMs)
    // Quick Capture: do nothing else. We finalize on releaseQuickCaptureButton().
}

func finalizeQuickCaptureChunk(triggerReason: TriggerReason) async -> TranscriptChunk {
    let combinedText = pendingFinals
        .sorted { $0.startOffsetMs < $1.startOffsetMs }
        .map(\.text)
        .joined(separator: " ")
    let avgConfidence = pendingFinals.isEmpty
        ? 0.0
        : pendingFinals.map(\.confidence).reduce(0, +) / Double(pendingFinals.count)
    let startMs = pendingFinals.map(\.startOffsetMs).min() ?? 0
    let endMs = pendingFinals.map(\.endOffsetMs).max() ?? 0
    let chunk = buildChunk(
        text: combinedText,
        startOffsetMs: startMs,
        endOffsetMs: endMs,
        confidence: avgConfidence,
        triggerReason: triggerReason,
        silenceDurationMs: nil,
        speakers: [.singleUser(start: startMs, end: endMs)]
    )
    pendingFinals.removeAll()
    return chunk
}
```

If a Quick Capture session has no transcript finals (the user pressed the button silently or released too fast for any speech), we still emit a chunk with empty text. This is intentional: it preserves the session record on the silver side and surfaces "you tried to record but nothing was captured" downstream.

### 8.3 Meeting Mode Policy (v1.x, designed-in for v1)

Three triggers for chunk finalization, evaluated continuously:

1. **Silence detected.** No SpeechTranscriber final received for ≥ 1.2 seconds AND no buffer-level speech detected (using the energy floor on raw audio buffers as a corroborating signal).
2. **Speaker turn.** A speaker change is detected. v1 has no on-device diarization, so this trigger is dormant in v1; v1.x adds it via near/far-field heuristic or a pyannote/Picovoice CoreML model. The finalization path is in place; only the detection source changes.
3. **30-second ceiling.** If a chunk has been open for 30 seconds with no other trigger firing, we close it on the next sentence boundary (end-of-final). The 30s is a soft ceiling — we wait for the current SpeechTranscriber final to land rather than cutting mid-utterance.

```swift
func acceptFinal(_ final: TranscriberFinal) async {
    pendingFinals.append(final)
    lastFinalEndOffsetMs = max(lastFinalEndOffsetMs, final.endOffsetMs)
    // Schedule a silence check: if no new final arrives in 1.2s, close.
    silenceTask?.cancel()
    silenceTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(1200))
        if Task.isCancelled { return }
        await self?.finalizeOnSilence()
    }
    // Check ceiling.
    if pendingChunkDurationMs() >= 30_000 {
        await finalizeOnCeiling()
    }
}

func handleSpeakerTurn(at offsetMs: Int64, newSpeaker: SpeakerLabel) async {
    await finalizeOnSpeakerTurn(offsetMs: offsetMs)
}
```

### 8.4 The `prior_chunk_tail` Mechanism

After each chunk is emitted, ChunkAssembler stores the last ~5 seconds of its text:

```swift
private func updatePriorTail(from chunk: TranscriptChunk) {
    let words = chunk.payload.transcript.text.split(separator: " ")
    // Approximate "last 5 seconds" as the last 12 words; tune later.
    let tailWords = words.suffix(12)
    lastChunkTail = tailWords.joined(separator: " ")
    lastChunkUUID = chunk.recordUUID
}
```

The next chunk's `payload.context` is populated:

```swift
context: ChunkContext(
    priorChunkUUID: lastChunkUUID,
    priorChunkTail: lastChunkTail
)
```

On the first chunk of a session, both fields are nil. The 5-second / 12-word approximation is intentionally heuristic; it can be refined to true 5-second-of-audio alignment later by mapping word offsets to audio timeline.

### 8.5 The `vad.energy_floor_db` Field

CaptureEngine maintains a rolling window of audio buffer RMS values from the audio actor. When ChunkAssembler builds a chunk, it queries the energy floor for the chunk's time range and embeds it. Useful for downstream silver-layer quality scoring (very-low-energy chunks may be background captures and should be deprioritized).

### 8.6 Sequence Numbering

Strictly monotonic per session, starting at 0 for `sessionStarted`, 1 for the first chunk, etc. Session lifecycle events also get sequence numbers so the silver pipeline can detect missing events of any kind.

```swift
private func nextSequence() -> Int32 {
    sequenceNumber += 1
    return sequenceNumber
}
```

### 8.7 UUIDv7 Generation

Same approach as elsewhere in the app:

```swift
struct UUIDv7 {
    static func generate() -> String {
        let now = Date().timeIntervalSince1970
        let unixMs = UInt64(now * 1000)
        var bytes = [UInt8](repeating: 0, count: 16)
        // 48 bits ms timestamp
        bytes[0] = UInt8((unixMs >> 40) & 0xFF)
        bytes[1] = UInt8((unixMs >> 32) & 0xFF)
        bytes[2] = UInt8((unixMs >> 24) & 0xFF)
        bytes[3] = UInt8((unixMs >> 16) & 0xFF)
        bytes[4] = UInt8((unixMs >> 8) & 0xFF)
        bytes[5] = UInt8(unixMs & 0xFF)
        // version 7
        bytes[6] = 0x70 | UInt8.random(in: 0...0x0F)
        bytes[7] = UInt8.random(in: 0...0xFF)
        // variant 10xx
        bytes[8] = 0x80 | UInt8.random(in: 0...0x3F)
        for i in 9..<16 { bytes[i] = UInt8.random(in: 0...0xFF) }
        // Format as canonical UUID string
        return formatUUIDString(bytes)
    }
}
```

A single `UUIDv7` helper lives in a shared module (`App/Common/UUIDv7.swift`) used by AuthService, IngestService, ChunkAssembler, etc.

---

## 9. Session Start and End Events

### 9.1 `sessionStarted`

Emitted immediately after the audio engine successfully starts and before any chunk could be produced.

```swift
let sessionStartedEvent = SessionRecord(
    recordUUID: UUIDv7.generate(),
    sessionID: handle.sessionID,
    sequenceNumber: 0,
    eventType: .sessionStart,
    payload: SessionStartPayload(
        deviceBatteryLevel: UIDevice.current.batteryLevel,
        deviceThermalState: ProcessInfo.processInfo.thermalState.encoded
    ),
    headers: buildHeaders(...)
)
events.yield(.sessionStarted(sessionStartedEvent))
```

The `sessionStarted` record has no transcript, but it carries the full headers block — this is what the silver pipeline keys off to open a session window before any chunk arrives.

### 9.2 `sessionEnded`

Emitted after:
1. SpeechAnalyzer is finalized (any pending transcriber final has been processed)
2. ChunkAssembler has flushed its pending chunk (if any)
3. AudioRecorder has closed the file and emitted `.audioFileFinalized`

Carries:

```swift
SessionEndPayload(
    totalDurationMs: Date().timeIntervalSince(sessionStartedAt) * 1000,
    totalChunks: chunkCountEmitted,
    audioUploadIntent: audioFile != nil ? .pending : .none,
    terminationReason: reason
)
```

### 9.3 Ordering Guarantee

The event stream emits in this strict order:
1. `sessionStarted`
2. Zero or more `chunkFinalized`
3. Zero or one `audioFileFinalized`
4. `sessionEnded`

`warning` events can be interleaved anywhere. `error` events terminate the sequence prematurely (no further events for that session).

---

## 10. Crash Recovery

Sessions can die mid-flight: app force-quit, OS jetsam, device crash. CaptureEngine performs a **recovery pass** at app start, inside an `init`-time hook called by AppCoordinator before any UI is shown:

1. List `<AppSupport>/sessions/`. For each directory, read `meta.json`.
2. For any session where `state == "writing"`:
   - Try to repair the Opus file: read until the last valid Ogg page, truncate to that boundary
   - If repair succeeds, emit a synthetic `audioFileFinalized` event for it (so StorageService picks it up for upload)
   - Mark `state = "recovered"` in meta.json
3. For any session where `state == "closed"` but no upload record exists in Core Data (StorageService territory) → handed off to StorageService's recovery
4. Sessions older than the configured retention period (default 7 days) with no transcript activity are deleted

The recovery pass does **not** attempt to re-emit transcript chunks. SpeechTranscriber state isn't recoverable across app restarts. The audio file is preserved and can be re-transcribed server-side from the upload.

A `sessionEnded` event with `terminationReason: .interrupted` is synthesized for recovered sessions and pushed to IngestService so the silver pipeline doesn't see a dangling session window.

---

## 11. Permissions Flow

CaptureEngine itself does not present permission prompts. AppCoordinator owns that UX. CaptureEngine throws typed errors:

| Condition | Error |
|---|---|
| `AVAudioSession` mic permission `.denied` or `.undetermined` | `.microphonePermissionDenied` |
| `SFSpeechRecognizer` auth `.denied` or `.restricted` | `.speechPermissionDenied` |
| Either `.undetermined` | engine pre-flight requests; if user denies, returns above |

Both prompts are deferred until the first `startSession` call, so the user sees them in context (immediately after pressing the capture button for the first time, with the rationale strings making sense).

---

## 12. Threading and Backpressure

### 12.1 Streams and Buffers

| Stream | Buffer policy | Subscriber count |
|---|---|---|
| `AudioProcessingActor` audio buffers | Per-subscriber AsyncStream, no buffer limit (bounded by 20ms cadence) | 2 (transcriber, recorder) |
| `partials` (UI live preview) | Bounded 1; latest wins | 1 (Home view) |
| `events` (CaptureEvent) | Bounded 100; oldest dropped + warning | N (Ingest, Storage, UI) |

### 12.2 Multicast Implementation

A simple multicast helper:

```swift
actor EventMulticaster<T: Sendable> {
    private var continuations: [UUID: AsyncStream<T>.Continuation] = [:]

    func subscribe() -> AsyncStream<T> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id: id) }
            }
        }
    }

    func emit(_ value: T) {
        for cont in continuations.values { cont.yield(value) }
    }
}
```

### 12.3 Slow Consumer Behavior

If IngestService's outbox writer falls behind (Core Data on a slow device), CaptureEngine never blocks. The bounded events buffer drops oldest events. A `warning(.eventDropped(...))` is emitted when this happens. In practice, Core Data writes at ~1ms each and chunks arrive at ~one per 5-10s in Quick Capture / one per 5-15s in Meeting Mode, so this is a margin-safety check, not an expected scenario.

---

## 13. Test Strategy

### 13.1 Unit Tests

- **ChunkAssembler Quick Capture:** zero finals → empty chunk emitted with correct trigger; multiple finals → joined text; sequence number increments correctly; `prior_chunk_tail` populated on second chunk
- **ChunkAssembler Meeting Mode:** silence trigger fires after 1.2s of no finals; ceiling trigger fires at 30s; speaker turn trigger flushes immediately; multiple triggers in rapid succession produce correct sequence
- **UUIDv7:** time-orderability across many generations; collision rate within tolerance
- **AudioGraph:** session category configuration; tap installation; route change handling (with mock notifications)
- **AudioRecorder:** Opus encoding round-trip; SHA-256 stability; tmp → final rename atomicity; recovery from partial write
- **TranscriberFeed:** result handling for finals vs partials; finalize() flushes pending; permission denial maps correctly

### 13.2 Integration Tests

- Pre-recorded WAV → AudioGraph → TranscriberFeed → ChunkAssembler → expected chunks (golden test corpus per language)
- Quick Capture: 3-second hold with known speech → exactly one chunk, expected text within Levenshtein distance of expected
- Meeting Mode: 60-second multi-utterance recording → expected number of chunks (within ±1 due to silence detection variance)
- Crash simulation: kill the app mid-session, relaunch, verify recovery emits `audioFileFinalized` with valid Opus

### 13.3 Test Seams

```swift
protocol AudioGraph { /* ... */ }
protocol TranscriberFeedProtocol { /* ... */ }
protocol AudioRecorderProtocol { /* ... */ }
```

Production: `LiveAudioGraph`, `LiveTranscriberFeed`, `LiveAudioRecorder`. Test: `MockAudioGraph` (replays a fixture WAV), `StubTranscriberFeed` (scriptable result sequences), `InMemoryAudioRecorder` (no disk).

---

## 14. Out of Scope for v1

- **On-device diarization.** Meeting Mode in v1.x uses near/far-field as a crude signal. True diarization (pyannote / Picovoice Falcon CoreML) is v2.
- **Wake-word activation.** Decided out at the architecture level. Not revisited here.
- **Live preview corrections.** SpeechTranscriber may revise partials; we forward the latest verbatim. v1 doesn't animate diffs.
- **Multi-language switching mid-session.** v1 fixes the locale at session start.
- **Background session continuation.** v1 stops capture if the app is backgrounded for >30 seconds (audio session retention is best-effort). v1.x adds the `audio` background mode + Live Activity for true background capture.

---

## 15. Open Items

| # | Item | Resolution Path |
|---|---|---|
| 1 | Final SpeechAnalyzer/SpeechTranscriber API names and result shapes | First implementation pass against iOS 26 SDK; refine type names in this doc |
| 2 | libopus integration approach (statically linked vs Swift Package wrapper) | Spike with both; pick lower-risk path |
| 3 | AAC fallback decision criteria | Establish a clear schedule trigger (e.g., libopus not integrated by week N → switch) |
| 4 | Energy floor window length and aggregation (mean vs min) | Start with 100ms windows, mean across the chunk's range; tune from real recordings |
| 5 | Quick Capture maximum hold duration | Default to 5 minutes hard cap; revisit after user testing |
| 6 | Meeting Mode silence threshold (1.2s) tuning | Validate against discovery-call recordings; expose as a debug setting in v1.x |
| 7 | Whether `prior_chunk_tail` is word-count or audio-time aligned | v1: word-count approximation. Refine to audio-time in v1.x with TimedToken alignment. |
| 8 | Behavior on `mediaServicesWereResetNotification` | v1: emit error, require user restart. Consider auto-recovery in v2. |

---

## 16. File Layout (proposed)

```
App/Capture/
├── CaptureEngine.swift                   // actor, public surface
├── CaptureEngineProtocol.swift           // protocol + value types + errors
├── CaptureEvent.swift
├── SessionHandle.swift
├── AudioGraph/
│   ├── AudioGraph.swift                  // protocol
│   ├── LiveAudioGraph.swift
│   ├── AudioProcessingActor.swift
│   ├── AudioBuffer.swift
│   ├── AudioSessionConfigurator.swift
│   └── RouteChangeObserver.swift
├── Transcriber/
│   ├── TranscriberFeed.swift             // protocol
│   ├── LiveTranscriberFeed.swift
│   ├── SpeechAnalyzerBridge.swift
│   └── TranscriberPermissions.swift
├── Recorder/
│   ├── AudioRecorder.swift               // protocol
│   ├── LiveAudioRecorder.swift
│   ├── OpusEncoder.swift                 // libopus wrapper
│   ├── OggMuxer.swift
│   ├── SessionFileLayout.swift
│   └── SessionMetaJSON.swift
├── Assembler/
│   ├── ChunkAssembler.swift
│   ├── AssemblerContext.swift
│   ├── ChunkBuilder.swift
│   ├── QuickCapturePolicy.swift
│   ├── MeetingModePolicy.swift
│   └── EnergyFloorTracker.swift
├── Recovery/
│   ├── SessionRecoveryPass.swift
│   └── OpusFileRepair.swift
└── Schema/
    ├── ZeroBusSchema.swift               // shared with IngestService
    ├── TranscriptChunk.swift
    ├── ChunkHeaders.swift
    ├── ChunkPayload.swift
    └── UUIDv7.swift                      // shared utility
```

Tests mirror this layout under `AppTests/Capture/`.

---

# Part II — As-Built File-Upload Pipeline (PRs #24, #26, #27, #28)

This appendix documents what's actually running today. It pairs with §§2–16 above: §§2–16 describe the live-transcription / ZeroBus path that's still in design; §§17–20 below describe the audio-file / multipart-upload path that's shipped and exercising against dev. Both paths attach to the same `app.capture_sessions` row, so the lifecycle endpoints (§17) serve both.

---

## 17. CaptureAPIClient — Server-Side Session Lifecycle

The four-route transport client for `app.capture_sessions`. All routes go through `LakeloomAppClient.request(...)` so they inherit the full two-layer iosAuth (Layer 0 M2M bearer + Layer 1 session token + ECDSA over canonical form). No bespoke URLRequest construction; no bespoke signing.

### 17.1 Protocol

```swift
public protocol CaptureAPIClient: Sendable {
    func createCaptureSession(
        workspaceID: String, projectID: String,
        label: String?, clientTimestamp: Date?
    ) async throws -> CaptureSession

    func updateCaptureSession(
        workspaceID: String, captureSessionID: String,
        state: CaptureSession.EndState, endedAt: Date?
    ) async throws -> CaptureSession

    func getCaptureSession(
        workspaceID: String, captureSessionID: String,
        includeUploads: Bool
    ) async throws -> CaptureSession

    func listProjectCaptureSessions(
        workspaceID: String, projectID: String,
        state: CaptureSession.State?, limit: Int, before: Date?
    ) async throws -> [CaptureSession]
}
```

### 17.2 Routes

| Method | Path | Caller | Purpose |
|--------|------|--------|---------|
| `POST` | `/api/projects/:project_id/captures` | `CaptureService.startCapture` | Open active session |
| `PATCH` | `/api/captures/:capture_session_id` | `CaptureService.stopCapture`/`cancelCapture`/watcher | Terminal transition |
| `GET` | `/api/captures/:capture_session_id?include=uploads` | smoke-test sheet, Module 08 sessions tab | Detail + uploads |
| `GET` | `/api/projects/:project_id/captures` | smoke-test sheet, Module 08 sessions tab | History list |

### 17.3 Value Types

`CaptureSession` mirrors `app.capture_sessions` exactly. `State` is `.active | .completed | .cancelled`; `EndState` is `.completed | .cancelled` (only terminal targets — `.active` can't be re-entered). Wire format uses snake_case (`project_id`, `started_at`, etc.); iOS maps via explicit `CodingKeys`.

### 17.4 Error Mapping

`CaptureAPIError` is the typed surface (§8.1 in Part I of this doc, restated):

| Status / source | `CaptureAPIError` case |
|-----------------|------------------------|
| `workspaceNotConfigured` | `.notSignedIn` |
| 400 | `.validationFailed(reason)` |
| 403 | `.forbidden(reason)` |
| 404 | `.notFound` |
| 409 | `.invalidTransition(reason)` |
| 401 (token kinds) | `.authFailed(reason)` |
| `URLError.notConnectedToInternet` | `.networkUnavailable` |
| `URLError.timedOut` | `.timeout` |
| 5xx | `.serverUnavailable(status, reason)` |
| Decode failure | `.decodeFailed(reason)` |
| anything else | `.unexpectedResponse(reason)` |

---

## 18. AudioRecorder — Shipped Implementation

The `LiveAudioRecorder` actor that's running today. M4A/AAC instead of Opus (see §7's as-built note).

### 18.1 Protocol

```swift
public protocol AudioRecorder: Sendable {
    func start(captureSessionID: String) async throws -> URL
    func stop() async throws -> AudioRecording
    func cancel() async
    var state: AudioRecorderState { get async }
}

public enum AudioRecorderState: Sendable, Equatable {
    case idle
    case recording(captureSessionID: String, startedAt: Date)
}

public struct AudioRecording: Sendable, Equatable, Hashable {
    public let captureSessionID: String
    public let fileURL: URL
    public let startedAt: Date
    public let endedAt: Date
    public let durationSeconds: Double
    public let sizeBytes: Int64
    public let mimeType: String          // always "audio/mp4"
    public let fileExtension: String     // always "m4a"
}
```

### 18.2 Engine Seam

`LiveAudioRecorder` doesn't wrap `AVAudioRecorder` directly. It delegates CoreAudio specifics to an `AudioRecordingEngine` protocol so the recorder's state machine + file layout can be unit-tested without real audio hardware. The live engine handles permission, session config, file-write start/stop. Tests inject a fake engine.

### 18.3 File Layout

```
<Application Support>/Captures/<captureSessionID>/audio-<ISO8601>.m4a
```

The `Captures/` directory is flagged `isExcludedFromBackup = true` so recordings (server-of-truth-on-Databricks) don't bloat iCloud backups.

### 18.4 Encoder Settings

iOS defaults via `AVAudioRecorder`:

- `AVFormatIDKey = kAudioFormatMPEG4AAC`
- `AVSampleRateKey = 44_100.0` (44.1 kHz)
- `AVNumberOfChannelsKey = 1` (mono)
- `AVEncoderAudioQualityKey = AVAudioQuality.medium.rawValue`

Genie's server-side MIME allowlist accepts both `audio/m4a` and `audio/mp4`; iOS sends `audio/mp4`.

### 18.5 Future: Camera + Screen Capture (PR 5/6)

The same protocol-seam pattern will apply for the camera (`AVCapturePhotoOutput`) and screen-broadcast (`ReplayKit` extension) paths. Each will produce a finalized file on disk + a value type with metadata; `CaptureService` will hand them to `UploadCoordinator` exactly the way audio does today.

---

## 19. UploadCoordinator — Persistent Upload Pipeline

The multipart-upload queue that drains finalized files from disk to UC Volume routes.

### 19.1 Protocol

```swift
public protocol UploadCoordinator: Sendable {
    func enqueue(_ pending: PendingUpload) async throws
    func currentUploads() async -> [PendingUpload]
    func stateUpdates() async -> AsyncStream<UploadStateChange>
    func retry(uploadID: String) async
    func discard(uploadID: String) async
    func start() async
    func stop() async
}

public struct PendingUpload: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let workspaceID: String
    public let captureSessionID: String
    public let kind: Kind                       // .audio | .screenshot | .photo | .document
    public let localFileURL: URL
    public let mimeType: String
    public let sizeBytes: Int64
    public let sha256Hex: String                // streaming SHA-256 from FileSHA256
    public let clientTimestamp: Date            // wall-clock at capture time
    public let originalFilename: String?
    public let createdAt: Date
    public var state: State
    public var attempts: Int
    public var nextAttemptAt: Date?
    public var lastError: String?
    public var remoteUploadID: String?          // populated on success
}

public enum State: Sendable, Equatable, Codable {
    case queued
    case uploading
    case succeeded
    case failed(reason: String, permanent: Bool)
}
```

### 19.2 Persistence

The queue mirrors to disk at `<Application Support>/Captures/upload-queue.json` on every state change. Writes are atomic (tmp + rename) so a crash mid-write leaves the prior good snapshot intact. `JSONEncoder.dateEncodingStrategy = .iso8601`, sorted keys for deterministic on-disk hashing if needed later.

On `start()`, the worker rehydrates the snapshot. Uploads stuck in `.uploading` from a prior launch are revived as `.queued` (the `revive` method) so a force-quit mid-upload is recoverable.

### 19.3 Retry Policy

Hard-coded backoff array: `[2, 4, 8, 16, 32]` seconds, max 5 attempts. The worker `await sleep(...)` is injected so tests can stub it.

Permanent-vs-transient classification (in `isPermanent(error:)`):

| `LakeloomAppError` case | Permanent? |
|------------------------|-----------|
| `.networkUnavailable` | no |
| `.timeout` | no |
| `.transport(...)` | no |
| `.httpError(408 or 429 or 5xx, ...)` | no |
| `.httpError(other 4xx, ...)` | yes |
| `.tokenExchangeFailed` / `.unauthorized` | yes (route to re-pair) |
| `.decodeFailed` / `.workspaceNotConfigured` | yes |

Permanent failures park the upload in the queue at `.failed(permanent: true)`. The user (via `retry` UI in PR 7) or the smoke-test sheet's "Clear failed uploads" action can re-queue or drop it.

### 19.4 Multipart Body

`MultipartFormBuilder.build` constructs an RFC 2046-compliant `multipart/form-data` body. Field order:

```
--<boundary>\r\n
Content-Disposition: form-data; name="client_ts"\r\n
\r\n
<unix-seconds string>\r\n
--<boundary>\r\n
Content-Disposition: form-data; name="client_filename"\r\n
\r\n
<filename>\r\n
--<boundary>\r\n
Content-Disposition: form-data; name="sha256_hex"\r\n
\r\n
<lowercase hex digest>\r\n
--<boundary>\r\n
Content-Disposition: form-data; name="file"; filename="<filename>"\r\n
Content-Type: <mime>\r\n
\r\n
<raw file bytes>\r\n
--<boundary>--\r\n
```

Boundary is `lakeloom.<UUID>`. Per the 2026-05-16 contract resolution: `BODY_SHA256_HEX` in the canonical form is `sha256(full multipart envelope)` — boundary markers + part headers + part bodies + closing boundary. Server-side iosAuth was updated to read raw bytes via `getRawBody` for non-JSON content types, hash those, and replay to busboy via `Readable.from(buffer)`.

### 19.5 FileSHA256

Streaming hash over a file URL via CryptoKit + `FileHandle`:

```swift
enum FileSHA256 {
    static let defaultChunkSize = 1 * 1024 * 1024  // 1 MiB

    static func hex(of url: URL, chunkSize: Int = defaultChunkSize) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = try? handle.read(upToCount: chunkSize)
            guard let chunk, !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
```

`autoreleasepool` per chunk keeps memory pressure flat on multi-MB recordings.

---

## 20. CaptureService — Orchestration + State Machine

The glue layer. Owns one in-flight `CaptureContext`, exposes an `AsyncStream<CaptureServiceState>` for UI binding, and runs a background watcher that drains `pendingUploadIDs` and patches the server-side session to `.completed` when uploads finish.

### 20.1 State Machine

```
                ┌────────────┐
                │   .idle    │◀───────────────────────────┐
                └─────┬──────┘                            │
        startCapture  │                                   │ (next startCapture)
                      ▼                                   │
            ┌─────────────────────┐                       │
            │     .recording      │◀─────────┐            │
            │   (CaptureContext)  │          │            │
            └──┬────────────────┬─┘          │            │
   stopCapture │                │  cancelCapture          │
               ▼                ▼                         │
   ┌─────────────────────┐  ┌──────────────────────┐      │
   │     .finalizing     │  │     .cancelled       │──────┤
   │ (CaptureContext,    │  │   (CaptureContext)   │      │
   │  pendingUploadIDs)  │  └──────────────────────┘      │
   └────┬──────────┬─────┘                                │
        │          │  cancelCapture                       │
        │          ▼                                      │
        │   ┌──────────────────────┐                      │
        │   │     .cancelled       │──────────────────────┤
        │   └──────────────────────┘                      │
        │                                                 │
        │  (watcher: pendingUploadIDs becomes empty)      │
        ▼                                                 │
   ┌─────────────────────┐                                │
   │     .completed      │────────────────────────────────┘
   │   (CaptureContext)  │
   └─────────────────────┘
```

Any of `start`, `stop`, hashing, or enqueue can also surface `.failed(reason)`; the next successful `startCapture` resets to `.recording`.

### 20.2 Watcher Race Avoidance

The watcher subscribes to `UploadCoordinator.stateUpdates()` **synchronously inside `stopCapture`** before returning. Earlier attempts had the watcher Task subscribe inside its own body, racing the test harness's emit; that hung one test for 19 minutes. The fix is documented in code at `LiveCaptureService.spawnWatcher`.

### 20.3 Rollback Semantics

If `createCaptureSession` succeeds but `recorder.start` throws, the service best-effort patches the server-side session to `.cancelled` (errors swallowed and logged) before transitioning to `.failed`. No dangling `.active` rows.

### 20.4 Persistence Gap

`CaptureService` state is in-memory only. App-killed-mid-capture leaves:

- Recording on disk (recoverable from `<Application Support>/Captures/.../audio-*.m4a`)
- Upload queue (rehydrates via `UploadCoordinator.start()`)
- Server-side `app.capture_sessions` row stuck at `.active` (no rehydration)

Closing the persistence gap is tracked as a follow-on (capture-context snapshot to disk, similar to `UploadQueueStore`). The smoke-test sheet's PATCH actions provide a manual workaround for the demo.

---

## 21. Files Currently Shipped

```
iOS/App/Captures/
├── CaptureAPIClient.swift         # protocol + LiveCaptureAPIClient
├── CaptureAPIError.swift          # typed errors
├── CaptureSession.swift           # value type + State/EndState
├── CaptureService.swift           # protocol + state + errors
├── LiveCaptureService.swift       # orchestrating actor
├── FileSHA256.swift               # streaming hasher
├── EndpointSmokeTestView.swift    # #if DEBUG diagnostic sheet
├── Audio/
│   ├── AudioRecorder.swift            # protocol + state + Recording + errors
│   ├── AudioRecordingEngine.swift     # AVAudioRecorder seam + LiveAudioRecordingEngine
│   └── LiveAudioRecorder.swift        # actor implementation
└── Upload/
    ├── PendingUpload.swift            # value type + state machine
    ├── UploadCoordinator.swift        # protocol + errors
    ├── LiveUploadCoordinator.swift    # actor + worker loop + retry policy
    ├── UploadQueueStore.swift         # disk persistence
    └── MultipartFormBuilder.swift     # multipart/form-data builder

iOS/AppTests/Captures/
├── CaptureAPIClientTests.swift          (12 tests)
├── LiveCaptureServiceTests.swift        (10 tests)
├── Audio/
│   ├── FakeAudioRecordingEngine.swift
│   └── LiveAudioRecorderTests.swift     (10 tests)
├── Upload/
│   ├── LiveUploadCoordinatorTests.swift  (9 tests)
│   ├── MultipartFormBuilderTests.swift   (5 tests)
│   └── UploadQueueStoreTests.swift       (5 tests)
└── Helpers/
    ├── FakeCaptureAPIClient.swift
    ├── FakeAudioRecorder.swift
    └── FakeUploadCoordinator.swift
```

42 unit tests across the module. Full suite (LakeloomApp + LakeloomAppTests) passes in ~0.6s on iPhone 17 Pro simulator.
