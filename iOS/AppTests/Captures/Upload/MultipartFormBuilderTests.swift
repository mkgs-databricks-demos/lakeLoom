import Foundation
import Testing

@testable import LakeloomApp

@Suite("MultipartFormBuilder")
struct MultipartFormBuilderTests {

    @Test("emits boundary, file part with Content-Disposition + Content-Type, and closing marker")
    func filePartShape() {
        let boundary = "lakeloom.boundary.fixture"
        let body = MultipartFormBuilder.build(
            boundary: boundary,
            fileBytes: Data([0x01, 0x02, 0x03, 0x04]),
            filename: "audio.m4a",
            mimeType: "audio/mp4",
            clientTimestamp: nil,
            clientFilename: nil,
            sha256Hex: nil
        )
        // isoLatin1 maps any byte 1:1 to a code point, so the
        // assertion text still appears verbatim even when the file
        // bytes include non-ASCII values like 0xFF.
        let ascii = String(data: body, encoding: .isoLatin1) ?? ""
        #expect(ascii.contains("--lakeloom.boundary.fixture\r\n"))
        #expect(ascii.contains("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n"))
        #expect(ascii.contains("Content-Type: audio/mp4\r\n\r\n"))
        #expect(ascii.contains("--lakeloom.boundary.fixture--\r\n"))
    }

    @Test("emits client_ts as unix seconds string when provided")
    func clientTsField() {
        let boundary = "lakeloom.boundary.fixture"
        let timestamp = Date(timeIntervalSince1970: 1_747_152_120)
        let body = MultipartFormBuilder.build(
            boundary: boundary,
            fileBytes: Data([0xFF]),
            filename: "x.m4a",
            mimeType: "audio/mp4",
            clientTimestamp: timestamp,
            clientFilename: nil,
            sha256Hex: nil
        )
        // isoLatin1 maps any byte 1:1 to a code point, so the
        // assertion text still appears verbatim even when the file
        // bytes include non-ASCII values like 0xFF.
        let ascii = String(data: body, encoding: .isoLatin1) ?? ""
        #expect(ascii.contains("Content-Disposition: form-data; name=\"client_ts\"\r\n\r\n1747152120\r\n"))
    }

    @Test("emits sha256_hex + client_filename when provided")
    func optionalFields() {
        let boundary = "lakeloom.boundary.fixture"
        let body = MultipartFormBuilder.build(
            boundary: boundary,
            fileBytes: Data([0xFF]),
            filename: "audio.m4a",
            mimeType: "audio/mp4",
            clientTimestamp: nil,
            clientFilename: "original.m4a",
            sha256Hex: "deadbeef"
        )
        // isoLatin1 maps any byte 1:1 to a code point, so the
        // assertion text still appears verbatim even when the file
        // bytes include non-ASCII values like 0xFF.
        let ascii = String(data: body, encoding: .isoLatin1) ?? ""
        #expect(ascii.contains("Content-Disposition: form-data; name=\"client_filename\"\r\n\r\noriginal.m4a\r\n"))
        #expect(ascii.contains("Content-Disposition: form-data; name=\"sha256_hex\"\r\n\r\ndeadbeef\r\n"))
    }

    @Test("file bytes are preserved verbatim in the body")
    func fileBytesPreserved() {
        let bytes = Data((0..<256).map { UInt8($0) })
        let boundary = "lakeloom.boundary.fixture"
        let body = MultipartFormBuilder.build(
            boundary: boundary,
            fileBytes: bytes,
            filename: "x.bin",
            mimeType: "application/octet-stream",
            clientTimestamp: nil,
            clientFilename: nil,
            sha256Hex: nil
        )
        // Find the file bytes by locating the `Content-Type: ...\r\n\r\n` marker.
        let separator = Data("Content-Type: application/octet-stream\r\n\r\n".utf8)
        guard let range = body.range(of: separator) else {
            Issue.record("expected file-part separator in body")
            return
        }
        let suffix = body.subdata(in: range.upperBound..<body.count)
        let closing = Data("\r\n--lakeloom.boundary.fixture--\r\n".utf8)
        guard let closingRange = suffix.range(of: closing) else {
            Issue.record("expected closing boundary after file bytes")
            return
        }
        let payload = suffix.subdata(in: 0..<closingRange.lowerBound)
        #expect(payload == bytes)
    }

    @Test("contentTypeHeaderValue is multipart/form-data with the boundary")
    func contentTypeHeader() {
        #expect(
            MultipartFormBuilder.contentTypeHeaderValue(boundary: "abc-123")
                == "multipart/form-data; boundary=abc-123"
        )
    }
}
