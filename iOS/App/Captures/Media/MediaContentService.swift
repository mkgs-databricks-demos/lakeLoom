import Foundation
import UniformTypeIdentifiers

/// Downloads the bytes for an `app.uploads` row from Genie's media
/// proxy (`GET /api/media/:upload_id`, shipped in PR #61 with HTTP
/// Range support) and writes them to a local file so consumers like
/// `QLPreviewController` — which needs a real on-disk URL — can
/// preview them.
///
/// Stateless past the single `downloadMedia(...)` call. Re-downloads
/// don't dedupe across calls; the temp file is overwritten if the
/// caller asks for the same `uploadID` twice in a row.
public protocol MediaContentService: Sendable {

    /// Fetch the upload's bytes through the Layer-2-signed media
    /// proxy and write them to a temp file. Returns the local URL.
    ///
    /// `mimeType` + `suggestedFilename` are used to pick the file
    /// extension so the consumer (QuickLook, share sheet, etc.) can
    /// route the file to the right renderer.
    func downloadMedia(
        uploadID: String,
        workspaceID: String,
        mimeType: String,
        suggestedFilename: String?
    ) async throws -> URL
}

/// Live ``MediaContentService`` backed by ``LakeloomAppClient``.
/// Routes the GET through `requestRaw` so the Layer 2 headers
/// (`X-Lakeloom-Session-Token` + `X-Lakeloom-Timestamp` +
/// `X-Lakeloom-Signature`) are applied automatically — same path
/// every other authed iOS request takes since the PR #60 refactor.
public actor LiveMediaContentService: MediaContentService {

    private let lakeloomApp: any LakeloomAppClient
    private let logger: AppLogger

    public init(
        lakeloomApp: any LakeloomAppClient,
        logger: AppLogger = AppLogger(category: .capture)
    ) {
        self.lakeloomApp = lakeloomApp
        self.logger = logger
    }

    public func downloadMedia(
        uploadID: String,
        workspaceID: String,
        mimeType: String,
        suggestedFilename: String?
    ) async throws -> URL {
        await logger.debug(
            "media.download.attempt",
            metadata: [
                "upload_id": .uuidPrefix(uploadID),
                "mime_type": .string(mimeType)
            ]
        )
        let data = try await lakeloomApp.requestRaw(
            workspaceID: workspaceID,
            method: .get,
            path: "/api/media/\(uploadID)",
            body: nil,
            contentType: nil
        )

        let url = try Self.writeToTemp(
            data: data,
            mimeType: mimeType,
            suggestedFilename: suggestedFilename,
            uploadID: uploadID
        )
        await logger.info(
            "media.download.ok",
            metadata: [
                "upload_id": .uuidPrefix(uploadID),
                "bytes": .int(Int64(data.count)),
                "local_url": .string(url.lastPathComponent)
            ]
        )
        return url
    }

    // MARK: - File layout

    /// Temp directory where downloaded previews live. Distinct from
    /// `Application Support/Captures/` (which holds recordings
    /// awaiting upload) — preview files are ephemeral and can be
    /// purged whenever the OS reclaims temp space.
    private static func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lakeloom-media", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writeToTemp(
        data: Data,
        mimeType: String,
        suggestedFilename: String?,
        uploadID: String
    ) throws -> URL {
        let ext = preferredExtension(forMime: mimeType, fallbackFrom: suggestedFilename) ?? "bin"
        let stem = baseName(from: suggestedFilename) ?? "document-\(String(uploadID.prefix(8)))"
        let dir = try tempDirectory()
        let url = dir.appendingPathComponent("\(stem).\(ext)", isDirectory: false)
        // Overwrite if a previous download left the same path on disk.
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// MIME-type → filename extension. Falls back to the extension
    /// the server-supplied filename already carries (e.g., the
    /// server returns `mime_type=application/octet-stream` for an
    /// unknown encoding but `original_filename=session-plan.md`).
    private static func preferredExtension(
        forMime mime: String,
        fallbackFrom filename: String?
    ) -> String? {
        if let utType = UTType(mimeType: mime),
           let ext = utType.preferredFilenameExtension {
            return ext
        }
        if let filename {
            let pathExt = (filename as NSString).pathExtension
            if !pathExt.isEmpty { return pathExt }
        }
        return nil
    }

    private static func baseName(from filename: String?) -> String? {
        guard let filename, !filename.isEmpty else { return nil }
        let stem = (filename as NSString).deletingPathExtension
        return stem.isEmpty ? nil : stem
    }
}
