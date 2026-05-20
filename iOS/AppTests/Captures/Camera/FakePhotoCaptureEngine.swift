import Foundation

@testable import LakeloomApp

/// Scriptable ``PhotoCaptureEngine`` for ``LivePhotoCapture`` tests.
/// Tracks permission probes + capture calls and lets tests stub the
/// permission state and the bytes a capture would produce without
/// touching AVCaptureSession.
actor FakePhotoCaptureEngine: PhotoCaptureEngine {

    enum Call: Sendable, Equatable {
        case currentPermission
        case requestPermission
        case captureJPEG
    }

    private(set) var calls: [Call] = []

    var permissionState: Bool?
    var captureError: Error?
    var jpegPayload: Data = Data(repeating: 0xFF, count: 32)

    init(permission: Bool? = true) {
        self.permissionState = permission
    }

    func setPermission(_ value: Bool?) { permissionState = value }
    func setCaptureError(_ error: Error?) { captureError = error }
    func setJPEGPayload(_ data: Data) { jpegPayload = data }

    func currentPermission() async -> Bool? {
        calls.append(.currentPermission)
        return permissionState
    }

    func requestPermission() async -> Bool {
        calls.append(.requestPermission)
        if let granted = permissionState { return granted }
        permissionState = true
        return true
    }

    func captureJPEG() async throws -> Data {
        calls.append(.captureJPEG)
        if let captureError { throw captureError }
        return jpegPayload
    }
}
