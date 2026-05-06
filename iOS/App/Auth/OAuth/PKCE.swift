import CryptoKit
import Foundation

/// PKCE (Proof Key for Code Exchange) material per RFC 7636.
///
/// The verifier is a 32-byte random secret that stays on-device. The
/// challenge is `BASE64URL-NO-PAD(SHA256(verifier))` and is sent on the
/// authorization request. The verifier is sent on the token exchange so
/// the auth server can confirm the original client.
///
/// See Module 01 §5.3.
public struct PKCE: Sendable, Equatable {
    /// 43–128-character URL-safe code verifier (we use 43 characters,
    /// from 32 random bytes, base64url-encoded without padding).
    public let codeVerifier: String

    /// SHA-256 of the verifier, base64url-encoded without padding.
    public let codeChallenge: String

    /// `S256` — the only challenge method we support. Plain is forbidden.
    public let codeChallengeMethod: String = "S256"
}

extension PKCE {
    /// Generates fresh PKCE material using a cryptographically secure RNG.
    /// Throws ``PKCEError/randomGenerationFailed`` if the system RNG returns
    /// a non-success status.
    public static func generate() throws -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw PKCEError.randomGenerationFailed(status: status)
        }
        let verifierData = Data(bytes)
        let verifier = verifierData.base64URLEncodedString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        return PKCE(codeVerifier: verifier, codeChallenge: challenge)
    }

    /// Test-friendly initializer that derives the challenge from a caller-
    /// supplied verifier. Production code uses ``generate()``.
    public static func from(verifier: String) -> PKCE {
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        return PKCE(codeVerifier: verifier, codeChallenge: challenge)
    }
}

/// Errors produced by ``PKCE/generate()``.
public enum PKCEError: Error, Sendable, Equatable {
    case randomGenerationFailed(status: OSStatus)
}

// MARK: - base64url helpers

extension Data {
    /// RFC 7636 base64url encoding: standard base64 with `+→-`, `/→_`,
    /// and trailing `=` padding stripped.
    public func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
