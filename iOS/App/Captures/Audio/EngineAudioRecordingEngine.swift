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
    /// directly) so the rotation logic in PR A piece 4 can swap the
    /// underlying writer atomically without racing the real-time tap
    /// thread. Currently always holds a single writer for the entire
    /// session; rotation is a follow-up.
    private var writerHolder: AudioWriterHolder?
    private var frameCounter: FrameCounter?
    private var sampleRate: Double = 0
    private var startedAt: Date?
    /// URL the caller asked the final `.m4a` to be written to.
    private var finalURL: URL?
    /// Sibling `.caf` URL (same stem, swapped extension) used as the
    /// intermediate PCM file before transcoding.
    private var intermediateURL: URL?
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
    private let logger: AppLogger
    /// Maximum number of `AVAssetExportSession.export()` attempts
    /// before falling back to CAF. Interruption is the most common
    /// failure mode and typically clears within a second; three
    /// attempts with a 500ms gap covers the realistic transient
    /// window.
    private let transcodeAttempts: Int

    init(
        logger: AppLogger = AppLogger(category: .capture),
        transcodeAttempts: Int = 3
    ) {
        self.logger = logger
        self.transcodeAttempts = transcodeAttempts
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
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            throw AudioRecorderError.sessionConfigurationFailed(
                reason: "invalid input format: sr=\(inputFormat.sampleRate) ch=\(inputFormat.channelCount)"
            )
        }

        // Intermediate CAF lives at the same path as the requested
        // .m4a but with a swapped extension. Same parent directory,
        // so caller-side cleanup logic (which already deletes the
        // capture's directory tree on cancel/failure) handles both
        // without explicit knowledge of the intermediate.
        let intermediate = url.deletingPathExtension().appendingPathExtension("caf")
        // If a prior aborted run left a stale CAF behind, drop it
        // before opening a fresh writer.
        try? FileManager.default.removeItem(at: intermediate)

        let writer: AVAudioFile
        do {
            writer = try AVAudioFile(forWriting: intermediate, settings: inputFormat.settings)
        } catch {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            throw AudioRecorderError.fileSystemError(reason: "AVAudioFile init: \(error.localizedDescription)")
        }
        let holder = AudioWriterHolder(initial: writer)

        let counter = FrameCounter()
        // PR 9b: also fan out audio buffers to a live stream so the
        // speech recognizer can consume them in parallel with the
        // file write. Single tap, two consumers — no parallel-engine
        // race condition that bit PR 8d.
        let (stream, streamContinuation) = AsyncStream<PCMBufferEnvelope>.makeStream()
        // The tap closure runs on a real-time audio thread. Capture
        // only Sendable references. The writer holder is lock-
        // protected internally so rotation in PR A piece 4 can swap
        // the underlying `AVAudioFile` without racing tap writes; the
        // `FrameCounter` wraps an NSLock; `AsyncStream.Continuation.yield`
        // is documented as thread-safe.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            holder.write(buffer)
            counter.add(buffer.frameLength)
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
        self.frameCounter = counter
        self.sampleRate = inputFormat.sampleRate
        self.startedAt = Date()
        self.finalURL = url
        self.intermediateURL = intermediate
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
              let intermediate = intermediateURL,
              let final = finalURL else {
            throw AudioRecorderError.notRecording
        }

        // Detach session observers before tearing the engine down so
        // a late interruption notification can't sneak in while we're
        // mid-stop. Done first because removeObserver is a synchronous
        // O(1) op — no risk of dropping a real interruption signal.
        unregisterSessionObservers()

        // Stop the audio pipeline FIRST, before any await, so no new
        // tap buffers fire while we're transcoding.
        avEngine.inputNode.removeTap(onBus: 0)
        avEngine.stop()
        // Dropping the AVAudioFile reference flushes + closes the
        // CAF file. AVAudioFile's destructor handles this.
        writerHolder?.close()
        writerHolder = nil
        // Finish the buffer stream so any consumer (live speech
        // recognizer) drains naturally and calls request.endAudio()
        // on its recognition request.
        bufferContinuation?.finish()
        bufferContinuation = nil
        interruptionContinuation?.finish()
        interruptionContinuation = nil

        let frames = frameCounter?.snapshot() ?? 0
        let measuredDuration = sampleRate > 0 ? Double(frames) / sampleRate : 0
        let savedStartedAt = startedAt
        let duration: Double = measuredDuration > 0
            ? measuredDuration
            : max(0.001, Date().timeIntervalSince(savedStartedAt ?? Date()))

        // Attempt the transcode up to `transcodeAttempts` times. The
        // most common cause of `AVAssetExportSession` failure is an
        // AVAudioSession interruption mid-export — typically transient,
        // so a couple of retries handles it. On terminal failure we
        // fall back to returning the raw CAF rather than losing the
        // user's audio (Genie's server-side accepts `audio/x-caf`).
        var lastTranscodeError: Error?
        for attempt in 1...transcodeAttempts {
            do {
                try await transcode(from: intermediate, to: final)
                lastTranscodeError = nil
                break
            } catch {
                lastTranscodeError = error
                await logger.warning(
                    "audio.transcode.attempt_failed",
                    metadata: [
                        "attempt": .int(Int64(attempt)),
                        "of": .int(Int64(transcodeAttempts)),
                        "reason": .string(error.localizedDescription)
                    ]
                )
                if attempt < transcodeAttempts {
                    // Brief sleep before next attempt — interruptions
                    // usually clear within a second.
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }

        if lastTranscodeError == nil {
            // Happy path: M4A on disk at `final`, drop the CAF.
            try? FileManager.default.removeItem(at: intermediate)
            cleanupState()
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            return EngineStopArtifact(
                fileURL: final,
                duration: duration,
                mimeType: "audio/mp4",
                fileExtension: "m4a"
            )
        }

        // Permanent transcode failure → CAF fallback.
        // Keep the CAF; that IS the user's audio now. Don't touch
        // `final` because there's no valid M4A there — server will
        // get the CAF instead.
        await logger.error(
            "audio.transcode.fallback_to_caf",
            metadata: [
                "caf_path": .string(intermediate.lastPathComponent),
                "reason": .string(lastTranscodeError?.localizedDescription ?? "unknown")
            ],
            errorCode: "transcode_fallback"
        )
        // Delete the partial/missing M4A at `final` so nothing else
        // tries to upload it. AVAssetExportSession may have left a
        // partial file behind on failure.
        try? FileManager.default.removeItem(at: final)
        cleanupState()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        return EngineStopArtifact(
            fileURL: intermediate,
            duration: duration,
            mimeType: "audio/x-caf",
            fileExtension: "caf"
        )
    }

    func cancel() async {
        guard let avEngine = engine else { return }
        unregisterSessionObservers()
        avEngine.inputNode.removeTap(onBus: 0)
        avEngine.stop()
        writerHolder?.close()
        writerHolder = nil
        bufferContinuation?.finish()
        bufferContinuation = nil
        interruptionContinuation?.finish()
        interruptionContinuation = nil
        if let intermediate = intermediateURL {
            try? FileManager.default.removeItem(at: intermediate)
        }
        cleanupState()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Helpers

    private func cleanupState() {
        engine = nil
        writerHolder?.close()
        writerHolder = nil
        frameCounter = nil
        sampleRate = 0
        startedAt = nil
        finalURL = nil
        intermediateURL = nil
        bufferStream = nil
        bufferContinuation = nil
        interruptionStream = nil
        interruptionContinuation = nil
        isInterrupted = false
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
/// `@unchecked Sendable` because the lock is the only mutable
/// state and is explicitly thread-safe.
final class AudioWriterHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: AVAudioFile?

    init(initial: AVAudioFile) {
        self.writer = initial
    }

    /// Write a buffer to the currently-held writer. Called from
    /// the real-time tap thread. Errors are silently swallowed —
    /// matches the prior `try? writer.write(from: buffer)` behavior
    /// (write failures during a recording session are not
    /// actionable in real time; they surface later via the file's
    /// final size or transcode result).
    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        try? writer?.write(from: buffer)
    }

    /// Atomically swap the held writer. Returns the previous writer
    /// so the caller can let its destructor flush the CAF tail.
    /// Used by the rotation path: open the new file, then swap.
    func swap(_ new: AVAudioFile) -> AVAudioFile? {
        lock.lock()
        defer { lock.unlock() }
        let old = writer
        writer = new
        return old
    }

    /// Drop the held writer. AVAudioFile's destructor flushes and
    /// closes the CAF when the last reference goes away. Called
    /// from `stop()` / `cancel()` / `cleanupState()`.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        writer = nil
    }
}

/// Lock-protected frame counter shared between the real-time tap
/// callback and the actor-isolated stop() path. AVAudioFramePosition
/// is Int64 — increments are NOT atomic on all platforms, so we
/// guard with NSLock. `@unchecked Sendable` because the lock is the
/// only mutable state and is explicitly thread-safe.
private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: AVAudioFramePosition = 0

    func add(_ frames: AVAudioFrameCount) {
        lock.lock()
        count += AVAudioFramePosition(frames)
        lock.unlock()
    }

    func snapshot() -> AVAudioFramePosition {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
