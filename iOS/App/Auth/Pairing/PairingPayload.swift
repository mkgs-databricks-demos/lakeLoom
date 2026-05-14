import Foundation

/// Decoded form of the QR code payload the lakeLoom Databricks App
/// renders on its "Pair iPhone" page.
///
/// The QR string is base64-encoded JSON; iOS scans it, runs
/// ``PairingPayload/decode(from:)``, and uses the result to drive
/// ``AuthServicing/signInViaPairing(qrText:)``.
///
/// Field naming mirrors the on-wire JSON (`v`, `xcode_spn`, etc.) via
/// explicit `CodingKeys`. The contract is owned by Genie Code; see
/// `architecture/hi_genie/qr-pair-auth-model.md` and
/// `architecture/hey_isaac/2026-05-13_pairing-auth-endpoints-live.md`.
public struct PairingPayload: Sendable, Equatable, Codable {

    public let version: Int
    public let workspace: WorkspaceInfo
    public let user: UserInfo
    public let xcodeSPN: SPNCredentials
    public let session: SessionInfo
    public let app: AppInfo

    public init(
        version: Int,
        workspace: WorkspaceInfo,
        user: UserInfo,
        xcodeSPN: SPNCredentials,
        session: SessionInfo,
        app: AppInfo
    ) {
        self.version = version
        self.workspace = workspace
        self.user = user
        self.xcodeSPN = xcodeSPN
        self.session = session
        self.app = app
    }

    public struct WorkspaceInfo: Sendable, Equatable, Codable {
        public let url: URL
        public let id: String
        public let name: String
        /// One of `"aws"`, `"azure"`, `"gcp"`. Decoded later into ``Cloud``.
        public let cloud: String

        public init(url: URL, id: String, name: String, cloud: String) {
            self.url = url
            self.id = id
            self.name = name
            self.cloud = cloud
        }
    }

    public struct UserInfo: Sendable, Equatable, Codable {
        public let scimID: String
        public let userName: String
        public let displayName: String

        public init(scimID: String, userName: String, displayName: String) {
            self.scimID = scimID
            self.userName = userName
            self.displayName = displayName
        }

        private enum CodingKeys: String, CodingKey {
            case scimID = "scim_id"
            case userName = "user_name"
            case displayName = "display_name"
        }
    }

    public struct SPNCredentials: Sendable, Equatable, Codable {
        public let clientID: String
        public let clientSecret: String

        public init(clientID: String, clientSecret: String) {
            self.clientID = clientID
            self.clientSecret = clientSecret
        }

        private enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case clientSecret = "client_secret"
        }
    }

    public struct SessionInfo: Sendable, Equatable, Codable {
        /// Opaque session token; iOS sends as `X-Lakeloom-Session` and
        /// the App verifies via `sha256(token)` lookup against
        /// `app.paired_sessions.token_hash`.
        public let token: String
        public let expiresAt: Date

        public init(token: String, expiresAt: Date) {
            self.token = token
            self.expiresAt = expiresAt
        }

        private enum CodingKeys: String, CodingKey {
            case token
            case expiresAt = "expires_at"
        }
    }

    public struct AppInfo: Sendable, Equatable, Codable {
        public let baseURL: URL

        public init(baseURL: URL) {
            self.baseURL = baseURL
        }

        private enum CodingKeys: String, CodingKey {
            case baseURL = "base_url"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case workspace
        case user
        case xcodeSPN = "xcode_spn"
        case session
        case app
    }
}

extension PairingPayload {

    /// The wire-format version this build can decode. Any other value
    /// triggers ``PairingPayload/DecodingError/unsupportedVersion``;
    /// iOS surfaces "Update lakeLoom to pair this workspace."
    public static let supportedVersion: Int = 1

    public enum DecodingError: Error, Sendable, Equatable {
        case invalidBase64
        case invalidJSON(reason: String)
        case unsupportedVersion(found: Int, supported: Int)
    }

    /// Decodes a QR-scanned payload string.
    ///
    /// The wire format is "base64-encoded JSON." We accept either
    /// standard base64 (RFC 4648 §4) or base64url (§5) with or without
    /// padding — Genie's encoder writes one of these and we'd rather
    /// be lenient than tie to a specific variant on the iOS side. JSON
    /// decoding uses `.iso8601` for `expires_at`.
    public static func decode(from qrString: String) throws -> PairingPayload {
        let trimmed = qrString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonData = Self.decodeBase64Variants(trimmed) else {
            throw DecodingError.invalidBase64
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload: PairingPayload
        do {
            payload = try decoder.decode(PairingPayload.self, from: jsonData)
        } catch {
            throw DecodingError.invalidJSON(reason: String(describing: error))
        }
        guard payload.version == supportedVersion else {
            throw DecodingError.unsupportedVersion(
                found: payload.version,
                supported: supportedVersion
            )
        }
        return payload
    }

    /// Tries both base64 variants. Returns `nil` if neither parses.
    private static func decodeBase64Variants(_ s: String) -> Data? {
        if let data = Data(base64Encoded: s) {
            return data
        }
        var normalized = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: normalized)
    }
}

extension PairingPayload.WorkspaceInfo {
    /// Decode the wire-format string into the typed ``Cloud`` enum.
    /// Unknown values become ``Cloud/unknown``.
    public var cloudCase: Cloud {
        Cloud(rawValue: cloud.lowercased()) ?? .unknown
    }
}
