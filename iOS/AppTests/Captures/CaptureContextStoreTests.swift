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

    @Test("save of the same session upserts (replaces) its snapshot")
    func saveUpsertsSameSession() async throws {
        let (store, _) = Self.makeStore()
        try await store.save(Self.sampleContext(phase: .recording, pending: []))
        try await store.save(Self.sampleContext(phase: .finalizing, pending: ["u-9"]))
        let all = await store.loadAll()
        #expect(all.count == 1) // same captureSessionID → replaced, not appended
        let loaded = await store.load()
        #expect(loaded?.phase == .finalizing)
        #expect(loaded?.pendingUploadIDs == ["u-9"])
    }

    // MARK: - Multi-slot (June-2 morning/afternoon recovery)

    private static func context(
        id: String,
        startedAt: Date,
        phase: PersistedCaptureContext.Phase = .finalizing,
        pending: [String] = []
    ) -> PersistedCaptureContext {
        PersistedCaptureContext(
            captureSessionID: id,
            projectID: "proj-1",
            workspaceID: "ws-1",
            startedAt: startedAt,
            phase: phase,
            pendingUploadIDs: pending
        )
    }

    @Test("loadAll keeps every session; load() returns the most-recently-started")
    func multiSlotLoad() async throws {
        let (store, _) = Self.makeStore()
        let morning = Self.context(id: "cap-morning", startedAt: Date(timeIntervalSince1970: 1_000_000), pending: ["m1"])
        let afternoon = Self.context(id: "cap-afternoon", startedAt: Date(timeIntervalSince1970: 1_020_000), pending: ["a1"])
        try await store.save(morning)
        try await store.save(afternoon)

        let all = await store.loadAll()
        #expect(Set(all.map(\.captureSessionID)) == ["cap-morning", "cap-afternoon"])
        #expect(await store.load()?.captureSessionID == "cap-afternoon")
    }

    @Test("clear(captureSessionID:) removes only that session")
    func clearOneSession() async throws {
        let (store, _) = Self.makeStore()
        try await store.save(Self.context(id: "cap-morning", startedAt: Date(timeIntervalSince1970: 1_000_000)))
        try await store.save(Self.context(id: "cap-afternoon", startedAt: Date(timeIntervalSince1970: 1_020_000)))

        await store.clear(captureSessionID: "cap-afternoon")
        let remaining = await store.loadAll()
        #expect(remaining.map(\.captureSessionID) == ["cap-morning"])
    }

    @Test("clear(captureSessionID:) of the last session removes the file")
    func clearLastSessionRemovesFile() async throws {
        let (store, url) = Self.makeStore()
        try await store.save(Self.sampleContext()) // cap-1
        await store.clear(captureSessionID: "cap-1")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(await store.loadAll().isEmpty)
    }

    @Test("legacy single-object file migrates to the array shape transparently")
    func legacyMigration() async throws {
        let (store, url) = Self.makeStore()
        // Write the OLD single-object format directly to disk.
        let legacy = Self.sampleContext(phase: .finalizing, pending: ["u-legacy"]) // cap-1
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(legacy).write(to: url)

        // loadAll reads it as a one-element list (migration on read).
        let migrated = await store.loadAll()
        #expect(migrated.count == 1)
        #expect(migrated.first?.captureSessionID == "cap-1")
        #expect(migrated.first?.pendingUploadIDs == ["u-legacy"])

        // Saving a second session rewrites the file as an array; both survive.
        try await store.save(Self.context(id: "cap-2", startedAt: Date(timeIntervalSince1970: 1_715_780_000), pending: ["u-2"]))
        let after = await store.loadAll()
        #expect(Set(after.map(\.captureSessionID)) == ["cap-1", "cap-2"])
        let raw = try Data(contentsOf: url)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let asArray = try dec.decode([PersistedCaptureContext].self, from: raw)
        #expect(asArray.count == 2)
    }
}
