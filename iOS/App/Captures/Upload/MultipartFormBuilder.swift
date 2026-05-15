import Foundation

/// Builds `multipart/form-data` bodies matching the wire-format
/// contract in Genie's `2026-05-13_upload-traceability-response.md`:
///
/// - `file`            — required, raw bytes
/// - `client_ts`       — unix seconds string (recommended)
/// - `client_filename` — original filename (optional)
/// - `sha256_hex`      — lowercase hex digest, verified server-side
///                       (optional but cheap to provide)
///
/// Server-side parses the body with `busboy`. Field order doesn't
/// matter; the builder emits the metadata fields first so the file
/// part lands last (cosmetic — readability when tcpdump'ing).
enum MultipartFormBuilder {

    /// Each multipart body needs a unique boundary marker; this
    /// reads back from the call site so callers can put the same
    /// value into the `Content-Type` header.
    static func makeBoundary() -> String {
        "lakeloom.\(UUID().uuidString)"
    }

    /// Build the body bytes for a single-file upload.
    ///
    /// - Parameters:
    ///   - boundary: marker returned by ``makeBoundary()``.
    ///   - fileURL:  path to read file bytes from. Failure to read
    ///               throws — callers wrap into their own typed
    ///               error.
    ///   - fileFieldName: form field name. Always `"file"` for the
    ///               current upload routes.
    ///   - filename: filename header value for the file part. Server
    ///               stores this on `app.uploads.original_filename`.
    ///   - mimeType: Content-Type for the file part.
    ///   - clientTimestamp: serialized as unix seconds string in the
    ///               `client_ts` field.
    ///   - clientFilename: optional `client_filename` field (often
    ///               the same as `filename`; sent so the server can
    ///               distinguish the *value* from the *Content-
    ///               Disposition header*).
    ///   - sha256Hex: optional `sha256_hex` field.
    static func build(
        boundary: String,
        fileURL: URL,
        fileFieldName: String = "file",
        filename: String,
        mimeType: String,
        clientTimestamp: Date?,
        clientFilename: String?,
        sha256Hex: String?
    ) throws -> Data {
        let fileData = try Data(contentsOf: fileURL)
        return build(
            boundary: boundary,
            fileBytes: fileData,
            fileFieldName: fileFieldName,
            filename: filename,
            mimeType: mimeType,
            clientTimestamp: clientTimestamp,
            clientFilename: clientFilename,
            sha256Hex: sha256Hex
        )
    }

    /// In-memory variant — tests use this directly so they don't need
    /// to write fixture files to disk.
    static func build(
        boundary: String,
        fileBytes: Data,
        fileFieldName: String = "file",
        filename: String,
        mimeType: String,
        clientTimestamp: Date?,
        clientFilename: String?,
        sha256Hex: String?
    ) -> Data {
        var body = Data()

        if let clientTimestamp {
            body.append(boundaryLine(boundary))
            body.append(fieldDisposition("client_ts"))
            body.append(string("\(Int(clientTimestamp.timeIntervalSince1970))"))
            body.append(crlf)
        }
        if let clientFilename {
            body.append(boundaryLine(boundary))
            body.append(fieldDisposition("client_filename"))
            body.append(string(clientFilename))
            body.append(crlf)
        }
        if let sha256Hex {
            body.append(boundaryLine(boundary))
            body.append(fieldDisposition("sha256_hex"))
            body.append(string(sha256Hex))
            body.append(crlf)
        }

        body.append(boundaryLine(boundary))
        body.append(string("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(filename)\"\r\n"))
        body.append(string("Content-Type: \(mimeType)\r\n\r\n"))
        body.append(fileBytes)
        body.append(crlf)

        body.append(closingBoundary(boundary))
        return body
    }

    /// Compose the `Content-Type` header value for a given boundary.
    static func contentTypeHeaderValue(boundary: String) -> String {
        "multipart/form-data; boundary=\(boundary)"
    }

    // MARK: - Private

    private static let crlf = Data("\r\n".utf8)

    private static func string(_ value: String) -> Data {
        Data(value.utf8)
    }

    private static func boundaryLine(_ boundary: String) -> Data {
        Data("--\(boundary)\r\n".utf8)
    }

    private static func closingBoundary(_ boundary: String) -> Data {
        Data("--\(boundary)--\r\n".utf8)
    }

    private static func fieldDisposition(_ name: String) -> Data {
        Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8)
    }
}
