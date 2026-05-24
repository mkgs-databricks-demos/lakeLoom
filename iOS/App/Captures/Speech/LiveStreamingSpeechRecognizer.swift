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
    /// Highest phrase start time we've already yielded. Used to
    /// dedupe across multiple result callbacks. Robust to two Apple
    /// behaviors we observed:
    ///   1. `bestTranscription` is cumulative across callbacks
    ///      (start times increase monotonically — easy case).
    ///   2. `bestTranscription` resets per utterance with
    ///      utterance-relative or session-absolute start times
    ///      — start times still grow monotonically across utterances
    ///      because the recorder's clock keeps advancing.
    /// Either way, we only emit a phrase when its start exceeds
    /// what we've emitted so far.
    private var maxEmittedStartTime: Double = -.infinity
    /// Monotonic segment_index counter assigned to emitted phrases.
    private var globalSegmentIndex: Int = 0
    /// Count of times the recognizer fired `isFinal=true`. Buffer
    /// mode fires this at every utterance boundary, not just at
    /// endAudio() — so multiple finals per session is normal.
    /// Logged for diagnostic visibility.
    private var finalCallbackCount: Int = 0

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
        maxEmittedStartTime = -.infinity
        globalSegmentIndex = 0
        finalCallbackCount = 0
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
            // Buffer stream finished (recorder stopped or cancelled).
            // Signal end-of-input to the recognizer; it will fire one
            // last `isFinal=true` callback with any trailing utterance.
            drainRequest.endAudio()
            // Give the recognizer a brief window to deliver the
            // post-endAudio terminal callback. Empirically Apple
            // fires it within ~200ms; 1.5s is comfortable headroom
            // without making Stop feel sluggish. After the window,
            // we finish the segment stream so awaiters unblock —
            // whether or not the terminal callback arrived.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self.finishStream(error: nil)
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
        if isFinal { finalCallbackCount += 1 }

        let words = transcription.segments.map { apple -> WordTiming in
            WordTiming(
                text: apple.substring,
                startTimeSeconds: apple.timestamp,
                durationSeconds: apple.duration,
                confidence: apple.confidence
            )
        }
        let phrases = PhraseGrouper.phrases(from: words)

        // Per-callback diagnostic. Lets us see in the device log
        // how Apple is delivering results — multiple isFinal=true
        // callbacks per session are normal in buffer mode (one per
        // utterance), and we want visibility into whether that's
        // what's happening.
        let preview = transcription.formattedString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(60)
        let isFinalCopy = isFinal
        let wordCount = transcription.segments.count
        let finalCallbackCountCopy = finalCallbackCount
        let phraseCount = phrases.count
        Task { [logger] in
            await logger.debug(
                "speech.streaming.callback",
                metadata: [
                    "is_final": .string(String(isFinalCopy)),
                    "words": .int(Int64(wordCount)),
                    "phrases": .int(Int64(phraseCount)),
                    "preview": .string(preview.isEmpty ? "(empty)" : String(preview)),
                    "final_callbacks_so_far": .int(Int64(finalCallbackCountCopy))
                ]
            )
        }

        // Emission strategy: for each phrase from Apple, emit it if
        // its startTime exceeds the highest we've emitted so far.
        // This handles BOTH possible Apple behaviors:
        //   (a) bestTranscription cumulative — start times grow
        //       monotonically; we just emit new ones.
        //   (b) bestTranscription per-utterance — each callback
        //       brings fresh phrases, but timestamps are
        //       session-absolute (relative to recorder start), so
        //       new utterances naturally have higher start times.
        //
        // For non-final callbacks, hold back the LAST phrase unless
        // it ends with sentence punctuation — it may still grow
        // and we don't want to emit then re-emit different text.
        for (i, phrase) in phrases.enumerated() {
            let isLastPhrase = i == phrases.count - 1
            let endsInSentencePunct = phrase.text
                .trimmingCharacters(in: .whitespaces)
                .last.map { ".!?".contains($0) } ?? false
            let isStable = isFinal || !isLastPhrase || endsInSentencePunct
            guard isStable else { continue }
            guard phrase.startTimeSeconds > maxEmittedStartTime else { continue }

            let yielded = TranscriptSegment(
                text: phrase.text,
                confidence: phrase.confidence,
                segmentIndex: globalSegmentIndex,
                durationMs: phrase.durationMs,
                startTimeSeconds: phrase.startTimeSeconds
            )
            segmentContinuation?.yield(yielded)
            globalSegmentIndex += 1
            maxEmittedStartTime = phrase.startTimeSeconds
        }

        // CRITICAL: do NOT finish the segment stream on isFinal=true.
        // In buffer mode with shouldReportPartialResults=true, Apple
        // fires isFinal at every utterance boundary, not just at
        // endAudio. Closing on the first one would drop everything
        // after — which is exactly the bug we saw in PR 9b's first
        // device test (only the first utterance landed in
        // transcript_events_raw). The drain task closes the stream
        // once the buffer source ends + we've called endAudio.
    }

    private func finishStream(error: NSError?) async {
        guard segmentContinuation != nil else { return }
        let continuation = segmentContinuation
        segmentContinuation = nil
        task?.cancel()
        task = nil
        request = nil
        let total = globalSegmentIndex
        let finals = finalCallbackCount
        await logger.info(
            "speech.streaming.ok",
            metadata: [
                "phrases_emitted": .int(Int64(total)),
                "final_callbacks": .int(Int64(finals))
            ]
        )
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
