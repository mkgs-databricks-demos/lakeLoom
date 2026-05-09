import CryptoKit
import Foundation
import Security

/// Owns the iOS app's single device signing keypair.
///
/// On first call, generates a P-256 keypair in the Secure Enclave (or
/// software, in the InMemory test impl), persists an opaque
/// `dataRepresentation` blob in the Keychain, and caches the live key
/// for the rest of the process. Subsequent launches restore the key
/// from the blob.
///
/// The private key never leaves the Secure Enclave; this protocol
/// exposes only the public key (DER-encoded) and a `sign(_:)` operation.
public protocol DeviceKeyStoring: Sendable {

    /// DER-encoded `SubjectPublicKeyInfo` of the device public key.
    /// Generates the key on first call. Subsequent calls return the
    /// same key for the lifetime of this app install.
    func publicKeyDER() async throws -> Data

    /// Sign `message` with the device private key. Returns a
    /// DER-encoded ECDSA P-256 signature.
    func sign(_ message: Data) async throws -> Data

    /// Wipe the persisted key blob. Used by "Reset local data" or the
    /// first-launch hygiene sentinel. Idempotent.
    func reset() async throws
}

public enum DeviceKeyStoreError: Error, Sendable, Equatable {
    /// Secure Enclave reports the platform doesn't support hardware-
    /// backed keys (very old devices, or some macOS without T2/M-series
    /// chips). The app falls back to surfacing this rather than
    /// silently downgrading to software keys.
    case secureEnclaveUnavailable

    /// `SecItemAdd` / `SecItemCopyMatching` returned a non-success
    /// `OSStatus`. Carries the status for diagnostics.
    case keychainFailed(OSStatus)

    /// The persisted blob couldn't be reconstituted into a
    /// `SecureEnclave.P256.Signing.PrivateKey`. The blob is treated as
    /// corrupted — `reset()` clears it and the next call regenerates.
    case persistedBlobInvalid(reason: String)

    /// The signing operation itself failed (rare — usually means the
    /// Secure Enclave was deauthorized).
    case signingFailed(reason: String)
}

/// Production ``DeviceKeyStoring`` backed by `SecureEnclave.P256`.
///
/// The Keychain entry is a `kSecClassGenericPassword` with a fixed
/// account name; `kSecAttrAccessible` =
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, no iCloud sync.
public actor LiveDeviceKeyStore: DeviceKeyStoring {

    private let service: String
    private let account: String
    private var cachedKey: SecureEnclave.P256.Signing.PrivateKey?

    public init(
        service: String = "com.databricks.lakeloom.device",
        account: String = "device.signing_key"
    ) {
        self.service = service
        self.account = account
    }

    public func publicKeyDER() async throws -> Data {
        let key = try await loadOrCreateKey()
        return key.publicKey.derRepresentation
    }

    public func sign(_ message: Data) async throws -> Data {
        let key = try await loadOrCreateKey()
        do {
            let signature = try key.signature(for: message)
            return signature.derRepresentation
        } catch {
            throw DeviceKeyStoreError.signingFailed(reason: error.localizedDescription)
        }
    }

    public func reset() async throws {
        cachedKey = nil
        try deleteFromKeychain()
    }

    // MARK: - Private

    private func loadOrCreateKey() async throws -> SecureEnclave.P256.Signing.PrivateKey {
        if let cached = cachedKey { return cached }

        guard SecureEnclave.isAvailable else {
            throw DeviceKeyStoreError.secureEnclaveUnavailable
        }

        if let blob = try loadFromKeychain() {
            do {
                let key = try SecureEnclave.P256.Signing.PrivateKey(
                    dataRepresentation: blob
                )
                cachedKey = key
                return key
            } catch {
                // Persisted blob is unusable — most likely the device
                // was restored from backup and the Secure Enclave can't
                // decrypt it. Wipe and regenerate.
                try? deleteFromKeychain()
            }
        }

        let newKey: SecureEnclave.P256.Signing.PrivateKey
        do {
            newKey = try SecureEnclave.P256.Signing.PrivateKey()
        } catch {
            throw DeviceKeyStoreError.signingFailed(
                reason: "secure enclave key creation: \(error.localizedDescription)"
            )
        }
        try saveToKeychain(newKey.dataRepresentation)
        cachedKey = newKey
        return newKey
    }

    private func loadFromKeychain() throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw DeviceKeyStoreError.persistedBlobInvalid(reason: "non-Data result")
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw DeviceKeyStoreError.keychainFailed(status)
        }
    }

    private func saveToKeychain(_ data: Data) throws {
        // Try update first; if no existing item, fall through to add.
        let updateQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false
        ]
        let updateAttributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(
            updateQuery as CFDictionary,
            updateAttributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw DeviceKeyStoreError.keychainFailed(updateStatus)
        }

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: data
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw DeviceKeyStoreError.keychainFailed(addStatus)
        }
    }

    private func deleteFromKeychain() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw DeviceKeyStoreError.keychainFailed(status)
        }
    }
}
