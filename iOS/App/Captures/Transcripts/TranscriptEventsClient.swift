import Foundation

/// Transport-layer protocol for the lakeLoom Databricks App's
/// ZeroBus transcript ingest endpoint.
///
/// ```
/// POST /api/sessions/<paired_session_id>/events
/// Content-Type: application/json
/// Authorization: Bearer <m2m>
/// X-Lakeloom-Session-Token: <session_token>
/// X-Lakeloom-Timestamp: <unix_seconds>
/// X-Lakeloom-Signature: <ECDSA-P-256 over METHOD\nPATH\nTIMESTAMP\nBODY_SHA256_HEX>
///
/// Body: [TranscriptEvent, ...]  (1..100 events per POST)
/// 202 -> { "accepted": <Int> }
/// ```
///
/// Wire contract: `architecture/hey_isaac/2026-05-21_zerobus-ingest-live-start-sending.md`.
///
/// All auth lives in ``LakeloomAppClient`` — the live implementation
/// routes through it so callers (TranscriptStreamer, smoke test,
/// AppCoordinator) never see signing or M2M-token plumbing.
public protocol TranscriptEventsClient: Sendable {

    /// Send `events` to the paired session's ZeroBus endpoint. The
    /// server takes a single event OR an array; this client always
    /// sends an array (the wire shape stays consistent regardless of
    /// batch size). Returns the server-confirmed accepted count —
    /// usually equal to `events.count`, but we surface the actual
    /// value so callers can detect partial-acceptance scenarios if
    /// Genie ever adds them.
    ///
    /// Pre-flight checks:
    /// * empty array → throws ``TranscriptEventsError/empty``
    /// * more than 100 → throws ``TranscriptEventsError/batchTooLarge``
    func sendEvents(
        workspaceID: String,
        pairedSessionID: String,
        events: [TranscriptEvent]
    ) async throws -> Int
}

public extension TranscriptEventsClient {
    /// Convenience for the common singleton case.
    func sendEvent(
        workspaceID: String,
        pairedSessionID: String,
        event: TranscriptEvent
    ) async throws -> Int {
        try await sendEvents(
            workspaceID: workspaceID,
            pairedSessionID: pairedSessionID,
            events: [event]
        )
    }
}

// MARK: - Live implementation

public actor LiveTranscriptEventsClient: TranscriptEventsClient {

    /// Hard cap from Genie's note. Past this the server 422s — we
    /// short-circuit so callers can split before hitting the wire.
    public static let maxEventsPerRequest: Int = 100

    private let lakeloomApp: any LakeloomAppClient
    private let encoder: JSONEncoder
    private let logger: AppLogger

    public init(
        lakeloomApp: any LakeloomAppClient,
        logger: AppLogger = AppLogger(category: .auth)
    ) {
        self.lakeloomApp = lakeloomApp
        self.logger = logger
        self.encoder = JSONEncoder()
        // Genie's note: "Body must be compact JSON — no extra
        // whitespace. The ECDSA signature covers the exact bytes."
        // The default JSONEncoder output is compact (no
        // prettyPrinted), so we just confirm by leaving formatting
        // empty rather than relying on platform defaults.
        self.encoder.outputFormatting = []
    }

    public func sendEvents(
        workspaceID: String,
        pairedSessionID: String,
        events: [TranscriptEvent]
    ) async throws -> Int {
        guard !events.isEmpty else { throw TranscriptEventsError.empty }
        guard events.count <= Self.maxEventsPerRequest else {
            throw TranscriptEventsError.batchTooLarge(count: events.count)
        }

        let bodyData: Data
        do {
            bodyData = try encoder.encode(events)
        } catch {
            throw TranscriptEventsError.unexpectedResponse(
                reason: "encode events: \(error)"
            )
        }

        let path = "/api/sessions/\(pairedSessionID)/events"

        await logger.debug(
            "transcript.events.attempt",
            metadata: [
                "method": .string("POST"),
                "path": .string(path),
                "count": .int(Int64(events.count))
            ]
        )

        struct AcceptedResponse: Decodable, Sendable {
            let accepted: Int
        }

        do {
            let response: AcceptedResponse = try await lakeloomApp.request(
                workspaceID: workspaceID,
                method: .post,
                path: path,
                body: bodyData,
                decode: AcceptedResponse.self
            )
            await logger.info(
                "transcript.events.ok",
                metadata: ["accepted": .int(Int64(response.accepted))]
            )
            return response.accepted
        } catch let error as LakeloomAppError {
            let mapped = TranscriptEventsError.from(error)
            await logger.error(
                "transcript.events.failed",
                metadata: [
                    "path": .string(path),
                    "count": .int(Int64(events.count)),
                    "reason": .string(String(describing: mapped))
                ],
                errorCode: String(describing: mapped)
                    .split(separator: "(").first.map(String.init) ?? "unknown"
            )
            throw mapped
        } catch let error as TranscriptEventsError {
            throw error
        } catch {
            throw TranscriptEventsError.unexpectedResponse(
                reason: error.localizedDescription
            )
        }
    }
}
