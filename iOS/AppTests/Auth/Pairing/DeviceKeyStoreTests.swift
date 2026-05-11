import CryptoKit
import Foundation
import Testing

@testable import LakeloomApp

@Suite("DeviceKeyStore — InMemory test impl")
struct DeviceKeyStoreInMemoryTests {

    @Test("publicKeyDER returns a valid DER-encoded P-256 SubjectPublicKeyInfo")
    func publicKeyDERIsValid() async throws {
        let store = InMemoryDeviceKeyStore()
        let der = try await store.publicKeyDER()
        // Round-trip: decoding the DER should yield a valid P256 public key.
        let key = try P256.Signing.PublicKey(derRepresentation: der)
        // P-256 raw representation is 64 bytes (X || Y).
        #expect(key.rawRepresentation.count == 64)
    }

    @Test("sign produces a DER-encoded ECDSA signature that verifies against the public key")
    func signProducesVerifiableSignature() async throws {
        let store = InMemoryDeviceKeyStore()
        let message = Data("POST\n/api/projects\n1715284800\nabc123".utf8)
        let derSignature = try await store.sign(message)

        let publicKey = await store.currentPublicKey()
        let signature = try P256.Signing.ECDSASignature(derRepresentation: derSignature)
        #expect(publicKey.isValidSignature(signature, for: message))
    }

    @Test("signatures verify only against the matching message")
    func signatureRejectsTamperedMessage() async throws {
        let store = InMemoryDeviceKeyStore()
        let message = Data("original".utf8)
        let tampered = Data("tampered".utf8)
        let der = try await store.sign(message)

        let publicKey = await store.currentPublicKey()
        let signature = try P256.Signing.ECDSASignature(derRepresentation: der)
        #expect(!publicKey.isValidSignature(signature, for: tampered))
    }

    @Test("reset rotates to a new keypair")
    func resetRotatesKey() async throws {
        let store = InMemoryDeviceKeyStore()
        let firstDER = try await store.publicKeyDER()

        try await store.reset()

        let secondDER = try await store.publicKeyDER()
        #expect(firstDER != secondDER)
        let count = await store.resetCount
        #expect(count == 1)
    }

    @Test("publicKeyDER and sign are stable across calls — no per-call key rotation")
    func keyIsStableAcrossCalls() async throws {
        let store = InMemoryDeviceKeyStore()
        let der1 = try await store.publicKeyDER()
        let der2 = try await store.publicKeyDER()
        #expect(der1 == der2)

        let message = Data("hello".utf8)
        // Two signatures of the same message produce different DER bytes
        // (ECDSA is randomized) but BOTH must verify against the same
        // public key.
        let sig1 = try P256.Signing.ECDSASignature(
            derRepresentation: try await store.sign(message)
        )
        let sig2 = try P256.Signing.ECDSASignature(
            derRepresentation: try await store.sign(message)
        )
        let pub = await store.currentPublicKey()
        #expect(pub.isValidSignature(sig1, for: message))
        #expect(pub.isValidSignature(sig2, for: message))
    }
}

@Suite("DeviceKeyStore — Live (Secure Enclave)")
struct DeviceKeyStoreLiveTests {

    /// LiveDeviceKeyStore touches the real Keychain. Tests use a
    /// per-test service identifier so they don't collide with the
    /// production entry or with each other.
    private static func makeStore(testID: String = UUID().uuidString) -> LiveDeviceKeyStore {
        LiveDeviceKeyStore(
            service: "com.databricks.lakeloom.tests.\(testID)",
            account: "device.signing_key.test"
        )
    }

    @Test("first call generates a key and persists it; second call recovers the same public key")
    func keyIsPersistedAcrossInstances() async throws {
        // Skip on platforms without Secure Enclave (some macOS hosts in
        // CI). On iOS Simulator and devices, SE is available.
        guard SecureEnclave.isAvailable else { return }

        let testID = UUID().uuidString
        let store1 = Self.makeStore(testID: testID)
        defer { Task { try? await store1.reset() } }

        let der1 = try await store1.publicKeyDER()

        // Re-instantiate the store — simulates an app cold launch.
        let store2 = Self.makeStore(testID: testID)
        let der2 = try await store2.publicKeyDER()

        #expect(der1 == der2)
    }

    @Test("sign produces a verifiable ECDSA signature")
    func signRoundTrips() async throws {
        guard SecureEnclave.isAvailable else { return }

        let store = Self.makeStore()
        defer { Task { try? await store.reset() } }

        let der = try await store.publicKeyDER()
        let publicKey = try P256.Signing.PublicKey(derRepresentation: der)
        let message = Data("canonical request".utf8)
        let sigDER = try await store.sign(message)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: sigDER)
        #expect(publicKey.isValidSignature(signature, for: message))
    }

    @Test("reset wipes the persisted blob; the next call generates a fresh key")
    func resetClearsPersistedKey() async throws {
        guard SecureEnclave.isAvailable else { return }

        let testID = UUID().uuidString
        let store = Self.makeStore(testID: testID)
        let firstDER = try await store.publicKeyDER()
        try await store.reset()

        // Re-instantiate after reset — should NOT recover the old key.
        let store2 = Self.makeStore(testID: testID)
        defer { Task { try? await store2.reset() } }
        let secondDER = try await store2.publicKeyDER()
        #expect(firstDER != secondDER)
    }
}
