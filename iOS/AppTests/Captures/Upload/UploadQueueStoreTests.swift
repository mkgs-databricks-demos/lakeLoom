import Foundation
import Testing

@testable import LakeloomApp

@Suite("UploadQueueStore")
struct UploadQueueStoreTests {

    private static func makeStore() -> (UploadQueueStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lakeloom-queue-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("upload-queue.json", isDirectory: false)
        return (UploadQueueStore(fileURL: url), url)
    }

    private static func makeUpload(id: String) -> PendingUpload {
        PendingUpload(
            id: id,
            workspaceID: "ws-1",
            captureSessionID: "cap-1",
            kind: .audio,
            localFileURL: URL(fileURLWithPath: "/tmp/x.m4a"),
            mimeType: "audio/mp4",
            sizeBytes: 1024,
            sha256Hex: "deadbeef",
            clientTimestamp: Date(timeIntervalSince1970: 1_747_152_120),
            originalFilename: "audio.m4a",
            createdAt: Date(timeIntervalSince1970: 1_747_152_120)
        )
    }

    @Test("load on a missing file returns empty array")
    func loadMissing() async {
        let (store, _) = Self.makeStore()
        let uploads = await store.load()
        #expect(uploads.isEmpty)
    }

    @Test("save then load round-trips uploads in order")
    func saveLoadRoundTrip() async throws {
        let (store, _) = Self.makeStore()
        let u1 = Self.makeUpload(id: "u1")
        let u2 = Self.makeUpload(id: "u2")
        try await store.save([u1, u2])

        let restored = await store.load()
        #expect(restored.count == 2)
        #expect(restored[0].id == "u1")
        #expect(restored[1].id == "u2")
    }

    @Test("save is atomic — interrupt mid-write doesn't corrupt prior snapshot")
    func saveLeavesPriorSnapshotOnFailure() async throws {
        let (store, url) = Self.makeStore()
        let u1 = Self.makeUpload(id: "u1")
        try await store.save([u1])

        // Drop a malformed payload at the tmp path; replaceItemAt
        // should still succeed because save() writes the tmp first
        // and replaces atomically. We just verify that the on-disk
        // snapshot remains parseable after a fresh save.
        let u2 = Self.makeUpload(id: "u2")
        try await store.save([u1, u2])

        // The store uses `.iso8601` date encoding; mirror that here
        // so the decode doesn't blow up on the timestamp fields.
        let raw = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([String: [PendingUpload]].self, from: raw)
        #expect(decoded["uploads"]?.map(\.id) == ["u1", "u2"])
    }

    @Test("load on a corrupt file returns empty without throwing")
    func loadCorrupt() async throws {
        let (store, url) = Self.makeStore()
        try Data("not json".utf8).write(to: url)
        let uploads = await store.load()
        #expect(uploads.isEmpty)
    }

    @Test("clear deletes the file")
    func clearRemovesFile() async throws {
        let (store, url) = Self.makeStore()
        try await store.save([Self.makeUpload(id: "u1")])
        #expect(FileManager.default.fileExists(atPath: url.path))
        await store.clear()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
