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
/// File-size note: a 30 s recording produces ~5 MB of intermediate
/// CAF (48 kHz Float32 mono) and ~240 KB of final AAC m4a — the
/// transcode below pins the encoder at 64 kbps / 16 kHz / mono,
/// well-sized for speech and downstream STT (Whisper ingests 16 kHz
/// mono natively). The PR 9a `AVAssetExportPresetAppleM4A` default
/// of ~256 kbps gave us ~660 KB for 23 s of audio — 3-4× oversized.
actor EngineAudioRecordingEngine: AudioRecordingEngine, AudioBufferSource {

    private var engine: AVAudioEngine?
    private var cafWriter: AVAudioFile?
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

    init() {}

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

        let counter = FrameCounter()
        // PR 9b: also fan out audio buffers to a live stream so the
        // speech recognizer can consume them in parallel with the
        // file write. Single tap, two consumers — no parallel-engine
        // race condition that bit PR 8d.
        let (stream, streamContinuation) = AsyncStream<PCMBufferEnvelope>.makeStream()
        // The tap closure runs on a real-time audio thread. Capture
        // only Sendable references; the AVAudioFile + FrameCounter
        // are both safe to access from the tap (AVAudioFile.write is
        // documented as thread-safe for serial writes; FrameCounter
        // wraps an NSLock; AsyncStream.Continuation.yield is
        // documented as thread-safe).
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            try? writer.write(from: buffer)
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
        self.cafWriter = writer
        self.frameCounter = counter
        self.sampleRate = inputFormat.sampleRate
        self.startedAt = Date()
        self.finalURL = url
        self.intermediateURL = intermediate
        self.bufferStream = stream
        self.bufferContinuation = streamContinuation
    }

    // MARK: - AudioBufferSource

    func buffers() async -> AsyncStream<PCMBufferEnvelope>? {
        bufferStream
    }

    func stop() async throws -> Double {
        guard let avEngine = engine,
              let intermediate = intermediateURL,
              let final = finalURL else {
            throw AudioRecorderError.notRecording
        }

        // Stop the audio pipeline FIRST, before any await, so no new
        // tap buffers fire while we're transcoding.
        avEngine.inputNode.removeTap(onBus: 0)
        avEngine.stop()
        // Dropping the AVAudioFile reference flushes + closes the
        // CAF file. AVAudioFile's destructor handles this.
        cafWriter = nil
        // Finish the buffer stream so any consumer (live speech
        // recognizer) drains naturally and calls request.endAudio()
        // on its recognition request.
        bufferContinuation?.finish()
        bufferContinuation = nil

        let frames = frameCounter?.snapshot() ?? 0
        let measuredDuration = sampleRate > 0 ? Double(frames) / sampleRate : 0
        let savedStartedAt = startedAt

        do {
            try await transcode(from: intermediate, to: final)
        } catch {
            cleanupState()
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            throw AudioRecorderError.engineFailure(reason: "transcode: \(error.localizedDescription)")
        }

        try? FileManager.default.removeItem(at: intermediate)
        cleanupState()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])

        // Fallback to wall-clock if the frame counter never fired
        // (e.g., very-short capture where the tap had no chance to
        // deliver a buffer). Mirrors LiveAudioRecordingEngine's
        // 0.001s floor so we never report a zero-duration recording.
        if measuredDuration > 0 {
            return measuredDuration
        }
        return max(0.001, Date().timeIntervalSince(savedStartedAt ?? Date()))
    }

    func cancel() async {
        guard let avEngine = engine else { return }
        avEngine.inputNode.removeTap(onBus: 0)
        avEngine.stop()
        cafWriter = nil
        bufferContinuation?.finish()
        bufferContinuation = nil
        if let intermediate = intermediateURL {
            try? FileManager.default.removeItem(at: intermediate)
        }
        cleanupState()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Helpers

    private func cleanupState() {
        engine = nil
        cafWriter = nil
        frameCounter = nil
        sampleRate = 0
        startedAt = nil
        finalURL = nil
        intermediateURL = nil
        bufferStream = nil
        bufferContinuation = nil
    }

    /// CAF → AAC m4a transcode with explicit voice-grade bitrate.
    ///
    /// Why not `AVAssetExportSession(presetName: AVAssetExportPresetAppleM4A)`:
    /// that preset defaults to ~256 kbps AAC at the source sample
    /// rate. For voice it's 3-4× larger than necessary — a 30 s
    /// session would land ~900 KB instead of ~250 KB. The export
    /// session API exposes no bitrate knob (the M4A preset is the
    /// only audio-only preset, and its `fileLengthLimit` works
    /// retroactively, not as an a-priori bitrate cap).
    ///
    /// Switching to `AVAssetReader` + `AVAssetWriter` lets us pin
    /// the encoder at 64 kbps mono — broadcast-voice quality, well
    /// above the 32 kbps AM-radio floor, and significantly under
    /// what Whisper / downstream STT pipelines actually consume
    /// (16 kHz mono ≈ 256 kbit/s PCM). Sample-rate stays at the
    /// source rate (typically 48 kHz from the iPhone mic); the AAC
    /// encoder handles 48 → output internally.
    private func transcode(from source: URL, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)

        let asset = AVURLAsset(url: source)
        let audioTrack: AVAssetTrack
        do {
            let tracks = try await asset.load(.tracks)
            guard let track = tracks.first(where: { $0.mediaType == .audio }) else {
                throw AudioRecorderError.engineFailure(reason: "transcode: no audio track in source")
            }
            audioTrack = track
        } catch let error as AudioRecorderError {
            throw error
        } catch {
            throw AudioRecorderError.engineFailure(reason: "transcode: load tracks: \(error.localizedDescription)")
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioRecorderError.engineFailure(reason: "transcode: reader init: \(error.localizedDescription)")
        }
        // Pull raw 16-bit interleaved PCM out of the CAF — what
        // the AAC encoder wants to ingest.
        let readerOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        guard reader.canAdd(readerOutput) else {
            throw AudioRecorderError.engineFailure(reason: "transcode: can't add reader output")
        }
        reader.add(readerOutput)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        } catch {
            throw AudioRecorderError.engineFailure(reason: "transcode: writer init: \(error.localizedDescription)")
        }
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 16_000,
                AVEncoderBitRateKey: 64_000
            ]
        )
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw AudioRecorderError.engineFailure(reason: "transcode: can't add writer input")
        }
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw AudioRecorderError.engineFailure(
                reason: "transcode: startWriting: \(writer.error?.localizedDescription ?? "unknown")"
            )
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw AudioRecorderError.engineFailure(
                reason: "transcode: startReading: \(reader.error?.localizedDescription ?? "unknown")"
            )
        }

        // Pump reader samples into the writer.
        // `requestMediaDataWhenReady` fires the closure on `queue`
        // repeatedly while the input can accept more data; we keep
        // feeding until the reader runs dry, then mark the input
        // finished and resume from `finishWriting`'s completion.
        //
        // `TranscodePump` boxes the non-Sendable AVFoundation
        // references as @unchecked Sendable so the @Sendable
        // closure can capture them. Access is naturally serialized
        // by the single dispatch queue.
        let queue = DispatchQueue(label: "lakeloom.audio.transcode", qos: .utility)
        let pump = TranscodePump(
            reader: reader,
            readerOutput: readerOutput,
            writer: writer,
            writerInput: writerInput
        )
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pump.writerInput.requestMediaDataWhenReady(on: queue) {
                while pump.writerInput.isReadyForMoreMediaData {
                    if let sample = pump.readerOutput.copyNextSampleBuffer() {
                        pump.writerInput.append(sample)
                    } else {
                        pump.writerInput.markAsFinished()
                        pump.writer.finishWriting {
                            continuation.resume()
                        }
                        return
                    }
                }
            }
        }

        if reader.status == .failed {
            throw AudioRecorderError.engineFailure(
                reason: "transcode: reader failed: \(reader.error?.localizedDescription ?? "unknown")"
            )
        }
        if writer.status != .completed {
            throw AudioRecorderError.engineFailure(
                reason: "transcode: writer status=\(writer.status.rawValue): \(writer.error?.localizedDescription ?? "unknown")"
            )
        }
    }
}

/// `@unchecked Sendable` box for the four AVFoundation handles used
/// by the CAF → AAC transcode pump. AVAssetReader / Writer /
/// ReaderTrackOutput / WriterInput aren't marked `Sendable`, but the
/// transcode pump serializes all access through a single private
/// dispatch queue, so wrapping them in this box satisfies the
/// `@Sendable` closure requirement of
/// `AVAssetWriterInput.requestMediaDataWhenReady(on:_:)`.
private struct TranscodePump: @unchecked Sendable {
    let reader: AVAssetReader
    let readerOutput: AVAssetReaderTrackOutput
    let writer: AVAssetWriter
    let writerInput: AVAssetWriterInput
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
