import Foundation
import Testing

@testable import LakeloomApp

@Suite("LivePhotoCapture")
struct LivePhotoCaptureTests {

    private static let captureID = "cap-photo-001"
    private static let fixedNow = Date(timeIntervalSince1970: 1_715_770_800)

    /// Per-test sandbox standing in for `Application Support`.
    private static func makeSandboxRoot() -> URL {
        let unique = "lakeloom-phototest-\(UUID().uuidString)"
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(unique, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func makePhotoCapture(
        engine: FakePhotoCaptureEngine = FakePhotoCaptureEngine()
    ) -> (LivePhotoCapture, FakePhotoCaptureEngine, URL) {
        let root = makeSandboxRoot()
        let capture = LivePhotoCapture(
            engine: engine,
            baseDirectoryProvider: { root },
            nowProvider: { LivePhotoCaptureTests.fixedNow }
        )
        return (capture, engine, root)
    }

    // MARK: Happy path

    @Test("capturePhoto writes JPEG to disk and returns metadata")
    func captureHappyPath() async throws {
        let payload = Data((0..<512).map { UInt8($0 & 0xFF) })
        let engine = FakePhotoCaptureEngine()
        await engine.setJPEGPayload(payload)
        let (capture, _, _) = Self.makePhotoCapture(engine: engine)

        let photo = try await capture.capturePhoto(captureSessionID: Self.captureID)

        #expect(photo.captureSessionID == Self.captureID)
        #expect(photo.mimeType == "image/jpeg")
        #expect(photo.fileExtension == "jpg")
        #expect(photo.sizeBytes == 512)
        #expect(photo.fileURL.lastPathComponent.hasPrefix("photo-"))
        #expect(photo.fileURL.pathExtension == "jpg")
        #expect(photo.fileURL.path.contains("/Captures/\(Self.captureID)/"))

        // File on disk matches the payload byte-for-byte.
        let written = try Data(contentsOf: photo.fileURL)
        #expect(written == payload)
    }

    // MARK: Permission

    @Test("capturePhoto throws permissionDenied when engine reports denied")
    func capturePermissionDenied() async throws {
        let engine = FakePhotoCaptureEngine(permission: false)
        let (capture, _, _) = Self.makePhotoCapture(engine: engine)

        await #expect(throws: PhotoCaptureError.permissionDenied) {
            _ = try await capture.capturePhoto(captureSessionID: Self.captureID)
        }
    }

    @Test("requestPermission only invoked once per capture")
    func capturePermissionRequestedOnce() async throws {
        let engine = FakePhotoCaptureEngine()
        let (capture, _, _) = Self.makePhotoCapture(engine: engine)

        _ = try await capture.capturePhoto(captureSessionID: Self.captureID)

        let calls = await engine.calls
        #expect(calls.filter { $0 == .requestPermission }.count == 1)
        #expect(calls.contains(.captureJPEG))
    }

    // MARK: Engine failure

    @Test("capturePhoto surfaces engine errors as captureFailed")
    func captureEngineFailure() async throws {
        let engine = FakePhotoCaptureEngine()
        await engine.setCaptureError(PhotoCaptureError.captureFailed(reason: "boom"))
        let (capture, _, _) = Self.makePhotoCapture(engine: engine)

        await #expect(throws: PhotoCaptureError.captureFailed(reason: "boom")) {
            _ = try await capture.capturePhoto(captureSessionID: Self.captureID)
        }
    }

    @Test("capturePhoto wraps unknown engine errors as captureFailed")
    func captureWrapsUnknownErrors() async throws {
        struct WeirdError: Error {}
        let engine = FakePhotoCaptureEngine()
        await engine.setCaptureError(WeirdError())
        let (capture, _, _) = Self.makePhotoCapture(engine: engine)

        do {
            _ = try await capture.capturePhoto(captureSessionID: Self.captureID)
            Issue.record("expected throw")
        } catch let error as PhotoCaptureError {
            if case .captureFailed = error { /* ok */ } else {
                Issue.record("expected .captureFailed, got \(error)")
            }
        } catch {
            Issue.record("unexpected non-PhotoCaptureError: \(error)")
        }
    }

    // MARK: File layout

    @Test("directory is created and isExcludedFromBackup is set")
    func captureCreatesDirectory() async throws {
        let engine = FakePhotoCaptureEngine()
        let (capture, _, root) = Self.makePhotoCapture(engine: engine)

        let photo = try await capture.capturePhoto(captureSessionID: Self.captureID)
        let dir = photo.fileURL.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(dir.path.contains(root.path))
    }
}
