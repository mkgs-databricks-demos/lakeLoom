import Foundation

/// Production ``AudioRecorder``. Owns the state machine and the
/// on-disk file layout; delegates CoreAudio specifics to
/// ``AudioRecordingEngine``.
///
/// File layout: each recording lands at
/// `<Application Support>/Captures/<captureSessionID>/audio-<ISO8601>.m4a`.
/// Application Support is chosen over `tmp/` so recordings survive
/// app termination — the upload coordinator (next PR) can resume
/// pending uploads on the following launch. The directory is also
/// excluded from iCloud backup (recordings are server-of-truth on
/// the Databricks side).
public actor LiveAudioRecorder: AudioRecorder {

    private let engine: AudioRecordingEngine
    private let logger: AppLogger
    /// Resolved on each `start()` so tests can inject a per-test
    /// sandbox without subclassing `FileManager` (which the strict
    /// concurrency model treats as non-`Sendable` once subclassed).
    private let baseDirectoryProvider: @Sendable () throws -> URL
    private let nowProvider: @Sendable () -> Date

    private var current: RecordingInFlight?

    private struct RecordingInFlight: Sendable {
        let captureSessionID: String
        let url: URL
        let startedAt: Date
    }

    public init(
        logger: AppLogger = AppLogger(category: .capture)
    ) {
        self.engine = LiveAudioRecordingEngine()
        self.logger = logger
        self.baseDirectoryProvider = Self.defaultApplicationSupportDirectory
        self.nowProvider = Date.init
    }

    init(
        engine: AudioRecordingEngine,
        baseDirectoryProvider: @Sendable @escaping () throws -> URL = LiveAudioRecorder.defaultApplicationSupportDirectory,
        logger: AppLogger = AppLogger(category: .capture),
        nowProvider: @Sendable @escaping () -> Date = Date.init
    ) {
        self.engine = engine
        self.logger = logger
        self.baseDirectoryProvider = baseDirectoryProvider
        self.nowProvider = nowProvider
    }

    @Sendable
    private static func defaultApplicationSupportDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    public var state: AudioRecorderState {
        if let current {
            return .recording(captureSessionID: current.captureSessionID, startedAt: current.startedAt)
        }
        return .idle
    }

    public func start(captureSessionID: String) async throws -> URL {
        guard current == nil else {
            throw AudioRecorderError.alreadyRecording
        }

        // Permission gate. We block on `requestPermission()` so the
        // caller doesn't have to wire a separate prompt — first
        // launch will show the system dialog; subsequent launches
        // resolve instantly with cached status.
        let granted = await engine.requestPermission()
        guard granted else {
            await logger.warning("audio.recorder.permission_denied")
            throw AudioRecorderError.permissionDenied
        }

        let startedAt = nowProvider()
        let url: URL
        do {
            url = try makeRecordingURL(captureSessionID: captureSessionID, startedAt: startedAt)
        } catch let error as AudioRecorderError {
            throw error
        } catch {
            throw AudioRecorderError.fileSystemError(reason: error.localizedDescription)
        }

        do {
            try await engine.start(writingTo: url)
        } catch let error as AudioRecorderError {
            await logger.error(
                "audio.recorder.start_failed",
                metadata: [
                    "capture_session_id": .string(captureSessionID),
                    "reason": .string(String(describing: error))
                ],
                errorCode: String(describing: error).split(separator: "(").first.map(String.init) ?? "engine"
            )
            throw error
        } catch {
            throw AudioRecorderError.engineFailure(reason: error.localizedDescription)
        }

        current = RecordingInFlight(captureSessionID: captureSessionID, url: url, startedAt: startedAt)
        await logger.info(
            "audio.recorder.started",
            metadata: [
                "capture_session_id": .string(captureSessionID),
                "url": .string(url.lastPathComponent)
            ]
        )
        return url
    }

    public func stop() async throws -> AudioRecording {
        guard let inFlight = current else {
            throw AudioRecorderError.notRecording
        }

        let duration: Double
        do {
            duration = try await engine.stop()
        } catch let error as AudioRecorderError {
            // Engine threw mid-stop. Drop our state — the partial
            // file may exist; leave it on disk so a debug build
            // can inspect it. Production won't see it again.
            current = nil
            throw error
        } catch {
            current = nil
            throw AudioRecorderError.engineFailure(reason: error.localizedDescription)
        }

        let endedAt = nowProvider()
        let sizeBytes = fileSize(at: inFlight.url)

        current = nil
        await logger.info(
            "audio.recorder.stopped",
            metadata: [
                "capture_session_id": .string(inFlight.captureSessionID),
                "duration_s": .string(String(format: "%.3f", duration)),
                "bytes": .int(sizeBytes)
            ]
        )
        return AudioRecording(
            captureSessionID: inFlight.captureSessionID,
            fileURL: inFlight.url,
            startedAt: inFlight.startedAt,
            endedAt: endedAt,
            durationSeconds: duration,
            sizeBytes: sizeBytes,
            mimeType: "audio/mp4",
            fileExtension: "m4a"
        )
    }

    public func cancel() async {
        guard let inFlight = current else { return }
        await engine.cancel()
        current = nil
        try? FileManager.default.removeItem(at: inFlight.url)
        await logger.info(
            "audio.recorder.cancelled",
            metadata: ["capture_session_id": .string(inFlight.captureSessionID)]
        )
    }

    // MARK: - File layout

    private func makeRecordingURL(captureSessionID: String, startedAt: Date) throws -> URL {
        let base: URL
        do {
            base = try baseDirectoryProvider()
        } catch {
            throw AudioRecorderError.fileSystemError(reason: "appSupport: \(error.localizedDescription)")
        }
        let dir = base
            .appendingPathComponent("Captures", isDirectory: true)
            .appendingPathComponent(captureSessionID, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Exclude from iCloud backup — recordings are uploaded
            // to UC Volumes; the on-device copy is a staging area.
            var dirToFlag = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dirToFlag.setResourceValues(values)
        } catch {
            throw AudioRecorderError.fileSystemError(reason: "mkdir: \(error.localizedDescription)")
        }
        let stamp = Self.filenameTimestamp(startedAt)
        return dir.appendingPathComponent("audio-\(stamp).m4a", isDirectory: false)
    }

    private func fileSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }

    private static func filenameTimestamp(_ date: Date) -> String {
        // ":" is illegal in file names on some sync providers; use
        // the basic ISO8601 profile (no separators) which is also
        // shorter. Constructing the formatter per call avoids
        // sharing non-`Sendable` Foundation state across the actor.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        return formatter.string(from: date)
    }
}
