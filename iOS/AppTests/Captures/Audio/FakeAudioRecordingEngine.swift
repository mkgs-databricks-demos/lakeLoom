import Foundation

@testable import LakeloomApp

/// Test seam over ``AudioRecordingEngine``. Lets tests script
/// permission, start failures, and stop durations deterministically
/// without touching CoreAudio.
actor FakeAudioRecordingEngine: AudioRecordingEngine {

    enum Step: Sendable, Equatable {
        case currentPermission
        case requestPermission
        case start(URL)
        case stop
        case cancel
    }

    var permissionState: Bool?
    var startThrows: Error?
    var stopThrows: Error?
    var stopDuration: Double = 1.234
    /// If set, ``start(writingTo:)`` writes this Data to the URL
    /// before returning — lets tests assert that downstream code
    /// finds a non-empty file size.
    var fakeFilePayload: Data?

    private(set) var calls: [Step] = []

    init(permission: Bool? = true) {
        self.permissionState = permission
    }

    func setPermission(_ value: Bool?) { permissionState = value }
    func setStartThrows(_ error: Error?) { startThrows = error }
    func setStopThrows(_ error: Error?) { stopThrows = error }
    func setStopDuration(_ value: Double) { stopDuration = value }
    func setFakeFilePayload(_ data: Data?) { fakeFilePayload = data }

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

    func start(writingTo url: URL) async throws {
        calls.append(.start(url))
        if let startThrows { throw startThrows }
        if let fakeFilePayload {
            try fakeFilePayload.write(to: url)
        }
    }

    func stop() async throws -> Double {
        calls.append(.stop)
        if let stopThrows { throw stopThrows }
        return stopDuration
    }

    func cancel() async {
        calls.append(.cancel)
    }
}
