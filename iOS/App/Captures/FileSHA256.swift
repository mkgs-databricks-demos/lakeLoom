import CryptoKit
import Foundation

/// Streaming SHA-256 over a file URL. Avoids loading the whole file
/// into memory at once — important once captures grow past audio
/// into screen recordings and photo bursts. CryptoKit's `update`
/// API accepts repeated chunks.
enum FileSHA256 {

    /// Default chunk size — 1 MiB. Big enough that the per-read
    /// overhead is negligible, small enough that we never hold more
    /// than a buffer's worth of bytes in memory.
    static let defaultChunkSize = 1 * 1024 * 1024

    /// Lowercase hex SHA-256 of the file at `url`.
    ///
    /// Throws if the file is missing or unreadable. The caller maps
    /// to whatever typed error fits its surface — `CaptureService`
    /// wraps as ``CaptureServiceError/hashingFailed(reason:)``.
    static func hex(of url: URL, chunkSize: Int = defaultChunkSize) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = try? handle.read(upToCount: chunkSize)
            guard let chunk, !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
