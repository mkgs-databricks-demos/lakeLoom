@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

/// Production ``StreamingSpeechRecognizer`` backed by AVAudioEngine
/// + SFSpeechRecognizer + SFSpeechAudioBufferRecognitionRequest.
/// Runs in parallel with ``LiveAudioRecorder`` (both consume the
/// shared AVAudioSession's input) so the user gets a live
/// transcript landing in ZeroBus while the AAC `.m4a` is still
/// recording for upload.
///
/// On-device only — `requiresOnDeviceRecognition = true`. Audio
/// buffers never leave the device for transcription; the server-side
/// Whisper pass on the uploaded file is the authoritative
/// transcript per Genie's AI pipeline note.
///
/// Per-segment timing: the recognizer fires its final result once
/// per detected speech segment with a `bestTranscription` containing
/// one or more `SFTranscriptionSegment` entries. We walk those and
/// yield one ``TranscriptSegment`` per Apple segment with a
/// monotonic index — same shape as the file-based
/// ``LiveSpeechTranscriber``.
public actor LiveStreamingSpeechRecognizer: StreamingSpeechRecognizer {

    private let logger: AppLogger

    /// Owned engine — distinct from any AVAudioEngine
    /// ``LiveAudioRecorder`` might install (today it uses the
    /// AVAudioRecorder API, which doesn't expose an engine). If
    /// both ever share a single engine, this property is the
    /// rewrite point.
    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Continuation handed back to the caller. Held so `stop()` can
    /// finish the stream after the recognizer fires its terminal
    /// result.
    private var continuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation?

    /// Monotonic counter across all segments emitted in this
    /// session. SFSpeechRecognizer emits its segments fresh per
    /// final result, so we have to track session-level index
    /// ourselves to match the protocol shape downstream consumers
    /// (TranscriptStreamer, server) expect.
    private var nextSegmentIndex: Int = 0

    public init(logger: AppLogger = AppLogger(category: .capture)) {
        self.logger = logger
    }

    // MARK: - StreamingSpeechRecognizer

    public func transcripts() async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        // Guard against double-start. A second call replaces the
        // first — but we throw rather than silently teardown so the
        // caller notices the bug.
        guard task == nil else {
            throw SpeechTranscriberError.recognitionFailed(
                reason: "streaming recognizer already started",
                code: nil
            )
        }

        try await ensureAuthorized()

        let chosenLocale = Locale(identifier: "en-US")
        guard let recognizer = SFSpeechRecognizer(locale: chosenLocale) else {
            throw SpeechTranscriberError.unavailable(
                reason: "no recognizer for locale \(chosenLocale.identifier)"
            )
        }
        guard recognizer.isAvailable else {
            throw SpeechTranscriberError.unavailable(reason: "recognizer not available")
        }
        self.recognizer = recognizer

        // Audio session — request record category. We're permissive
        // about `.mixWithOthers` so the AVAudioRecorder's session
        // also keeps working. iOS will share the input across the
        // two consumers.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw SpeechTranscriberError.unavailable(
                reason: "audio session config failed: \(error.localizedDescription)"
            )
        }

        let engine = AVAudioEngine()
        self.engine = engine
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
        self.request = request

        await logger.debug(
            "speech.streaming.attempt",
            metadata: [
                "locale": .string(chosenLocale.identifier),
                "sample_rate": .int(Int64(inputFormat.sampleRate)),
                "channels": .int(Int64(inputFormat.channelCount))
            ]
        )

        // Reset session-level state.
        nextSegmentIndex = 0

        let (stream, continuation) = AsyncThrowingStream<TranscriptSegment, Error>.makeStream()
        self.continuation = continuation

        // Install tap BEFORE starting the task so no buffer is lost
        // on the leading edge.
        let appendQueue = DispatchQueue(label: "lakeloom.speech.append", qos: .userInitiated)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            // SFSpeechAudioBufferRecognitionRequest.append is
            // documented as thread-safe; we hop to a serial queue to
            // make the contract obvious from the call site.
            appendQueue.async {
                request.append(buffer)
            }
        }

        let actorLogger = logger
        let recognizerLocal = recognizer
        let task = recognizerLocal.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let error {
                let nsError = error as NSError
                // SFSpeechRecognitionErrorDomain code 1 ("No speech
                // detected") fires on silence at end-of-stream and
                // shouldn't be treated as a hard failure — just
                // finish the stream.
                let isBenignNoSpeech = nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1
                Task {
                    if isBenignNoSpeech {
                        await actorLogger.debug("speech.streaming.no_speech")
                    } else {
                        await actorLogger.warning(
                            "speech.streaming.failed",
                            metadata: [
                                "domain": .string(nsError.domain),
                                "code": .int(Int64(nsError.code)),
                                "reason": .string(nsError.localizedDescription)
                            ]
                        )
                    }
                    await self.finishStreamSuccessfully(isBenignNoSpeech: isBenignNoSpeech, error: nsError)
                }
                return
            }
            guard let result, result.isFinal else { return }
            Task {
                await self.emit(segmentsFrom: result.bestTranscription)
                // For a buffer-based request, `isFinal == true` only
                // fires after `endAudio()` is called (which happens
                // in stop()), so we don't finish the stream here.
            }
        }
        self.task = task

        do {
            engine.prepare()
            try engine.start()
        } catch {
            await tearDown()
            throw SpeechTranscriberError.unavailable(
                reason: "engine.start failed: \(error.localizedDescription)"
            )
        }

        return stream
    }

    public func stop() async {
        // Ending audio tells SFSpeechRecognizer the source is done.
        // It will fire one last final result, then the task ends.
        request?.endAudio()

        // Pull the tap immediately so no more buffers queue up.
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        // Don't finish the continuation here — the recognizer
        // callback will do that after delivering the final segment
        // group, OR our error path will. That keeps emissions
        // monotonic with respect to the user's stop gesture.

        await logger.info("speech.streaming.stopped")
    }

    // MARK: - Helpers

    private func emit(segmentsFrom transcription: SFTranscription) {
        guard let continuation else { return }
        for apple in transcription.segments {
            let durationMs = Int((apple.duration * 1000.0).rounded())
            let confidence: Double? = apple.confidence > 0 ? Double(apple.confidence) : nil
            let segment = TranscriptSegment(
                text: apple.substring,
                confidence: confidence,
                segmentIndex: nextSegmentIndex,
                durationMs: max(0, durationMs),
                startTimeSeconds: apple.timestamp
            )
            nextSegmentIndex += 1
            continuation.yield(segment)
        }
    }

    private func finishStreamSuccessfully(isBenignNoSpeech: Bool, error: NSError?) {
        let continuation = self.continuation
        self.continuation = nil
        // Benign no-speech and post-stop terminal callbacks finish
        // cleanly. Anything else surfaces as an error on the stream.
        if isBenignNoSpeech || task == nil {
            continuation?.finish()
        } else if let error {
            continuation?.finish(throwing: SpeechTranscriberError.recognitionFailed(
                reason: error.localizedDescription,
                code: error.code
            ))
        } else {
            continuation?.finish()
        }
        task = nil
        request = nil
    }

    private func tearDown() async {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
    }

    private func ensureAuthorized() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            return
        case .denied, .restricted:
            throw SpeechTranscriberError.permissionDenied
        case .notDetermined:
            let resolved = await Self.requestAuthorization()
            switch resolved {
            case .authorized: return
            case .denied, .restricted: throw SpeechTranscriberError.permissionDenied
            case .notDetermined: throw SpeechTranscriberError.permissionDenied
            @unknown default: throw SpeechTranscriberError.permissionDenied
            }
        @unknown default:
            throw SpeechTranscriberError.permissionDenied
        }
    }

    private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
