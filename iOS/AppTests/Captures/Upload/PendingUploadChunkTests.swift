import Foundation
import Testing

@testable import LakeloomApp

@Suite("PendingUpload — chunk fields (PR A piece 4 / migration 021)")
struct PendingUploadChunkTests {

    private static func makeUpload(
        chunkIndex: Int = 0,
        isFinalChunk: Bool = true,
        totalChunks: Int? = nil
    ) -> PendingUpload {
        PendingUpload(
            id: "u-1",
            workspaceID: "ws-1",
            captureSessionID: "cap-1",
            kind: .audio,
            localFileURL: URL(fileURLWithPath: "/tmp/x.m4a"),
            mimeType: "audio/mp4",
            sizeBytes: 1,
            sha256Hex: "deadbeef",
            clientTimestamp: Date(timeIntervalSince1970: 1_747_152_120),
            originalFilename: "x.m4a",
            deviceID: "dev-1",
            chunkIndex: chunkIndex,
            isFinalChunk: isFinalChunk,
            totalChunks: totalChunks,
            createdAt: Date(timeIntervalSince1970: 1_747_152_120)
        )
    }

    @Test("defaults are single-chunk semantics: index 0, final true, totalChunks nil")
    func defaults() {
        let upload = PendingUpload(
            id: "u-1",
            workspaceID: "ws-1",
            captureSessionID: "cap-1",
            kind: .audio,
            localFileURL: URL(fileURLWithPath: "/tmp/x.m4a"),
            mimeType: "audio/mp4",
            sizeBytes: 1,
            sha256Hex: "deadbeef",
            clientTimestamp: Date(),
            originalFilename: "x.m4a",
            createdAt: Date()
        )
        #expect(upload.chunkIndex == 0)
        #expect(upload.isFinalChunk == true)
        #expect(upload.totalChunks == nil)
    }

    @Test("chunk fields round-trip through Codable")
    func codableRoundTrip() throws {
        let upload = Self.makeUpload(chunkIndex: 3, isFinalChunk: false, totalChunks: 5)
        let data = try JSONEncoder().encode(upload)
        let decoded = try JSONDecoder().decode(PendingUpload.self, from: data)
        #expect(decoded.chunkIndex == 3)
        #expect(decoded.isFinalChunk == false)
        #expect(decoded.totalChunks == 5)
        #expect(decoded == upload)
    }

    /// The whole branch exists to prevent losing queued audio across
    /// app termination. A queue file written by a build that pre-dates
    /// the chunk fields MUST still rehydrate after the user updates the
    /// app — missing chunk keys fill single-chunk defaults rather than
    /// throwing.
    @Test("legacy queue JSON without chunk keys decodes with defaults")
    func legacyDecodeCompat() throws {
        // Derive a "pre-chunk-fields" blob from a real encode, then
        // strip the three chunk keys — guarantees the rest of the wire
        // shape matches exactly what an older build wrote, isolating the
        // test to chunk-key absence rather than hand-guessing the
        // State / Date encoding.
        let upload = Self.makeUpload(chunkIndex: 7, isFinalChunk: false, totalChunks: 9)
        let data = try JSONEncoder().encode(upload)
        var dict = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        dict.removeValue(forKey: "chunkIndex")
        dict.removeValue(forKey: "isFinalChunk")
        dict.removeValue(forKey: "totalChunks")
        // Sanity: the keys really are gone before we decode.
        #expect(dict["chunkIndex"] == nil)
        #expect(dict["isFinalChunk"] == nil)
        #expect(dict["totalChunks"] == nil)

        let legacyData = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(PendingUpload.self, from: legacyData)
        #expect(decoded.id == upload.id)
        #expect(decoded.chunkIndex == 0)
        #expect(decoded.isFinalChunk == true)
        #expect(decoded.totalChunks == nil)
    }

    @Test("chunkIndex(fromFilename:) parses -chunkN suffix")
    func parseChunkSuffix() {
        #expect(LiveCaptureService.chunkIndex(fromFilename: "audio-20260515T120000Z-chunk0.m4a") == 0)
        #expect(LiveCaptureService.chunkIndex(fromFilename: "audio-20260515T120000Z-chunk1.m4a") == 1)
        #expect(LiveCaptureService.chunkIndex(fromFilename: "audio-20260515T120000Z-chunk12.caf") == 12)
    }

    @Test("chunkIndex(fromFilename:) returns 0 for legacy single-chunk names")
    func parseLegacyName() {
        #expect(LiveCaptureService.chunkIndex(fromFilename: "audio-20260515T120000Z.m4a") == 0)
        #expect(LiveCaptureService.chunkIndex(fromFilename: "audio.caf") == 0)
        #expect(LiveCaptureService.chunkIndex(fromFilename: "weird-name-no-index.m4a") == 0)
    }

    // MARK: - DedupSignal (Genie's chunk-dedup response flag, option b)

    @Test("DedupSignal decodes _dedup + dedup_sha_mismatch when present")
    func dedupSignalPresent() throws {
        let json = Data(#"{"id":"x","_dedup":true,"dedup_sha_mismatch":true}"#.utf8)
        let signal = try JSONDecoder().decode(DedupSignal.self, from: json)
        #expect(signal.isDedup)
        #expect(signal.shaMismatch)
    }

    @Test("DedupSignal: clean idempotent retry has mismatch false")
    func dedupSignalCleanRetry() throws {
        let json = Data(#"{"id":"x","_dedup":true,"dedup_sha_mismatch":false}"#.utf8)
        let signal = try JSONDecoder().decode(DedupSignal.self, from: json)
        #expect(signal.isDedup)
        #expect(!signal.shaMismatch)
    }

    @Test("DedupSignal defaults both flags false on a normal (non-dedup) response")
    func dedupSignalAbsent() throws {
        // A first-insert response carries neither flag.
        let json = Data(#"{"id":"x","kind":"audio","size_bytes":1024}"#.utf8)
        let signal = try JSONDecoder().decode(DedupSignal.self, from: json)
        #expect(!signal.isDedup)
        #expect(!signal.shaMismatch)
    }
}
