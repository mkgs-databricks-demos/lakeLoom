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
/// Emission strategy (v2 — 2026-05-24, after the "silent reset" bug):
/// * `shouldReportPartialResults = true` for diagnostic visibility,
///   but we only **emit** on utterance boundaries — never on
///   mid-utterance partials. Stale partials caused content drops in
///   v1 (see the "silent reset" comment in `processResult`).
/// * A utterance boundary is detected by **either**:
///   - `isFinal=true` (Apple's explicit signal), or
///   - The new callback's first-segment `timestamp` is greater than
///     the previous callback's first-segment `timestamp` (Apple
///     silently rolled `bestTranscription` to a new utterance — a
///     real device behavior we observed where the recognizer
///     "resets" between utterances WITHOUT firing isFinal).
/// * On every detected boundary we emit the **complete** previous
///   utterance through `PhraseGrouper`, so every spoken word lands
///   in exactly one `TranscriptSegment` event. The trailing utterance
///   (no successor to trigger a boundary) flushes from `finishStream`
///   when the buffer drain task closes the stream.
///
/// Trade-off: a phrase only emits when the **next** utterance begins
/// (or the session ends). For a 30 s monologue with no pauses, this
/// means one big emission at session end — fine for the downstream
/// document-generation pipeline (correctness > liveness for the FDE
/// demo), tunable later if in-session UX needs sub-utterance updates.
public actor LiveStreamingSpeechRecognizer: StreamingSpeechRecognizer {

    private let logger: AppLogger

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var bufferDrainTask: Task<Void, Never>?
    private var segmentContinuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation?
    private var didStop = false
    /// Monotonic segment_index counter assigned to emitted phrases.
    private var globalSegmentIndex: Int = 0
    /// Count of times the recognizer fired `isFinal=true`. Buffer
    /// mode fires this at every utterance boundary, not just at
    /// endAudio() — but we observed real-device runs where it
    /// silently resets `bestTranscription` between utterances
    /// **without** firing isFinal. Logged for diagnostic visibility.
    private var finalCallbackCount: Int = 0

    /// Most-recent `bestTranscription` we've seen (as `WordTiming`s),
    /// held until the next utterance boundary so we can emit the
    /// complete utterance once we know it's done. Cleared after
    /// emission.
    private var pendingWords: [WordTiming] = []
    /// First-segment `timestamp` from the most-recent callback. A
    /// later callback whose first-segment timestamp exceeds this is
    /// a silent-reset boundary (a new utterance started). Reset to
    /// `nil` after emission.
    private var lastUtteranceFirstStart: Double?

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
        globalSegmentIndex = 0
        finalCallbackCount = 0
        pendingWords = []
        lastUtteranceFirstStart = nil
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

        // Utterance-boundary emission. We never emit mid-utterance —
        // partials get rewritten or silently reset by Apple, which
        // dropped content in the v1 emission strategy. Two boundary
        // signals:
        //   1. **Explicit:** `isFinal=true`.
        //   2. **Silent reset:** the new callback's first-segment
        //      `startTimeSeconds` is strictly greater than the
        //      previous callback's first-segment value. Apple
        //      rolled `bestTranscription` to a fresh utterance
        //      without firing isFinal. The previous `pendingWords`
        //      is the now-completed utterance — flush it.
        //
        // Within an utterance, the first-segment start stays equal
        // across callbacks (it's anchored to the utterance's audio
        // start time), so equal-first-start callbacks just refine
        // `pendingWords` without emitting.
        if !words.isEmpty {
            let currentFirstStart = words[0].startTimeSeconds
            if let lastStart = lastUtteranceFirstStart, currentFirstStart > lastStart {
                emitUtterance(pendingWords)
            }
            lastUtteranceFirstStart = currentFirstStart
        }
        pendingWords = words

        if isFinal {
            // Explicit utterance-end. Flush whatever we have, then
            // clear the boundary watermark so the next utterance
            // begins fresh.
            emitUtterance(pendingWords)
            pendingWords = []
            lastUtteranceFirstStart = nil
        }

        // Do NOT finish the segment stream on isFinal=true. Apple's
        // buffer mode fires isFinal at every utterance boundary, not
        // just at endAudio; closing on the first one drops every
        // utterance after (the original PR 9b lifecycle bug). The
        // buffer drain task closes the stream once the audio source
        // ends + endAudio is called.
    }

    /// Run `pendingWords` through `PhraseGrouper` and emit each
    /// resulting phrase as its own `TranscriptSegment`. No-op for
    /// empty word lists.
    private func emitUtterance(_ words: [WordTiming]) {
        guard !words.isEmpty else { return }
        let phrases = PhraseGrouper.phrases(from: words)
        for phrase in phrases {
            let segment = TranscriptSegment(
                text: phrase.text,
                confidence: phrase.confidence,
                segmentIndex: globalSegmentIndex,
                durationMs: phrase.durationMs,
                startTimeSeconds: phrase.startTimeSeconds
            )
            segmentContinuation?.yield(segment)
            globalSegmentIndex += 1
        }
    }

    private func finishStream(error: NSError?) async {
        guard segmentContinuation != nil else { return }
        // Flush the trailing utterance. If Apple never delivered a
        // terminal `isFinal=true` after `endAudio()` (e.g., the
        // drain-task timeout fired first), the last utterance's
        // words are still sitting in `pendingWords`. Boundary
        // detection isn't going to fire again — the stream is
        // closing — so do the emit here so no content is lost.
        emitUtterance(pendingWords)
        pendingWords = []
        lastUtteranceFirstStart = nil

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
