import Foundation
import Testing

@testable import LakeloomApp

@Suite("CaptureContextStore")
struct CaptureContextStoreTests {

    private static func makeStore() -> (CaptureContextStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lakeloom-ctx-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("active-capture.json", isDirectory: false)
        return (CaptureContextStore(fileURL: url), url)
    }

    private static func sampleContext(
        phase: PersistedCaptureContext.Phase = .recording,
        pending: [String] = []
    ) -> PersistedCaptureContext {
        PersistedCaptureContext(
            captureSessionID: "cap-1",
            projectID: "proj-1",
            workspaceID: "ws-1",
            startedAt: Date(timeIntervalSince1970: 1_715_770_800),
            phase: phase,
            pendingUploadIDs: pending
        )
    }

    @Test("load on a missing file returns nil")
    func loadMissing() async {
        let (store, _) = Self.makeStore()
        let result = await store.load()
        #expect(result == nil)
    }

    @Test("save then load round-trips the snapshot")
    func saveLoadRoundTrip() async throws {
        let (store, _) = Self.makeStore()
        let context = Self.sampleContext(phase: .finalizing, pending: ["u-1", "u-2"])
        try await store.save(context)

        let loaded = await store.load()
        #expect(loaded == context)
    }

    @Test("load on a corrupt file returns nil without throwing")
    func loadCorrupt() async throws {
        let (store, url) = Self.makeStore()
        try Data("not json".utf8).write(to: url)
        let result = await store.load()
        #expect(result == nil)
    }

    @Test("clear removes the snapshot file")
    func clearRemovesFile() async throws {
        let (store, url) = Self.makeStore()
        try await store.save(Self.sampleContext())
        #expect(FileManager.default.fileExists(atPath: url.path))
        await store.clear()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("clear on a missing file is a no-op")
    func clearWhenMissing() async {
        let (store, _) = Self.makeStore()
        await store.clear() // does not throw
        let result = await store.load()
        #expect(result == nil)
    }

    @Test("save overwrites a prior snapshot atomically")
    func saveOverwrites() async throws {
        let (store, _) = Self.makeStore()
        try await store.save(Self.sampleContext(phase: .recording, pending: []))
        try await store.save(Self.sampleContext(phase: .finalizing, pending: ["u-9"]))
        let loaded = await store.load()
        #expect(loaded?.phase == .finalizing)
        #expect(loaded?.pendingUploadIDs == ["u-9"])
    }
}
