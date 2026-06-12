@preconcurrency import AVFoundation
import Foundation

/// Production ``AudioRecordingEngine`` backed by ``AVAudioEngine``.
///
/// Replaces ``LiveAudioRecordingEngine`` (which wraps the older
/// ``AVAudioRecorder`` API) for one reason: ``AVAudioEngine`` exposes
/// live PCM buffers via ``AVAudioInputNode/installTap(onBus:bufferSize:format:block:)``,
/// while ``AVAudioRecorder`` only writes a file and gives you no
/// way to consume the audio stream. The buffer-stream pipe is the
/// foundation PR 9b will use to wire live speech transcription —
/// the same audio source feeds both the file (for upload) and the
/// recognizer (for live transcript events).
///
/// File pipeline:
/// 1. ``start(writingTo:)`` configures `AVAudioSession`, creates an
///    `AVAudioEngine`, and installs an input tap that writes PCM
///    frames to a temporary `.caf` file via `AVAudioFile`.
/// 2. ``stop()`` removes the tap, stops the engine, and transcodes
///    the `.caf` → final `.m4a` at the caller-supplied URL via
///    `AVAssetExportSession`. The intermediate `.caf` is deleted.
/// 3. ``cancel()`` tears down without transcoding; deletes both
///    files.
///
/// Why CAF intermediate instead of writing AAC directly: `AVAudioFile`
/// on iOS supports PCM/CAF reliably; AAC encoding requires
/// `AVAssetWriter` with manual `CMSampleBuffer` construction, which
/// is brittle. `AVAssetExportSession` handles the CAF→AAC transcode
/// in 1-2 seconds for a 30s recording — well-tested, single API call.
/// The intermediate CAF is temporary; only the m4a is uploaded.
///
/// File-size note: a 30s recording produces ~5 MB of intermediate
/// CAF (48 kHz Float32 mono) and ~250 KB of final AAC m4a (~64 kbps).
actor EngineAudioRecordingEngine: AudioRecordingEngine, AudioBufferSource, AudioInterruptionPublishing {

    private var engine: AVAudioEngine?
    /// Thread-safe holder for the current `AVAudioFile` the tap is
    /// writing into. Wrapped (rather than holding the `AVAudioFile`
    /// directly) so the rotation logic can swap the underlying writer
    /// atomically without racing the real-time tap thread.
    private var writerHolder: AudioWriterHolder?
    private var sampleRate: Double = 0
    private var inputFormat: AVAudioFormat?
    private var startedAt: Date?
    /// URL the caller asked the final `.m4a` to be written to. In
    /// chunked mode, per-chunk M4A URLs are derived from this seed
    /// (see ``chunkFinalURL(seed:chunkIndex:)``).
    private var finalSeedURL: URL?
    /// Sibling `.caf` seed URL (same stem as `finalSeedURL`, `.caf`
    /// extension) used as the intermediate PCM file before transcoding.
    /// In chunked mode, per-chunk CAF URLs are derived from this seed.
    private var intermediateSeedURL: URL?
    /// 0-based index of the chunk currently being written by the tap.
    /// Starts at 0; bumped each time the rotation Task swaps the writer.
    private var activeChunkIndex: Int = 0
    /// Live PCM buffer stream. Created on `start()`, finished on
    /// `stop()` / `cancel()`. The speech recognizer subscribes via
    /// ``AudioBufferSource/buffers()``. Single-consumer.
    private var bufferStream: AsyncStream<PCMBufferEnvelope>?
    private var bufferContinuation: AsyncStream<PCMBufferEnvelope>.Continuation?
    /// Interruption events: yields `true` on `.began` (engine paused)
    /// and `false` on `.ended` (engine resumed, or paused-pending if
    /// iOS withheld `.shouldResume`). Created on `start()`, finished
    /// on `stop()` / `cancel()`.
    private var interruptionStream: AsyncStream<Bool>?
    private var interruptionContinuation: AsyncStream<Bool>.Continuation?
    private var isInterrupted = false
    /// `NotificationCenter` observer tokens — held so we can detach
    /// on stop/cancel and avoid leaking observers across recordings.
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    /// Periodic rotation Task. `nil` when `chunkDuration == nil`
    /// (single-chunk mode) or between recordings. Cancelled on stop /
    /// cancel; the rotation loop checks `Task.isCancelled` after each
    /// sleep and exits cleanly.
    private var rotationTask: Task<Void, Never>?
    /// In-flight finalization Tasks — one per closed chunk. `stop()`
    /// awaits all of them so the assembled `EngineStopArtifact` reflects
    /// every chunk's actual transcode outcome (M4A vs CAF fallback).
    private var pendingFinalizations: [Task<Void, Never>] = []
    /// Closed-out chunks. Each rotation appends one entry once its
    /// finalization Task completes; `stop()` sorts by `chunkIndex`
    /// before assembling the artifact. Mutated under actor isolation.
    private var finalizedChunks: [EngineStopArtifact.Chunk] = []
    private let logger: AppLogger
    /// Maximum number of `AVAssetExportSession.export()` attempts
    /// before falling back to CAF. Interruption is the most common
    /// failure mode and typically clears within a second; three
    /// attempts with a 500ms gap covers the realistic transient
    /// window.
    private let transcodeAttempts: Int
    /// Rotation interval. `nil` disables rotation entirely — the engine
    /// produces exactly one chunk per recording, identical to the
    /// pre-rotation behavior. When set (e.g. 300s = 5 min), the engine
    /// rotates `AVAudioFile` writers in place and finalizes each closed
    /// chunk through the same CAF→M4A transcode + fallback path.
    private let chunkDuration: TimeInterval?

    init(
        logger: AppLogger = AppLogger(category: .capture),
        transcodeAttempts: Int = 3,
        chunkDuration: TimeInterval? = nil
    ) {
        self.logger = logger
        self.transcodeAttempts = transcodeAttempts
        self.chunkDuration = chunkDuration
    }

    func currentPermission() async -> Bool? {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:    return true
        case .denied:     return false
        case .undetermined: return nil
        @unknown default: return nil
        }
    }

    func requestPermission() async -> Bool {
        if let known = await currentPermission() { return known }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start(writingTo url: URL) async throws {
        // Mirror LiveAudioRecordingEngine's session config so the
        // audio route + ducking behavior is identical to what
        // production users have been seeing. PR 9b may revisit the
        // mode for live speech recognition.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true, options: [])
        } catch {
            throw AudioRecorderError.sessionConfigurationFailed(reason: error.localizedDescription)
        }

        let avEngine = AVAudioEngine()
        let inputNode = avEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            throw AudioRecorderError.sessionConfigurationFailed(
                reason: "invalid input format: sr=\(format.sampleRate) ch=\(format.channelCount)"
            )
        }

        // Intermediate CAF lives in the same directory as the requested
        // .m4a but with a swapped extension. Same parent directory,
        // so caller-side cleanup logic (which already deletes the
        // capture's directory tree on cancel/failure) handles both
        // without explicit knowledge of the intermediate.
        let intermediateSeed = url.deletingPathExtension().appendingPathExtension("caf")
        let chunk0CAF = Self.chunkIntermediateURL(seed: intermediateSeed, chunkIndex: 0, chunked: chunkDuration != nil)
        // If a prior aborted run left a stale CAF behind, drop it
        // before opening a fresh writer.
        try? FileManager.default.removeItem(at: chunk0CAF)

        let writer: AVAudioFile
        do {
            writer = try AVAudioFile(forWriting: chunk0CAF, settings: format.settings)
        } catch {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            throw AudioRecorderError.fileSystemError(reason: "AVAudioFile init: \(error.localizedDescription)")
        }
        let holder = AudioWriterHolder(initial: writer)

        // PR 9b: also fan out audio buffers to a live stream so the
        // speech recognizer can consume them in parallel with the
        // file write. Single tap, two consumers — no parallel-engine
        // race condition that bit PR 8d.
        let (stream, streamContinuation) = AsyncStream<PCMBufferEnvelope>.makeStream()
        // The tap closure runs on a real-time audio thread. Capture
        // only Sendable references. The writer holder is lock-
        // protected internally so rotation can swap the underlying
        // `AVAudioFile` without racing tap writes (and it tallies
        // per-chunk frames inline under that same lock).
        // `AsyncStream.Continuation.yield` is documented as
        // thread-safe.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            holder.write(buffer)
            streamContinuation.yield(PCMBufferEnvelope(buffer))
        }

        do {
            avEngine.prepare()
            try avEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            throw AudioRecorderError.engineFailure(reason: "engine.start: \(error.localizedDescription)")
        }

        self.engine = avEngine
        self.writerHolder = holder
        self.sampleRate = format.sampleRate
        self.inputFormat = format
        self.startedAt = Date()
        self.finalSeedURL = url
        self.intermediateSeedURL = intermediateSeed
        self.activeChunkIndex = 0
        self.finalizedChunks = []
        self.pendingFinalizations = []
        self.bufferStream = stream
        self.bufferContinuation = streamContinuation

        // Build the interruption stream + register OS observers AFTER
        // the engine is running. Doing this last means a throw in the
        // setup above doesn't leak observers (their lifetime is bound
        // to a successfully-started recording).
        let (interruptStream, interruptContinuation) = AsyncStream<Bool>.makeStream()
        self.interruptionStream = interruptStream
        self.interruptionContinuation = interruptContinuation
        self.isInterrupted = false
        registerSessionObservers()

        // Last: spawn the rotation Task if rotation is enabled. We do
        // this *after* every piece of recording state is in place so
        // the first rotation has a valid `writerHolder`, `sampleRate`,
        // etc. to work with.
        if let chunkDuration {
            startRotationTask(interval: chunkDuration)
        }
    }

    // MARK: - AudioBufferSource

    func buffers() async -> AsyncStream<PCMBufferEnvelope>? {
        bufferStream
    }

    // MARK: - AudioInterruptionPublishing

    func interruptionUpdates() async -> AsyncStream<Bool>? {
        interruptionStream
    }

    func stop() async throws -> EngineStopArtifact {
        guard let avEngine = engine,
              let intermediateSeed = intermediateSeedURL,
              let finalSeed = finalSeedURL else {
            throw AudioRecorderError.notRecording
        }

        // Cancel the rotation Task first so no in-flight rotation
        // can race the stop() teardown. The sleeping rotation Task
        // will wake from cancellation, see Task.isCancelled, and exit
        // cleanly. We don't `await` it here — that's tail work; we
        // just need it to stop scheduling new rotations.
        rotationTask?.cancel()
        rotationTask = nil

        // Detach session observers before tearing the engine down so
        // a late interruption notification can't sneak in while we're
        // mid-stop. Done first because removeObserver is a synchronous
        // O(1) op — no risk of dropping a real interruption signal.
        unregisterSessionObservers()

        // Stop the audio pipeline FIRST, before any await, so no new
        // tap buffers fire while we're transcoding the final chunk.
        avEngine.inputNode.removeTap(onBus: 0)
        avEngine.stop()
        // Snapshot + drop the final writer. AVAudioFile's destructor
        // flushes + closes the CAF when the last reference goes away.
        let lastChunkFrames = writerHolder?.close() ?? 0
        writerHolder = nil
        // Finish the buffer stream so any consumer (live speech
        // recognizer) drains naturally and calls request.endAudio()
        // on its recognition request.
        bufferContinuation?.finish()
        bufferContinuation = nil
        interruptionContinuation?.finish()
        interruptionContinuation = nil

        // Finalize the chunk that was active when stop() landed —
        // synchronously here so we don't return before its transcode
        // outcome is known.
        let finalChunkIndex = activeChunkIndex
        let finalCAF = Self.chunkIntermediateURL(
            seed: intermediateSeed,
            chunkIndex: finalChunkIndex,
            chunked: chunkDuration != nil
        )
        if lastChunkFrames > 0 {
            let finalChunkDuration = Double(lastChunkFrames) / max(sampleRate, 1)
            let finalM4A = Self.chunkFinalURL(
                seed: finalSeed,
                chunkIndex: finalChunkIndex,
                chunked: chunkDuration != nil
            )
            let chunk = await finalizeChunk(
                index: finalChunkIndex,
                cafURL: finalCAF,
                duration: finalChunkDuration,
                preferredM4AURL: finalM4A
            )
            finalizedChunks.append(chunk)
        } else {
            // Engine produced no audio in the last chunk (e.g. stop()
            // landed within microseconds of a rotation). Drop the
            // empty CAF; don't add a zero-frame chunk to the artifact.
            try? FileManager.default.removeItem(at: finalCAF)
        }

        // Wait for every rotation-spawned finalization Task to settle.
        // Each task appended its chunk to `finalizedChunks` via the
        // actor-isolated path; by awaiting them we ensure the artifact
        // we return reflects every chunk's real transcode outcome.
        let pending = pendingFinalizations
        pendingFinalizations = []
        for task in pending {
            await task.value
        }

        // Sort chunks by index — finalization completion order may
        // not match recording order (especially when one chunk's
        // transcode retried while a later chunk finished quickly).
        let chunks = finalizedChunks.sorted { $0.chunkIndex < $1.chunkIndex }
        finalizedChunks = []

        if chunks.isEmpty {
            // No chunks landed — every one was either empty or its
            // finalization couldn't even produce a CAF fallback.
            // Treat as engine failure rather than returning a
            // zero-chunk artifact (which the artifact precondition
            // would crash on anyway).
            let savedStartedAt = startedAt
            cleanupState()
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            await logger.error(
                "audio.stop.no_chunks",
                metadata: [
                    "wall_clock_s": .string(
                        String(format: "%.3f", Date().timeIntervalSince(savedStartedAt ?? Date()))
                    )
                ],
                errorCode: "no_chunks"
            )
            throw AudioRecorderError.engineFailure(reason: "no chunks produced")
        }

        // Total duration = sum of per-chunk durations. Falls back to
        // wall-clock if every chunk somehow reported zero frames
        // (which shouldn't happen given the empty-chunk guard above).
        let summed = chunks.reduce(0.0) { $0 + $1.duration }
        let totalDuration: Double = summed > 0
            ? summed
            : max(0.001, Date().timeIntervalSince(startedAt ?? Date()))

        cleanupState()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        return EngineStopArtifact(chunks: chunks, totalDuration: totalDuration)
    }

    func cancel() async {
        guard let avEngine = engine else { return }
        rotationTask?.cancel()
        rotationTask = nil
        // Cancel every in-flight finalization Task so we don't leak
        // a transcode running in the background after cancel().
        for task in pendingFinalizations { task.cancel() }
        pendingFinalizations = []

        unregisterSessionObservers()
        avEngine.inputNode.removeTap(onBus: 0)
        avEngine.stop()
        writerHolder?.close()
        writerHolder = nil
        bufferContinuation?.finish()
        bufferContinuation = nil
        interruptionContinuation?.finish()
        interruptionContinuation = nil

        // Delete every CAF + M4A that this recording put on disk.
        // The caller's directory-tree cleanup also covers these, but
        // doing it here keeps the engine cleanup self-contained for
        // tests / smoke-test paths that don't clean the directory.
        if let intermediateSeed = intermediateSeedURL,
           let finalSeed = finalSeedURL {
            // Cover the full range we *might* have written, including
            // the chunk that was active when cancel landed.
            for index in 0...activeChunkIndex {
                let caf = Self.chunkIntermediateURL(
                    seed: intermediateSeed,
                    chunkIndex: index,
                    chunked: chunkDuration != nil
                )
                let m4a = Self.chunkFinalURL(
                    seed: finalSeed,
                    chunkIndex: index,
                    chunked: chunkDuration != nil
                )
                try? FileManager.default.removeItem(at: caf)
                try? FileManager.default.removeItem(at: m4a)
            }
        }
        // Also wipe any chunks the rotation Task had already finalized
        // to disk before cancel landed.
        for chunk in finalizedChunks {
            try? FileManager.default.removeItem(at: chunk.fileURL)
        }
        finalizedChunks = []

        cleanupState()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Helpers

    private func cleanupState() {
        engine = nil
        writerHolder?.close()
        writerHolder = nil
        sampleRate = 0
        inputFormat = nil
        startedAt = nil
        finalSeedURL = nil
        intermediateSeedURL = nil
        activeChunkIndex = 0
        bufferStream = nil
        bufferContinuation = nil
        interruptionStream = nil
        interruptionContinuation = nil
        isInterrupted = false
        rotationTask = nil
        pendingFinalizations = []
        finalizedChunks = []
    }

    // MARK: - Rotation

    /// Build the per-chunk CAF URL from the session's intermediate
    /// seed. In single-chunk mode (`chunked == false`) the seed is
    /// used verbatim — preserves the pre-rotation on-disk filename
    /// `<stem>.caf`. In chunked mode (`chunked == true`) each chunk
    /// is suffixed with `-chunkN`: `<stem>-chunk0.caf`, etc.
    static func chunkIntermediateURL(seed: URL, chunkIndex: Int, chunked: Bool) -> URL {
        guard chunked else { return seed }
        let dir = seed.deletingLastPathComponent()
        let stem = seed.deletingPathExtension().lastPathComponent
        let ext = seed.pathExtension
        return dir.appendingPathComponent("\(stem)-chunk\(chunkIndex).\(ext)", isDirectory: false)
    }

    /// Build the per-chunk M4A URL from the session's final seed.
    /// See ``chunkIntermediateURL(seed:chunkIndex:chunked:)`` for the
    /// naming scheme.
    static func chunkFinalURL(seed: URL, chunkIndex: Int, chunked: Bool) -> URL {
        guard chunked else { return seed }
        let dir = seed.deletingLastPathComponent()
        let stem = seed.deletingPathExtension().lastPathComponent
        let ext = seed.pathExtension
        return dir.appendingPathComponent("\(stem)-chunk\(chunkIndex).\(ext)", isDirectory: false)
    }

    /// Spawn the periodic rotation Task. Sleeps `interval` seconds at
    /// a time and calls `rotate()` after each tick. Exits on
    /// cancellation — `stop()` and `cancel()` both cancel the task.
    private func startRotationTask(interval: TimeInterval) {
        let nanos = UInt64(interval * 1_000_000_000)
        rotationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: nanos)
                } catch {
                    // Cancellation throws `CancellationError`; treat
                    // it as a clean exit signal.
                    return
                }
                if Task.isCancelled { return }
                await self?.rotate()
            }
        }
    }

    /// Rotation tick: open a fresh CAF for the next chunk, swap it
    /// into the holder atomically, and spawn a finalization Task for
    /// the chunk that just closed. Mutates `activeChunkIndex` so the
    /// tap's writes are now attributed to the new chunk.
    ///
    /// If the engine is paused (interrupted) and no frames have been
    /// written into the active chunk, skip the rotation — rotating
    /// an empty file just adds a zero-duration chunk to the artifact,
    /// which is worse than nothing.
    private func rotate() async {
        guard let holder = writerHolder,
              let intermediateSeed = intermediateSeedURL,
              let finalSeed = finalSeedURL,
              let format = inputFormat,
              !Task.isCancelled else {
            return
        }

        let closingChunkIndex = activeChunkIndex
        let nextChunkIndex = closingChunkIndex + 1
        let nextCAF = Self.chunkIntermediateURL(
            seed: intermediateSeed,
            chunkIndex: nextChunkIndex,
            chunked: true
        )
        // Pre-clean in case a stale file from a prior aborted run is
        // sitting at the next chunk's path.
        try? FileManager.default.removeItem(at: nextCAF)

        let nextWriter: AVAudioFile
        do {
            nextWriter = try AVAudioFile(forWriting: nextCAF, settings: format.settings)
        } catch {
            // Couldn't open the next chunk's CAF. Keep the current
            // writer in place — recording continues into the active
            // chunk — and log. The next rotation tick will try again.
            await logger.error(
                "audio.rotate.open_failed",
                metadata: [
                    "chunk_index": .int(Int64(nextChunkIndex)),
                    "reason": .string(error.localizedDescription)
                ],
                errorCode: "rotate_open"
            )
            return
        }

        // Swap atomically. After this call returns, tap writes go
        // into `nextWriter` and `closingWriter` is the previous
        // writer (its CAF will flush + close when we drop the ref).
        let (closingWriter, framesInClosing) = holder.swap(nextWriter)
        activeChunkIndex = nextChunkIndex

        // Drop the closing writer's reference so AVAudioFile's
        // destructor flushes the CAF tail to disk. We capture only
        // the URL + frame count into the finalization Task.
        _ = closingWriter
        let closingCAF = Self.chunkIntermediateURL(
            seed: intermediateSeed,
            chunkIndex: closingChunkIndex,
            chunked: true
        )

        if framesInClosing == 0 {
            // Chunk window passed with no audio (interruption /
            // tap stall). Drop the empty CAF and don't finalize.
            try? FileManager.default.removeItem(at: closingCAF)
            await logger.warning(
                "audio.rotate.empty_chunk",
                metadata: ["chunk_index": .int(Int64(closingChunkIndex))]
            )
            return
        }

        let closingDuration = Double(framesInClosing) / max(sampleRate, 1)
        let closingM4A = Self.chunkFinalURL(
            seed: finalSeed,
            chunkIndex: closingChunkIndex,
            chunked: true
        )

        await logger.info(
            "audio.rotate.swap",
            metadata: [
                "closed_chunk_index": .int(Int64(closingChunkIndex)),
                "closed_duration_s": .string(String(format: "%.3f", closingDuration)),
                "next_chunk_index": .int(Int64(nextChunkIndex))
            ]
        )

        // Spawn a finalization Task for the closing chunk. We don't
        // await it here — the rotation loop has to keep its cadence,
        // and the transcode runs in parallel with continued recording
        // into the new chunk. `stop()` awaits all pending finalizations
        // before assembling the artifact.
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            let chunk = await self.finalizeChunk(
                index: closingChunkIndex,
                cafURL: closingCAF,
                duration: closingDuration,
                preferredM4AURL: closingM4A
            )
            await self.appendFinalizedChunk(chunk)
        }
        pendingFinalizations.append(task)
    }

    /// Append a chunk to the finalized list under actor isolation.
    /// Used by background finalization Tasks; the in-line finalize
    /// path in `stop()` mutates the array directly without going
    /// through this helper.
    private func appendFinalizedChunk(_ chunk: EngineStopArtifact.Chunk) {
        finalizedChunks.append(chunk)
    }

    /// Transcode `cafURL` → `preferredM4AURL` with retries; on
    /// permanent failure, fall back to the CAF (Genie's server-side
    /// accepts `audio/x-caf`). Returns the finalized chunk metadata
    /// with the URL + MIME / extension that should actually be
    /// uploaded.
    private func finalizeChunk(
        index: Int,
        cafURL: URL,
        duration: Double,
        preferredM4AURL: URL
    ) async -> EngineStopArtifact.Chunk {
        var lastError: Error?
        for attempt in 1...transcodeAttempts {
            do {
                try await transcode(from: cafURL, to: preferredM4AURL)
                lastError = nil
                break
            } catch {
                lastError = error
                await logger.warning(
                    "audio.transcode.attempt_failed",
                    metadata: [
                        "chunk_index": .int(Int64(index)),
                        "attempt": .int(Int64(attempt)),
                        "of": .int(Int64(transcodeAttempts)),
                        "reason": .string(error.localizedDescription)
                    ]
                )
                if attempt < transcodeAttempts {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }

        if lastError == nil {
            // Happy path: M4A on disk at `preferredM4AURL`, drop the CAF.
            try? FileManager.default.removeItem(at: cafURL)
            return EngineStopArtifact.Chunk(
                fileURL: preferredM4AURL,
                chunkIndex: index,
                duration: duration,
                mimeType: "audio/mp4",
                fileExtension: "m4a"
            )
        }

        // Permanent transcode failure → CAF fallback for this chunk.
        // Server accepts `audio/x-caf`; silver pipeline transcodes
        // later. Delete any partial M4A AVAssetExportSession may have
        // left behind so we don't accidentally upload junk.
        await logger.error(
            "audio.transcode.fallback_to_caf",
            metadata: [
                "chunk_index": .int(Int64(index)),
                "caf_path": .string(cafURL.lastPathComponent),
                "reason": .string(lastError?.localizedDescription ?? "unknown")
            ],
            errorCode: "transcode_fallback"
        )
        try? FileManager.default.removeItem(at: preferredM4AURL)
        return EngineStopArtifact.Chunk(
            fileURL: cafURL,
            chunkIndex: index,
            duration: duration,
            mimeType: "audio/x-caf",
            fileExtension: "caf"
        )
    }

    // MARK: - Session observers

    /// Register for `AVAudioSession.interruptionNotification` and
    /// `routeChangeNotification`. Both observer blocks run on an
    /// arbitrary notification thread, so they extract Sendable
    /// values synchronously and hop back into the actor via a Task.
    /// Tokens are stored so `unregisterSessionObservers` can detach.
    private func registerSessionObservers() {
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard
                let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else { return }
            let shouldResume: Bool
            if let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt {
                shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            } else {
                shouldResume = false
            }
            Task { [weak self] in
                await self?.handleInterruption(type: type, shouldResume: shouldResume)
            }
        }
        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard
                let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
            else { return }
            Task { [weak self] in
                await self?.handleRouteChange(reason: reason)
            }
        }
    }

    private func unregisterSessionObservers() {
        let center = NotificationCenter.default
        if let interruptionObserver {
            center.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if let routeChangeObserver {
            center.removeObserver(routeChangeObserver)
            self.routeChangeObserver = nil
        }
    }

    /// React to an interruption event.
    ///
    /// `.began` → pause the engine (keep tap + writer in place so the
    /// recording resumes seamlessly), broadcast `true` on the
    /// interruption stream.
    ///
    /// `.ended` with `.shouldResume` → reactivate the audio session
    /// and restart the engine. Broadcast `false`.
    ///
    /// `.ended` without `.shouldResume` → iOS is signalling the
    /// interruption is over but the OS doesn't want us auto-resuming
    /// (typical for user-initiated alarms, Siri triggers). Stay
    /// paused but still broadcast `false` so the UI can offer a
    /// manual resume affordance later. Today nothing manually
    /// resumes — captures stay paused until stop().
    private func handleInterruption(
        type: AVAudioSession.InterruptionType,
        shouldResume: Bool
    ) async {
        guard let avEngine = engine else { return }
        switch type {
        case .began:
            avEngine.pause()
            isInterrupted = true
            interruptionContinuation?.yield(true)
            await logger.warning(
                "audio.session.interrupted",
                metadata: ["phase": .string("began")]
            )
        case .ended:
            if shouldResume {
                do {
                    try AVAudioSession.sharedInstance().setActive(true, options: [])
                    try avEngine.start()
                    isInterrupted = false
                    interruptionContinuation?.yield(false)
                    await logger.info("audio.session.resumed")
                } catch {
                    // Resume failed — engine stays paused. Surface
                    // the false transition so UI can move out of the
                    // "interrupted" indicator, but log a warning so
                    // it's visible in the support bundle. User will
                    // have to stop + restart to recover the run.
                    interruptionContinuation?.yield(false)
                    await logger.warning(
                        "audio.session.resume_failed",
                        metadata: ["reason": .string(error.localizedDescription)]
                    )
                }
            } else {
                // OS withheld .shouldResume — leave the engine paused
                // but signal the interruption window has ended.
                interruptionContinuation?.yield(false)
                await logger.info(
                    "audio.session.interrupt_ended_no_resume"
                )
            }
        @unknown default:
            return
        }
    }

    /// Route changes (headphones unplugged, BT connect/disconnect,
    /// mic source change) don't tear the engine down — `AVAudioEngine`
    /// rebinds to the new default input. We log for diagnostics and
    /// keep recording on the new route.
    ///
    /// The one exception is `.oldDeviceUnavailable` with no fallback
    /// available, which iOS surfaces as a separate interruption. The
    /// interruption observer handles that path.
    private func handleRouteChange(reason: AVAudioSession.RouteChangeReason) async {
        await logger.info(
            "audio.session.route_changed",
            metadata: ["reason": .string(String(describing: reason))]
        )
    }

    private func transcode(from source: URL, to destination: URL) async throws {
        // Ensure no stale file at the destination.
        try? FileManager.default.removeItem(at: destination)

        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioRecorderError.engineFailure(reason: "could not create AVAssetExportSession")
        }
        // iOS 18+ async API. Throws on failure; replaces the older
        // completion-handler + status-polling dance.
        try await exporter.export(to: destination, as: .m4a)

        // Post-transcode size guard: AVAssetExportSession has been
        // observed to silently produce a 0-byte / tiny output for
        // edge-case inputs without throwing. A valid AAC/M4A file
        // has at least an `ftyp` box (~32 bytes) and metadata; we
        // pick a generous 256-byte floor to catch the obviously-bad
        // case without false-positiving on legitimately short
        // recordings (1s of 64 kbps AAC is ~8 KB, so the floor never
        // fires on a real recording). Throwing here drops us into
        // the retry / CAF-fallback path one level up — uploading
        // the lossless CAF beats uploading a malformed M4A that
        // can't be decoded server-side or in the React player.
        let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if size < 256 {
            try? FileManager.default.removeItem(at: destination)
            throw AudioRecorderError.engineFailure(
                reason: "transcode produced \(size)-byte output (expected ≥256)"
            )
        }
    }
}

/// Lock-protected holder for the current `AVAudioFile` writer.
/// Sits between the real-time tap thread (which writes buffers
/// into the active file) and the actor's rotation path (which
/// swaps the active file for a fresh one at chunk boundaries).
///
/// `AVAudioFile.write(from:)` is documented as thread-safe for
/// writes from a single thread; concurrent writes from multiple
/// threads need external synchronization. The tap is one thread,
/// the rotation Task is another — so we wrap with an NSLock and
/// gate every write/swap behind it. Lock contention is on the
/// order of hundreds of nanoseconds; the tap's buffer interval
/// at 4096 samples / 48 kHz is ~85 ms. Six orders of magnitude
/// of headroom, no audible impact.
///
/// Per-chunk frame count is tracked inline with each `write()` so
/// that `swap()` / `close()` can return the exact frame count for
/// the chunk being closed — under the same lock that gates the
/// writer. This avoids a race where buffers written between a
/// separate frame snapshot and the writer swap would be miscounted.
///
/// `@unchecked Sendable` because the lock is the only mutable
/// state and is explicitly thread-safe.
final class AudioWriterHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: AVAudioFile?
    private var chunkFrames: AVAudioFramePosition = 0

    init(initial: AVAudioFile) {
        self.writer = initial
    }

    /// Write a buffer to the currently-held writer and tally the
    /// frames toward the current chunk. Called from the real-time
    /// tap thread. Errors are silently swallowed — matches the prior
    /// `try? writer.write(from: buffer)` behavior (write failures
    /// during a recording session are not actionable in real time;
    /// they surface later via the file's final size or transcode
    /// result). Frames are tallied even on write error so the
    /// counter still represents what *should* have landed —
    /// downstream duration calc is more useful than a frame counter
    /// that silently drops on IO failure.
    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        try? writer?.write(from: buffer)
        chunkFrames += AVAudioFramePosition(buffer.frameLength)
    }

    /// Atomically swap the held writer and return the previous
    /// writer along with the number of frames written into it.
    /// Resets the per-chunk frame counter to zero so the new
    /// writer starts counting from 0. Used by the rotation path:
    /// open the new file, then swap.
    ///
    /// The returned `previous` writer's destructor will flush + close
    /// its CAF as soon as the caller drops the reference. Hold onto
    /// it long enough to read `length` if needed before dropping.
    func swap(_ new: AVAudioFile) -> (previous: AVAudioFile?, framesInPrevious: AVAudioFramePosition) {
        lock.lock()
        defer { lock.unlock() }
        let old = writer
        let frames = chunkFrames
        writer = new
        chunkFrames = 0
        return (old, frames)
    }

    /// Drop the held writer and return the frames written into it.
    /// AVAudioFile's destructor flushes and closes the CAF when the
    /// last reference goes away. Called from `stop()` / `cancel()`
    /// / `cleanupState()`. Frame counter resets to 0 so subsequent
    /// `close()` calls (from the cleanup paths that call this twice)
    /// return 0 instead of the same count twice.
    @discardableResult
    func close() -> AVAudioFramePosition {
        lock.lock()
        defer { lock.unlock() }
        let frames = chunkFrames
        writer = nil
        chunkFrames = 0
        return frames
    }
}

