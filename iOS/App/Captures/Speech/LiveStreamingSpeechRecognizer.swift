@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

/// Production ``StreamingSpeechRecognizer`` backed by
/// `SFSpeechAudioBufferRecognitionRequest`. Consumes the recorder's
/// live audio buffers (via ``AudioBufferSource``) and emits
/// ``TranscriptSegment``s as the recognizer hypothesizes / commits
/// them, every 1-3 seconds during a recording.
///
/// On-device only — `requiresOnDeviceRecognition = true`. Audio
/// buffers never leave the device for transcription; the .m4a
/// uploads in parallel to UC volume and the server-side Whisper
/// pass handles the authoritative transcript per Genie's AI
/// pipeline note.
///
/// Emission strategy (v1):
/// * `shouldReportPartialResults = true` so we get incremental
///   callbacks as recognition progresses.
/// * Each callback delivers `bestTranscription` containing all
///   recognized words so far.
/// * We run those words through ``PhraseGrouper`` (pause-based +
///   sentence-punctuation-based) and emit any phrases past what
///   we've already yielded. On non-final callbacks we hold back
///   the last phrase (it may still grow); on final we emit
///   everything.
/// * Tracking is by phrase count rather than start-time so minor
///   word-boundary revisions in earlier phrases don't cause
///   re-emission.
public actor LiveStreamingSpeechRecognizer: StreamingSpeechRecognizer {

    private let logger: AppLogger

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var bufferDrainTask: Task<Void, Never>?
    private var segmentContinuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation?
    private var didStop = false
    /// Number of phrases we've already yielded from the current
    /// recognition session. Each `processResult` call emits
    /// phrases[emittedCount...] only.
    private var emittedPhraseCount = 0

    public init(logger: AppLogger = AppLogger(category: .capture)) {
        self.logger = logger
    }

    // MARK: - StreamingSpeechRecognizer

    public func transcripts(
        buffers: AsyncStream<PCMBufferEnvelope>
    ) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        // Guard against double-start.
        guard task == nil else {
            throw SpeechTranscriberError.recognitionFailed(
                reason: "streaming recognizer already started",
                code: nil
            )
        }

        try await ensureAuthorized()

        let chosenLocale = Locale(identifier: "en-US")
        guard let recognizerLocal = SFSpeechRecognizer(locale: chosenLocale) else {
            throw SpeechTranscriberError.unavailable(
                reason: "no recognizer for locale \(chosenLocale.identifier)"
            )
        }
        guard recognizerLocal.isAvailable else {
            throw SpeechTranscriberError.unavailable(reason: "recognizer not available")
        }
        guard recognizerLocal.supportsOnDeviceRecognition else {
            throw SpeechTranscriberError.unavailable(
                reason: "on-device recognition not supported for \(chosenLocale.identifier)"
            )
        }
        self.recognizer = recognizerLocal

        let requestLocal = SFSpeechAudioBufferRecognitionRequest()
        // Live emission requires partial results — the recognizer
        // streams hypotheses as audio is processed, and we extract
        // sentence-bounded phrases from each callback.
        requestLocal.shouldReportPartialResults = true
        requestLocal.requiresOnDeviceRecognition = true
        if #available(iOS 16.0, *) {
            requestLocal.addsPunctuation = true
        }
        self.request = requestLocal

        // Reset per-session state.
        emittedPhraseCount = 0
        didStop = false

        let (stream, continuation) = AsyncThrowingStream<TranscriptSegment, Error>.makeStream()
        self.segmentContinuation = continuation

        await logger.debug(
            "speech.streaming.attempt",
            metadata: [
                "locale": .string(chosenLocale.identifier),
                "on_device_supported": .string(String(recognizerLocal.supportsOnDeviceRecognition))
            ]
        )

        let actorLogger = logger
        let recognitionTask = recognizerLocal.recognitionTask(with: requestLocal) { [weak self] result, error in
            guard let self else { return }
            if let error {
                let nsError = error as NSError
                // SFSpeechRecognitionErrorDomain code 1 / kAFAssistantErrorDomain
                // code 1 = "No speech detected", which fires on
                // silence at end-of-stream. Treat as a clean finish,
                // not a hard failure.
                let isBenignNoSpeech = nsError.code == 1 &&
                    (nsError.domain == "kAFAssistantErrorDomain" || nsError.domain == "SFSpeechErrorDomain")
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
                    await self.finishStream(error: isBenignNoSpeech ? nil : nsError)
                }
                return
            }
            guard let result else { return }
            Task {
                await self.processResult(result)
            }
        }
        self.task = recognitionTask

        // Drain the recorder's buffer stream into the recognizer.
        // Runs in a detached Task so it doesn't block the actor
        // and remains decoupled from the segment stream's lifecycle.
        // When the buffer stream finishes (recorder stops or
        // cancels), we call request.endAudio() so the recognizer
        // fires its terminal `isFinal=true` callback.
        // Drain buffers on a regular Task (inherits actor isolation).
        // SFSpeechAudioBufferRecognitionRequest.append is documented
        // as thread-safe, so calling it from actor context is fine.
        // Can't use Task.detached here because AVAudioPCMBuffer
        // isn't Sendable in strict concurrency mode.
        let drainRequest = requestLocal
        self.bufferDrainTask = Task {
            for await envelope in buffers {
                if Task.isCancelled { break }
                drainRequest.append(envelope.buffer)
            }
            drainRequest.endAudio()
        }

        return stream
    }

    public func stop() async {
        guard !didStop else { return }
        didStop = true
        request?.endAudio()
        // Don't finish the segment stream here — let the recognizer's
        // terminal isFinal callback fire (delivers the final hypothesis)
        // and finish the stream cleanly via finishStream(). The
        // bufferDrainTask completes naturally when the recorder's
        // buffer stream ends; we don't cancel it here.
        await logger.info("speech.streaming.stopped")
    }

    // MARK: - Result processing

    private func processResult(_ result: SFSpeechRecognitionResult) {
        let transcription = result.bestTranscription
        let isFinal = result.isFinal

        // Run the FULL transcription through PhraseGrouper. Phrase
        // boundaries (pause + punctuation) are stable enough that
        // a phrase, once delimited, rarely changes — so emitting
        // phrases[emittedCount...] gives us incremental delivery
        // without major duplicate noise.
        let words = transcription.segments.map { apple -> WordTiming in
            WordTiming(
                text: apple.substring,
                startTimeSeconds: apple.timestamp,
                durationSeconds: apple.duration,
                confidence: apple.confidence
            )
        }
        let phrases = PhraseGrouper.phrases(from: words)

        // On non-final callbacks, hold back the LAST phrase — it
        // may still grow as more audio is processed. On final,
        // emit everything including the last.
        let emittableEnd: Int
        if isFinal {
            emittableEnd = phrases.count
        } else if phrases.count > 0 {
            emittableEnd = phrases.count - 1
        } else {
            emittableEnd = 0
        }

        if emittableEnd > emittedPhraseCount {
            let toEmit = phrases[emittedPhraseCount..<emittableEnd]
            for phrase in toEmit {
                // Re-index with our session-monotonic counter so
                // downstream consumers see a clean 0, 1, 2, ...
                // segment_index sequence even though PhraseGrouper
                // computed indices relative to its input.
                let yielded = TranscriptSegment(
                    text: phrase.text,
                    confidence: phrase.confidence,
                    segmentIndex: emittedPhraseCount,
                    durationMs: phrase.durationMs,
                    startTimeSeconds: phrase.startTimeSeconds
                )
                segmentContinuation?.yield(yielded)
                emittedPhraseCount += 1
            }
        }

        if isFinal {
            let phraseCount = emittedPhraseCount
            let wordCount = transcription.segments.count
            Task {
                await logger.info(
                    "speech.streaming.ok",
                    metadata: [
                        "phrases": .int(Int64(phraseCount)),
                        "raw_word_segments": .int(Int64(wordCount))
                    ]
                )
            }
            finishStream(error: nil)
        }
    }

    private func finishStream(error: NSError?) {
        let continuation = segmentContinuation
        segmentContinuation = nil
        task = nil
        request = nil
        if let error {
            continuation?.finish(throwing: SpeechTranscriberError.recognitionFailed(
                reason: error.localizedDescription,
                code: error.code
            ))
        } else {
            continuation?.finish()
        }
    }

    // MARK: - Permission

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
