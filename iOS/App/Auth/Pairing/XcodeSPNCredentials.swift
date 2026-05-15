import Foundation

/// The iOS-facing SPN's OAuth client credentials, delivered via QR
/// pairing and persisted in Keychain.
///
/// Used by ``M2MTokenClient`` to exchange for an M2M Bearer token at
/// `<workspace>/oidc/v1/token` on every iOS → App request. The Xcode
/// SPN has no workspace data-plane permissions — its sole entitlement
/// is `CAN_USE` on the App resource, so the bearer it produces only
/// satisfies Databricks Apps' platform-level auth, never workspace
/// REST APIs directly.
///
/// Distinct from the App-side SPN (`lakeloom-{schema}`) which writes
/// UC Volumes and produces ZeroBus events — that SPN never touches
/// iOS.
public struct XcodeSPNCredentials: Sendable, Equatable, Hashable, Codable {
    public let clientID: String
    public let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

extension XcodeSPNCredentials {
    public init(_ spn: PairingPayload.SPNCredentials) {
        self.init(clientID: spn.clientID, clientSecret: spn.clientSecret)
    }
}
