import Foundation
import Testing

@testable import LakeloomApp

@Suite("CaptureUpload — lenient decode + new fields")
struct CaptureUploadDecodeTests {

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @Test("decode happy path — size_bytes as JSON number")
    func decodeSizeBytesAsNumber() throws {
        let json = """
        {
          "id": "019e45e4-58ee-7749-94f6-0d254adf619f",
          "kind": "audio",
          "volume_path": "/Volumes/c/s/session_audio/p/c/u.m4a",
          "mime_type": "audio/mp4",
          "size_bytes": 134931,
          "sha256_hex": "deadbeef",
          "original_filename": "audio-x.m4a",
          "client_ts": "2026-05-20T15:48:48.000Z",
          "client_ts_source": "client",
          "uploaded_at": "2026-05-20T15:48:50.000Z"
        }
        """
        let upload = try Self.makeDecoder().decode(CaptureUpload.self, from: Data(json.utf8))
        #expect(upload.sizeBytes == 134931)
        #expect(upload.clientTsSource == .client)
    }

    @Test("decode lenient — size_bytes as JSON string (Lakebase bigint serialization)")
    func decodeSizeBytesAsString() throws {
        let json = """
        {
          "id": "u-1",
          "kind": "audio",
          "volume_path": "/v/p",
          "mime_type": "audio/mp4",
          "size_bytes": "134931",
          "sha256_hex": "deadbeef",
          "original_filename": null,
          "client_ts": null,
          "client_ts_source": null,
          "uploaded_at": "2026-05-20T15:48:50.000Z"
        }
        """
        let upload = try Self.makeDecoder().decode(CaptureUpload.self, from: Data(json.utf8))
        #expect(upload.sizeBytes == 134931)
        #expect(upload.clientTs == nil)
        #expect(upload.clientTsSource == nil)
    }

    @Test("decode rejects size_bytes that's neither a number nor a numeric string")
    func decodeSizeBytesRejectsGarbage() {
        let json = """
        {
          "id": "u-1",
          "kind": "audio",
          "volume_path": "/v/p",
          "mime_type": "audio/mp4",
          "size_bytes": "not a number",
          "sha256_hex": "deadbeef",
          "uploaded_at": "2026-05-20T15:48:50.000Z"
        }
        """
        do {
            _ = try Self.makeDecoder().decode(CaptureUpload.self, from: Data(json.utf8))
            Issue.record("expected DecodingError.typeMismatch")
        } catch {
            // ok — any DecodingError is fine here, we just shouldn't crash.
        }
    }

    @Test("clientTsSource decodes 'server' fallback case")
    func decodeClientTsSourceServer() throws {
        let json = """
        {
          "id": "u-1",
          "kind": "audio",
          "volume_path": "/v/p",
          "mime_type": "audio/mp4",
          "size_bytes": 1,
          "sha256_hex": "deadbeef",
          "client_ts_source": "server",
          "uploaded_at": "2026-05-20T15:48:50.000Z"
        }
        """
        let upload = try Self.makeDecoder().decode(CaptureUpload.self, from: Data(json.utf8))
        #expect(upload.clientTsSource == .server)
    }

    @Test("encode round-trip preserves all fields")
    func encodeRoundTrip() throws {
        let original = CaptureUpload(
            id: "u-1",
            kind: .audio,
            volumePath: "/Volumes/c/s/x.m4a",
            mimeType: "audio/mp4",
            sizeBytes: 134931,
            sha256Hex: "deadbeef",
            originalFilename: "audio-x.m4a",
            clientTs: Date(timeIntervalSince1970: 1_779_292_127),
            clientTsSource: .client,
            uploadedAt: Date(timeIntervalSince1970: 1_779_292_149)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let roundTripped = try Self.makeDecoder().decode(CaptureUpload.self, from: data)
        #expect(roundTripped == original)
    }
}
