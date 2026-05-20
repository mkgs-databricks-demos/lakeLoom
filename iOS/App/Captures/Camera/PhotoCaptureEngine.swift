@preconcurrency import AVFoundation
import Foundation
import UIKit

/// Testable seam over `AVCaptureSession` + `AVCapturePhotoOutput` +
/// `AVCaptureDevice.requestAccess`. Lets unit tests script
/// permission, hardware failures, and the bytes a capture would
/// produce without spinning up real camera hardware.
protocol PhotoCaptureEngine: Sendable {

    /// Current camera permission as iOS reports it. `nil` means the
    /// user has not been asked yet.
    func currentPermission() async -> Bool?

    /// Prompt for camera access if undetermined; otherwise return
    /// the current state.
    func requestPermission() async -> Bool

    /// Capture one JPEG and return the bytes. The engine handles
    /// `AVCaptureSession` setup + tear-down internally so callers
    /// don't have to manage the lifecycle.
    func captureJPEG() async throws -> Data
}

/// Production engine — wraps `AVCaptureSession` configured for a
/// single photo capture from the back camera, JPEG output.
///
/// The session is started fresh for each `captureJPEG()` call and
/// torn down after. This trades latency (~200 ms warm-up per
/// capture) for state simplicity — the engine never holds open
/// camera hardware between captures. A future optimization could
/// keep the session running across calls if the demo UI demands
/// fast shutter cadence.
actor LivePhotoCaptureEngine: PhotoCaptureEngine {

    init() {}

    func currentPermission() async -> Bool? {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:        return true
        case .denied, .restricted: return false
        case .notDetermined:     return nil
        @unknown default:        return nil
        }
    }

    func requestPermission() async -> Bool {
        if let known = await currentPermission() { return known }
        return await AVCaptureDevice.requestAccess(for: .video)
    }

    func captureJPEG() async throws -> Data {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
        else {
            throw PhotoCaptureError.sessionConfigurationFailed(reason: "no camera device")
        }

        let session = AVCaptureSession()
        session.sessionPreset = .photo

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw PhotoCaptureError.sessionConfigurationFailed(reason: "device input: \(error.localizedDescription)")
        }
        guard session.canAddInput(input) else {
            throw PhotoCaptureError.sessionConfigurationFailed(reason: "session.canAddInput false")
        }
        session.addInput(input)

        let output = AVCapturePhotoOutput()
        guard session.canAddOutput(output) else {
            throw PhotoCaptureError.sessionConfigurationFailed(reason: "session.canAddOutput false")
        }
        session.addOutput(output)

        // Start the session off-main; AVCaptureSession.startRunning
        // blocks until the camera is warm.
        await Task.detached { session.startRunning() }.value
        defer { Task.detached { session.stopRunning() } }

        let settings = AVCapturePhotoSettings(format: [
            AVVideoCodecKey: AVVideoCodecType.jpeg
        ])
        // Front-facing flash and high-resolution capture stay at
        // platform defaults — we want a representative photo, not a
        // tuned one.

        let proxy = PhotoCaptureProxy()
        // The delegate is held weakly by AVCapturePhotoOutput; the
        // proxy must outlive the delegate dispatch. Keep a strong
        // local reference for the await.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            proxy.onFinish = { result in
                switch result {
                case .success(let data): continuation.resume(returning: data)
                case .failure(let err):  continuation.resume(throwing: err)
                }
            }
            output.capturePhoto(with: settings, delegate: proxy)
        }
    }
}

/// Bridges `AVCapturePhotoCaptureDelegate` (Obj-C) into Swift
/// concurrency. Single-use: one capture per proxy, then discarded.
private final class PhotoCaptureProxy: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {

    var onFinish: ((Result<Data, Error>) -> Void)?

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            onFinish?(.failure(PhotoCaptureError.captureFailed(reason: error.localizedDescription)))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            onFinish?(.failure(PhotoCaptureError.noPhotoData))
            return
        }
        onFinish?(.success(data))
    }
}
