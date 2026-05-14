import Foundation

extension Data {
    /// RFC 4648 §5 base64url encoding: standard base64 with `+→-`,
    /// `/→_`, and trailing `=` padding stripped.
    ///
    /// Used everywhere in the QR-pair auth path: the device public key
    /// sent on `/api/pairing/confirm`, the ECDSA signature header
    /// (`X-Lakeloom-Signature`), and any iOS-supplied content hash.
    /// Genie's Node-side decoder uses `Buffer.from(x, 'base64url')`
    /// which accepts this exact format.
    public func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
