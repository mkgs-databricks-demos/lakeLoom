import Foundation

/// Buffers ``TranscriptSegment``s coming off a ``SpeechTranscriber``
/// and POSTs them to ``TranscriptEventsClient`` in batches with
/// retry classification. Sits between the capture service's segment
/// loop and the wire — callers don't see individual sends, just
/// "drain this stream of segments into ZeroBus."
///
/// Why this exists:
/// * **Batching** — Genie's endpoint accepts up to 100 events per
///   POST. Sending one-at-a-time wastes the round-trip; batching
///   amortizes the cost.
/// * **Retry** — first send of a session may hit a cold ZeroBus
///   pool (~500ms wake) and surface as a 5xx. Without retry the
///   first batch silently disappears; with retry it lands within
///   seconds.
/// * **Failure isolation** — a permanent failure on one batch
///   (e.g. server-side validation regression) shouldn't poison the
///   rest of the stream. Each batch is independent.
///
/// The transcription pipeline is best-effort (Genie's server-side
/// Whisper pass is the authoritative transcript per her AI pipeline
/// note), so this streamer never throws to the caller. Failures are
/// logged at warning; the audio file still uploads regardless.
public protocol TranscriptStreamer: Sendable {
    /// Drain `segments` into the events endpoint, batching as
    /// configured. Returns when the stream is fully consumed (all
    /// batches flushed, including the final partial). The `source`
    /// + `model` + `language` strings are applied uniformly to
    /// every emitted event; the per-segment fields come from the
    /// stream.
    func stream(
        workspaceID: String,
        pairedSessionID: String,
        projectID: String,
        deviceID: String?,
        recordingStartedAt: Date,
        segments: AsyncThrowingStream<TranscriptSegment, Error>,
        source: String,
        model: String,
        language: String
    ) async
}

// MARK: - Live implementation

public actor LiveTranscriptStreamer: TranscriptStreamer {

    /// Hard cap per Genie's contract. Public so call-sites that pre-
    /// shape batches (future SpeechAnalyzer chunking) can match.
    public static let defaultMaxBatchSize: Int = 100

    /// Default linear backoff schedule used for transient failures.
    /// Three attempts total (initial + 2 retries) with widening gaps.
    public static let defaultRetryBackoffSeconds: [TimeInterval] = [0.5, 1.5, 3.5]

    private let events: any TranscriptEventsClient
    private let maxBatchSize: Int
    private let retryBackoffSeconds: [TimeInterval]
    private let logger: AppLogger
    private let sleep: @Sendable (TimeInterval) async -> Void

    public init(
        events: any TranscriptEventsClient,
        maxBatchSize: Int = LiveTranscriptStreamer.defaultMaxBatchSize,
        retryBackoffSeconds: [TimeInterval] = LiveTranscriptStreamer.defaultRetryBackoffSeconds,
        logger: AppLogger = AppLogger(category: .capture)
    ) {
        self.init(
            events: events,
            maxBatchSize: maxBatchSize,
            retryBackoffSeconds: retryBackoffSeconds,
            logger: logger,
            sleep: { seconds in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            }
        )
    }

    /// Test-only init — lets tests stub the backoff sleep so they
    /// don't actually wait seconds between retry attempts.
    init(
        events: any TranscriptEventsClient,
        maxBatchSize: Int,
        retryBackoffSeconds: [TimeInterval],
        logger: AppLogger,
        sleep: @Sendable @escaping (TimeInterval) async -> Void
    ) {
        precondition(maxBatchSize > 0, "maxBatchSize must be positive")
        precondition(!retryBackoffSeconds.isEmpty, "need at least one attempt")
        self.events = events
        self.maxBatchSize = maxBatchSize
        self.retryBackoffSeconds = retryBackoffSeconds
        self.logger = logger
        self.sleep = sleep
    }

    public func stream(
        workspaceID: String,
        pairedSessionID: String,
        projectID: String,
        deviceID: String?,
        recordingStartedAt: Date,
        segments: AsyncThrowingStream<TranscriptSegment, Error>,
        source: String,
        model: String,
        language: String
    ) async {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var buffer: [TranscriptEvent] = []
        buffer.reserveCapacity(maxBatchSize)

        do {
            for try await segment in segments {
                let event = makeEvent(
                    segment: segment,
                    projectID: projectID,
                    deviceID: deviceID,
                    recordingStartedAt: recordingStartedAt,
                    source: source,
                    model: model,
                    language: language,
                    isoFormatter: isoFormatter
                )
                buffer.append(event)
                if buffer.count >= maxBatchSize {
                    await flush(
                        batch: buffer,
                        workspaceID: workspaceID,
                        pairedSessionID: pairedSessionID
                    )
                    buffer.removeAll(keepingCapacity: true)
                }
                if Task.isCancelled { return }
            }
        } catch {
            await logger.warning(
                "transcript.streamer.source_failed",
                metadata: [
                    "reason": .string(String(describing: error))
                ]
            )
            // Fall through — flush whatever we buffered up to this
            // point. Losing the tail in a mid-stream failure is
            // worse than losing nothing.
        }

        if !buffer.isEmpty {
            await flush(
                batch: buffer,
                workspaceID: workspaceID,
                pairedSessionID: pairedSessionID
            )
        }
    }

    // MARK: - Private

    private func makeEvent(
        segment: TranscriptSegment,
        projectID: String,
        deviceID: String?,
        recordingStartedAt: Date,
        source: String,
        model: String,
        language: String,
        isoFormatter: ISO8601DateFormatter
    ) -> TranscriptEvent {
        let eventTime = recordingStartedAt.addingTimeInterval(segment.startTimeSeconds)
        return TranscriptEvent(
            eventType: .finalTranscript,
            text: segment.text,
            confidence: segment.confidence,
            language: language,
            segmentIndex: segment.segmentIndex,
            durationMs: segment.durationMs,
            source: source,
            model: model,
            projectID: projectID,
            deviceID: deviceID,
            eventTime: isoFormatter.string(from: eventTime)
        )
    }

    /// Send `batch` with retry classification. Transient failures
    /// (network / timeout / 5xx) burn the backoff schedule; permanent
    /// failures (validation / forbidden / authFailed) drop the batch
    /// immediately. Either way, the streamer continues to subsequent
    /// batches — one bad batch does not poison the whole stream.
    private func flush(
        batch: [TranscriptEvent],
        workspaceID: String,
        pairedSessionID: String
    ) async {
        guard !batch.isEmpty else { return }

        await logger.debug(
            "transcript.streamer.flush.attempt",
            metadata: [
                "count": .int(Int64(batch.count)),
                "first_index": .int(Int64(batch.first?.segmentIndex ?? -1)),
                "last_index": .int(Int64(batch.last?.segmentIndex ?? -1))
            ]
        )

        for (attempt, delaySeconds) in retryBackoffSeconds.enumerated() {
            if Task.isCancelled { return }
            if attempt > 0 {
                await sleep(delaySeconds)
                if Task.isCancelled { return }
            }
            do {
                let accepted = try await events.sendEvents(
                    workspaceID: workspaceID,
                    pairedSessionID: pairedSessionID,
                    events: batch
                )
                await logger.info(
                    "transcript.streamer.flush.ok",
                    metadata: [
                        "accepted": .int(Int64(accepted)),
                        "attempt": .int(Int64(attempt + 1))
                    ]
                )
                return
            } catch let error as TranscriptEventsError {
                if Self.isTransient(error) {
                    await logger.warning(
                        "transcript.streamer.flush.transient",
                        metadata: [
                            "attempt": .int(Int64(attempt + 1)),
                            "reason": .string(String(describing: error))
                        ]
                    )
                    continue
                } else {
                    await logger.error(
                        "transcript.streamer.flush.permanent",
                        metadata: [
                            "reason": .string(String(describing: error))
                        ],
                        errorCode: String(describing: error)
                            .split(separator: "(").first.map(String.init) ?? "permanent"
                    )
                    return
                }
            } catch {
                await logger.warning(
                    "transcript.streamer.flush.unknown",
                    metadata: [
                        "attempt": .int(Int64(attempt + 1)),
                        "reason": .string(error.localizedDescription)
                    ]
                )
                continue
            }
        }
        await logger.error(
            "transcript.streamer.flush.exhausted",
            metadata: [
                "attempts": .int(Int64(retryBackoffSeconds.count)),
                "count": .int(Int64(batch.count))
            ],
            errorCode: "retry_exhausted"
        )
    }

    private static func isTransient(_ error: TranscriptEventsError) -> Bool {
        switch error {
        case .networkUnavailable,
             .timeout,
             .serverUnavailable:
            return true
        case .notSignedIn,
             .validationFailed,
             .forbidden,
             .notFound,
             .authFailed,
             .decodeFailed,
             .empty,
             .batchTooLarge,
             .unexpectedResponse:
            return false
        }
    }
}
