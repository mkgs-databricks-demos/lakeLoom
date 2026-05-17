import Foundation

/// Single-shot photo capture for the camera leg of a capture session.
///
/// Conceptually parallel to ``AudioRecorder`` but without the
/// start/stop bracketing — each ``capturePhoto(captureSessionID:)``
/// call produces exactly one finalized JPEG on disk and returns the
/// ``CapturedPhoto`` metadata the upload layer needs.
///
/// File layout matches the audio recorder's convention:
/// `<Application Support>/Captures/<captureSessionID>/photo-<ISO8601>.jpg`.
public protocol PhotoCapture: Sendable {

    /// Capture one JPEG to disk. The returned ``CapturedPhoto``'s
    /// `fileURL` is fully written by the time this call returns.
    ///
    /// Throws ``PhotoCaptureError`` for permission, hardware, or I/O
    /// failures. Callers in the capture flow surface these as
    /// `Retake` / `Open Settings` affordances per error case.
    func capturePhoto(captureSessionID: String) async throws -> CapturedPhoto
}

/// Finalized photo handed to the upload layer. Fields map 1:1 to
/// the upload-route metadata server-side per Genie's MIME allowlist
/// (`image/jpeg` is accepted; the server stores under
/// `/Volumes/.../<photos-volume>/{project_id}/{capture_session_id}/{uuidv7}.jpg`).
public struct CapturedPhoto: Sendable, Equatable, Hashable {
    public let captureSessionID: String
    public let fileURL: URL
    public let capturedAt: Date
    public let sizeBytes: Int64
    /// Always `"image/jpeg"` for v1. HEIC could be added later by
    /// extending the engine seam to negotiate format.
    public let mimeType: String
    /// Always `"jpg"`. Matches the file extension on `fileURL`.
    public let fileExtension: String

    public init(
        captureSessionID: String,
        fileURL: URL,
        capturedAt: Date,
        sizeBytes: Int64,
        mimeType: String,
        fileExtension: String
    ) {
        self.captureSessionID = captureSessionID
        self.fileURL = fileURL
        self.capturedAt = capturedAt
        self.sizeBytes = sizeBytes
        self.mimeType = mimeType
        self.fileExtension = fileExtension
    }
}

/// Typed errors. Mirrors the shape of ``AudioRecorderError`` so the
/// UI layer can pattern-match consistently across capture sources.
public enum PhotoCaptureError: Error, Sendable, Equatable {
    /// User denied camera access (first prompt or in Settings). Caller
    /// should route to a Settings deep-link.
    case permissionDenied

    /// No camera available, or `AVCaptureSession` can't be configured
    /// (e.g., the simulator has no virtual camera bound).
    case sessionConfigurationFailed(reason: String)

    /// `AVCapturePhotoOutput.capturePhoto(...)` failed or the delegate
    /// surfaced an error before the photo was finalized.
    case captureFailed(reason: String)

    /// The capture produced data but iOS handed back nil
    /// `fileDataRepresentation()`. Treated as a programmer/runtime
    /// error — extremely rare in practice.
    case noPhotoData

    /// Could not write the photo to disk.
    case fileSystemError(reason: String)
}
