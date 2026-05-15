import Foundation
import Testing

@testable import LakeloomApp

@Suite("LiveAudioRecorder — start / stop / cancel")
struct LiveAudioRecorderTests {

    private static let captureID = "cap-audio-001"
    private static let fixedStart = Date(timeIntervalSince1970: 1_715_770_800)
    private static let fixedEnd = Date(timeIntervalSince1970: 1_715_770_905)

    // MARK: Helpers

    /// Successive-tick clock for the recorder's `nowProvider`. Each
    /// call returns the previous value, then advances by `step`.
    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        private let step: TimeInterval
        init(start: Date, step: TimeInterval) {
            self.date = start
            self.step = step
        }
        func tick() -> Date {
            lock.lock(); defer { lock.unlock() }
            let now = date
            date = date.addingTimeInterval(step)
            return now
        }
    }

    /// Per-test sandbox directory standing in for `Application Support`.
    /// Created on construction; the recorder writes recordings under
    /// `<root>/Captures/<sessionID>/`.
    private static func makeSandboxRoot() -> URL {
        let unique = "lakeloom-audiotest-\(UUID().uuidString)"
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(unique, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func makeRecorder(
        engine: FakeAudioRecordingEngine = FakeAudioRecordingEngine(),
        now: Date = LiveAudioRecorderTests.fixedStart
    ) -> (LiveAudioRecorder, FakeAudioRecordingEngine, URL) {
        let clock = TestClock(start: now, step: 105)
        let root = makeSandboxRoot()
        let recorder = LiveAudioRecorder(
            engine: engine,
            baseDirectoryProvider: { root },
            nowProvider: { clock.tick() }
        )
        return (recorder, engine, root)
    }

    // MARK: start

    @Test("start happy path returns URL under Application Support/Captures/<id>/")
    func startHappyPath() async throws {
        let (recorder, engine, _) = Self.makeRecorder()
        let url = try await recorder.start(captureSessionID: Self.captureID)

        #expect(url.path.contains("/Captures/\(Self.captureID)/"))
        #expect(url.lastPathComponent.hasPrefix("audio-"))
        #expect(url.pathExtension == "m4a")

        // Directory exists on disk.
        let dir = url.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: dir.path))

        // Engine got requestPermission then start(writingTo:).
        let calls = await engine.calls
        #expect(calls.count == 2)
        #expect(calls.first == .requestPermission)
        if case .start(let writtenURL) = calls.last {
            #expect(writtenURL == url)
        } else {
            Issue.record("Expected .start call as second engine interaction")
        }

        let state = await recorder.state
        #expect(state == .recording(captureSessionID: Self.captureID, startedAt: Self.fixedStart))
    }

    @Test("start throws permissionDenied when engine reports denied")
    func startPermissionDenied() async throws {
        let engine = FakeAudioRecordingEngine(permission: false)
        let (recorder, _, _) = Self.makeRecorder(engine: engine)
        await #expect(throws: AudioRecorderError.permissionDenied) {
            _ = try await recorder.start(captureSessionID: Self.captureID)
        }
        let state = await recorder.state
        #expect(state == .idle)
    }

    @Test("start throws engineFailure when engine.start throws")
    func startEngineFailure() async throws {
        let engine = FakeAudioRecordingEngine()
        await engine.setStartThrows(AudioRecorderError.engineFailure(reason: "boom"))
        let (recorder, _, _) = Self.makeRecorder(engine: engine)
        await #expect(throws: AudioRecorderError.engineFailure(reason: "boom")) {
            _ = try await recorder.start(captureSessionID: Self.captureID)
        }
        let state = await recorder.state
        #expect(state == .idle)
    }

    @Test("start throws alreadyRecording on second invocation")
    func startAlreadyRecording() async throws {
        let (recorder, _, _) = Self.makeRecorder()
        _ = try await recorder.start(captureSessionID: Self.captureID)
        await #expect(throws: AudioRecorderError.alreadyRecording) {
            _ = try await recorder.start(captureSessionID: "another")
        }
    }

    // MARK: stop

    @Test("stop returns AudioRecording with duration + size + mime")
    func stopHappyPath() async throws {
        let engine = FakeAudioRecordingEngine()
        let payload = Data(repeating: 0xAB, count: 1024)
        await engine.setFakeFilePayload(payload)
        await engine.setStopDuration(7.5)
        let (recorder, _, _) = Self.makeRecorder(engine: engine)

        _ = try await recorder.start(captureSessionID: Self.captureID)
        let result = try await recorder.stop()

        #expect(result.captureSessionID == Self.captureID)
        #expect(result.durationSeconds == 7.5)
        #expect(result.sizeBytes == 1024)
        #expect(result.mimeType == "audio/mp4")
        #expect(result.fileExtension == "m4a")
        #expect(result.startedAt == Self.fixedStart)
        // endedAt comes from second nowProvider() call → +105s
        #expect(result.endedAt == Self.fixedStart.addingTimeInterval(105))

        let state = await recorder.state
        #expect(state == .idle)
    }

    @Test("stop throws notRecording when idle")
    func stopWhileIdle() async throws {
        let (recorder, _, _) = Self.makeRecorder()
        await #expect(throws: AudioRecorderError.notRecording) {
            _ = try await recorder.stop()
        }
    }

    @Test("stop clears state even when engine throws")
    func stopEngineFailure() async throws {
        let engine = FakeAudioRecordingEngine()
        let (recorder, _, _) = Self.makeRecorder(engine: engine)
        _ = try await recorder.start(captureSessionID: Self.captureID)
        await engine.setStopThrows(AudioRecorderError.engineFailure(reason: "stop boom"))

        await #expect(throws: AudioRecorderError.engineFailure(reason: "stop boom")) {
            _ = try await recorder.stop()
        }
        let state = await recorder.state
        #expect(state == .idle)
    }

    // MARK: cancel

    @Test("cancel removes file and resets state")
    func cancelHappyPath() async throws {
        let engine = FakeAudioRecordingEngine()
        await engine.setFakeFilePayload(Data([0x01, 0x02, 0x03]))
        let (recorder, _, _) = Self.makeRecorder(engine: engine)

        let url = try await recorder.start(captureSessionID: Self.captureID)
        #expect(FileManager.default.fileExists(atPath: url.path))

        await recorder.cancel()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let state = await recorder.state
        #expect(state == .idle)

        let calls = await engine.calls
        #expect(calls.contains(.cancel))
    }

    @Test("cancel is a no-op when idle")
    func cancelWhileIdle() async throws {
        let engine = FakeAudioRecordingEngine()
        let (recorder, _, _) = Self.makeRecorder(engine: engine)
        await recorder.cancel()
        let calls = await engine.calls
        #expect(calls.isEmpty)
    }
}
