import Foundation

/// Production ``PhotoCapture``. Owns nothing but the engine + a
/// few injected dependencies. Photo capture is stateless past a
/// single `capturePhoto()` call, so there's no in-flight context
/// to track (contrast with ``LiveAudioRecorder`` which holds a
/// start/stop pair).
public actor LivePhotoCapture: PhotoCapture {

    private let engine: PhotoCaptureEngine
    private let logger: AppLogger
    private let nowProvider: @Sendable () -> Date
    private let baseDirectoryProvider: @Sendable () throws -> URL

    public init(
        logger: AppLogger = AppLogger(category: .capture)
    ) {
        self.engine = LivePhotoCaptureEngine()
        self.logger = logger
        self.nowProvider = Date.init
        self.baseDirectoryProvider = LivePhotoCapture.defaultApplicationSupportDirectory
    }

    init(
        engine: PhotoCaptureEngine,
        baseDirectoryProvider: @Sendable @escaping () throws -> URL = LivePhotoCapture.defaultApplicationSupportDirectory,
        logger: AppLogger = AppLogger(category: .capture),
        nowProvider: @Sendable @escaping () -> Date = Date.init
    ) {
        self.engine = engine
        self.logger = logger
        self.nowProvider = nowProvider
        self.baseDirectoryProvider = baseDirectoryProvider
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

    public func capturePhoto(captureSessionID: String) async throws -> CapturedPhoto {
        // Permission gate. Like the audio recorder, we prompt
        // synchronously so the caller doesn't have to wire a
        // separate flow.
        let granted = await engine.requestPermission()
        guard granted else {
            await logger.warning("photo.capture.permission_denied")
            throw PhotoCaptureError.permissionDenied
        }

        let capturedAt = nowProvider()
        let fileURL: URL
        do {
            fileURL = try makePhotoURL(captureSessionID: captureSessionID, capturedAt: capturedAt)
        } catch let error as PhotoCaptureError {
            throw error
        } catch {
            throw PhotoCaptureError.fileSystemError(reason: error.localizedDescription)
        }

        await logger.debug(
            "photo.capture.attempt",
            metadata: [
                "capture_session_id": .uuidPrefix(captureSessionID),
                "url": .string(fileURL.lastPathComponent)
            ]
        )

        let jpegData: Data
        do {
            jpegData = try await engine.captureJPEG()
        } catch let error as PhotoCaptureError {
            await logger.error(
                "photo.capture.failed",
                metadata: [
                    "capture_session_id": .uuidPrefix(captureSessionID),
                    "reason": .string(String(describing: error))
                ],
                errorCode: String(describing: error).split(separator: "(").first.map(String.init) ?? "engine"
            )
            throw error
        } catch {
            throw PhotoCaptureError.captureFailed(reason: error.localizedDescription)
        }

        do {
            try jpegData.write(to: fileURL, options: [.atomic])
        } catch {
            throw PhotoCaptureError.fileSystemError(reason: "write: \(error.localizedDescription)")
        }

        let sizeBytes = Int64(jpegData.count)
        await logger.info(
            "photo.capture.ok",
            metadata: [
                "capture_session_id": .uuidPrefix(captureSessionID),
                "bytes": .int(sizeBytes)
            ]
        )
        return CapturedPhoto(
            captureSessionID: captureSessionID,
            fileURL: fileURL,
            capturedAt: capturedAt,
            sizeBytes: sizeBytes,
            mimeType: "image/jpeg",
            fileExtension: "jpg"
        )
    }

    // MARK: - File layout

    private func makePhotoURL(captureSessionID: String, capturedAt: Date) throws -> URL {
        let base: URL
        do {
            base = try baseDirectoryProvider()
        } catch {
            throw PhotoCaptureError.fileSystemError(reason: "appSupport: \(error.localizedDescription)")
        }
        let dir = base
            .appendingPathComponent("Captures", isDirectory: true)
            .appendingPathComponent(captureSessionID, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var dirToFlag = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dirToFlag.setResourceValues(values)
        } catch {
            throw PhotoCaptureError.fileSystemError(reason: "mkdir: \(error.localizedDescription)")
        }
        let stamp = Self.filenameTimestamp(capturedAt)
        return dir.appendingPathComponent("photo-\(stamp).jpg", isDirectory: false)
    }

    private static func filenameTimestamp(_ date: Date) -> String {
        // Matches the audio recorder's ISO8601 format-options for
        // consistent filename shapes across artifact kinds.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        return formatter.string(from: date)
    }
}
