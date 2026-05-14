import CryptoKit
import Foundation

/// Composes the per-request signature headers iOS attaches to every
/// authenticated request to the lakeLoom Databricks App backend.
///
/// Canonical message form (newline-joined exactly):
/// ```
/// <HTTP method, uppercase>
/// <URL path including query string>
/// <unix timestamp seconds>
/// <lowercase hex sha256 of request body, or "" if no body>
/// ```
///
/// See `architecture/hi_genie/qr-pair-auth-model.md` for the protocol
/// spec and Databricks App–side verification details.
public struct RequestSigner: Sendable {

    private let keyStore: any DeviceKeyStoring
    private let nowProvider: @Sendable () -> Date

    public init(
        keyStore: any DeviceKeyStoring,
        nowProvider: @Sendable @escaping () -> Date = Date.init
    ) {
        self.keyStore = keyStore
        self.nowProvider = nowProvider
    }

    /// Signs `(method, pathAndQuery, timestamp, sha256(body))` and
    /// returns the headers to attach to the request.
    ///
    /// - Parameters:
    ///   - method: HTTP method. Case-insensitive on input;
    ///     normalized to uppercase in the canonical form.
    ///   - pathAndQuery: the URL path including any query string,
    ///     e.g. `/api/projects?include=defaults`. Must NOT include the
    ///     scheme/host.
    ///   - body: the request body bytes. Pass `nil` (or empty) for
    ///     bodyless requests; the canonical form uses `""` in that
    ///     case (NOT the hash of an empty string).
    /// - Returns: a dictionary suitable for merging into URLRequest
    ///   headers — ``signatureHeader`` and ``timestampHeader`` keys.
    public func sign(
        method: String,
        pathAndQuery: String,
        body: Data?
    ) async throws -> [String: String] {
        let timestamp = String(Int(nowProvider().timeIntervalSince1970))
        let bodyHash = Self.bodyHash(for: body)
        let canonical = Self.canonicalForm(
            method: method,
            pathAndQuery: pathAndQuery,
            timestamp: timestamp,
            bodyHash: bodyHash
        )
        let signatureDER = try await keyStore.sign(Data(canonical.utf8))
        return [
            Self.timestampHeader: timestamp,
            Self.signatureHeader: signatureDER.base64URLEncodedString()
        ]
    }

    // MARK: - Header names + canonical form (exposed for App-side parity tests)

    public static let timestampHeader = "X-Lakeloom-Timestamp"
    public static let signatureHeader = "X-Lakeloom-Signature"

    /// Canonical message form — exposed for tests and for the App-side
    /// verifier (Genie Code) to mirror exactly.
    public static func canonicalForm(
        method: String,
        pathAndQuery: String,
        timestamp: String,
        bodyHash: String
    ) -> String {
        "\(method.uppercased())\n\(pathAndQuery)\n\(timestamp)\n\(bodyHash)"
    }

    /// Lowercase-hex SHA-256 of the body bytes. For nil/empty bodies,
    /// this is SHA-256 of zero bytes
    /// (`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`)
    /// — same as Genie's server-side `hashlib.sha256(b'').hexdigest()`.
    /// The original spec used `""` for empty bodies, but the contract
    /// locked in Genie's 2026-05-13 upload-traceability response moved
    /// to SHA-256-of-empty-bytes; iOS matches that here.
    public static func bodyHash(for body: Data?) -> String {
        let bytes = body ?? Data()
        let digest = SHA256.hash(data: bytes)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
