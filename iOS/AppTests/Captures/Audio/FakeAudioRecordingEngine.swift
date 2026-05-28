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
    /// Override the URL returned in the `EngineStopArtifact`. Defaults
    /// to the URL passed into `start(writingTo:)` so the m4a-happy-
    /// path behavior matches production. Set explicitly to simulate
    /// a CAF fallback (engine returning a different file than asked).
    var stopArtifactURL: URL?
    var stopArtifactMimeType: String = "audio/mp4"
    var stopArtifactExtension: String = "m4a"
    /// If set, ``start(writingTo:)`` writes this Data to the URL
    /// before returning — lets tests assert that downstream code
    /// finds a non-empty file size.
    var fakeFilePayload: Data?

    private(set) var calls: [Step] = []
    private var lastStartURL: URL?

    init(permission: Bool? = true) {
        self.permissionState = permission
    }

    func setPermission(_ value: Bool?) { permissionState = value }
    func setStartThrows(_ error: Error?) { startThrows = error }
    func setStopThrows(_ error: Error?) { stopThrows = error }
    func setStopDuration(_ value: Double) { stopDuration = value }
    func setFakeFilePayload(_ data: Data?) { fakeFilePayload = data }
    func setStopArtifact(url: URL?, mimeType: String, fileExtension: String) {
        stopArtifactURL = url
        stopArtifactMimeType = mimeType
        stopArtifactExtension = fileExtension
    }

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
        lastStartURL = url
        if let startThrows { throw startThrows }
        if let fakeFilePayload {
            try fakeFilePayload.write(to: url)
        }
    }

    func stop() async throws -> EngineStopArtifact {
        calls.append(.stop)
        if let stopThrows { throw stopThrows }
        return EngineStopArtifact(
            fileURL: stopArtifactURL ?? lastStartURL ?? URL(fileURLWithPath: "/dev/null"),
            duration: stopDuration,
            mimeType: stopArtifactMimeType,
            fileExtension: stopArtifactExtension
        )
    }

    func cancel() async {
        calls.append(.cancel)
    }
}
