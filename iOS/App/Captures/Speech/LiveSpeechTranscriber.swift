import Foundation
@preconcurrency import Speech

/// Production ``SpeechTranscriber`` backed by `SFSpeechRecognizer` +
/// `SFSpeechURLRecognitionRequest`. On-device only — we never send
/// audio off-device for transcription (server-side Whisper does the
/// authoritative pass once the .m4a uploads).
///
/// Concurrency model: the actor owns one in-flight recognition task
/// at a time. Each call to `transcribe(...)` starts a new
/// `SFSpeechRecognitionTask` and converts its delegate callbacks
/// into an `AsyncThrowingStream<TranscriptSegment>`. The stream
/// finishes when the recognizer fires `isFinal == true`.
///
/// Segments are derived from the recognizer's `bestTranscription`
/// — we walk `SFTranscription.segments` and emit one
/// ``TranscriptSegment`` per Apple segment, with index, duration,
/// and confidence.
public actor LiveSpeechTranscriber: SpeechTranscriber {

    private let logger: AppLogger

    /// In-flight recognition task. Held so a new transcribe call can
    /// cancel any prior recognition cleanly. Production wiring runs
    /// transcriptions sequentially (the capture service kicks one off
    /// per capture stop) but we still want defensive cancellation.
    private var currentTask: SFSpeechRecognitionTask?

    public init(logger: AppLogger = AppLogger(category: .capture)) {
        self.logger = logger
    }

    // MARK: - SpeechTranscriber

    public func transcribe(
        fileURL: URL,
        locale: Locale?
    ) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        try await ensureAuthorized()

        let chosenLocale = locale ?? Locale(identifier: "en-US")
        guard let recognizer = SFSpeechRecognizer(locale: chosenLocale) else {
            await logger.warning(
                "speech.transcribe.unavailable",
                metadata: ["reason": .string("no recognizer for locale \(chosenLocale.identifier)")]
            )
            throw SpeechTranscriberError.unavailable(
                reason: "no recognizer for locale \(chosenLocale.identifier)"
            )
        }
        guard recognizer.isAvailable else {
            await logger.warning(
                "speech.transcribe.unavailable",
                metadata: ["reason": .string("recognizer not available")]
            )
            throw SpeechTranscriberError.unavailable(reason: "recognizer not available")
        }

        // Verify file is readable before we fire the request — the
        // delegate-based async path otherwise hangs on bad input.
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw SpeechTranscriberError.fileUnreadable(
                reason: "file not readable at \(fileURL.path)"
            )
        }

        await logger.debug(
            "speech.transcribe.attempt",
            metadata: [
                "url": .string(fileURL.lastPathComponent),
                "locale": .string(chosenLocale.identifier)
            ]
        )

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        // On-device — never send audio off-device for transcription.
        // The .m4a uploads to UC volume and the server runs a
        // higher-fidelity pass; this client-side pass is only for
        // the live demo loop.
        request.requiresOnDeviceRecognition = true
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }

        // Cancel any prior task before starting a new one.
        currentTask?.cancel()

        let actorLogger = logger
        let stream = AsyncThrowingStream<TranscriptSegment, Error> { continuation in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    let nsError = error as NSError
                    Task {
                        await actorLogger.warning(
                            "speech.transcribe.failed",
                            metadata: [
                                "domain": .string(nsError.domain),
                                "code": .int(Int64(nsError.code)),
                                "reason": .string(nsError.localizedDescription)
                            ]
                        )
                    }
                    continuation.finish(throwing: SpeechTranscriberError.recognitionFailed(
                        reason: nsError.localizedDescription,
                        code: nsError.code
                    ))
                    return
                }
                guard let result else { return }
                guard result.isFinal else { return }
                let segments = Self.segments(from: result.bestTranscription)
                for segment in segments {
                    continuation.yield(segment)
                }
                Task {
                    await actorLogger.info(
                        "speech.transcribe.ok",
                        metadata: [
                            "segments": .int(Int64(segments.count))
                        ]
                    )
                }
                continuation.finish()
            }
            currentTask = task
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
        return stream
    }

    // MARK: - Helpers

    /// Convert Apple's `SFTranscription.segments` into our typed
    /// ``TranscriptSegment`` value, computing duration_ms and a
    /// mean confidence per segment. SFSpeechRecognizer's
    /// `SFTranscriptionSegment` reports per-segment timing, so we
    /// emit one TranscriptSegment per Apple segment with a
    /// monotonic index starting at 0.
    private static func segments(from transcription: SFTranscription) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for (i, apple) in transcription.segments.enumerated() {
            let durationMs = Int((apple.duration * 1000.0).rounded())
            let confidence: Double? = apple.confidence > 0 ? Double(apple.confidence) : nil
            out.append(
                TranscriptSegment(
                    text: apple.substring,
                    confidence: confidence,
                    segmentIndex: i,
                    durationMs: max(0, durationMs),
                    startTimeSeconds: apple.timestamp
                )
            )
        }
        return out
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
            case .notDetermined:
                // System left us in limbo (rare). Treat as denied so
                // the caller surfaces an actionable banner rather
                // than spinning.
                throw SpeechTranscriberError.permissionDenied
            @unknown default:
                throw SpeechTranscriberError.permissionDenied
            }
        @unknown default:
            throw SpeechTranscriberError.permissionDenied
        }
    }

    /// Wrap `SFSpeechRecognizer.requestAuthorization` (callback-based)
    /// in `withCheckedContinuation` so the actor can await it.
    private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
