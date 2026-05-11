import CryptoKit
import Foundation

@testable import LakeloomApp

/// Software-backed ``DeviceKeyStoring`` for unit tests. Generates a
/// fresh `P256.Signing.PrivateKey` (NOT Secure Enclave) on init;
/// produces compatible DER public key + DER ECDSA signatures so
/// callers see the same shape they'd see from
/// ``LiveDeviceKeyStore``.
public actor InMemoryDeviceKeyStore: DeviceKeyStoring {

    private var key: P256.Signing.PrivateKey
    public private(set) var resetCount = 0

    public init() {
        self.key = P256.Signing.PrivateKey()
    }

    public func publicKeyDER() async throws -> Data {
        key.publicKey.derRepresentation
    }

    public func sign(_ message: Data) async throws -> Data {
        try key.signature(for: message).derRepresentation
    }

    public func reset() async throws {
        // Mirror Live's regenerate-on-next-use behavior: drop the key
        // and synthesize a fresh one for the next call.
        key = P256.Signing.PrivateKey()
        resetCount += 1
    }

    /// Test helper — returns the public key matching the current
    /// private key, used to verify signatures the store produces.
    public func currentPublicKey() async -> P256.Signing.PublicKey {
        key.publicKey
    }
}
