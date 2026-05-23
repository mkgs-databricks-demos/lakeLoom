import Foundation
import Security

/// Provides a stable per-device UUID used to identify this physical
/// iPhone/iPad across pairing sessions, sign-outs, and (per keychain
/// semantics) most uninstall+reinstall cycles. Per Genie's
/// `hey_isaac/2026-05-23_uploads-surfacing-answers.md`, this is the
/// `device_id` field on every ZeroBus transcript event — gives the
/// analytics layer a stable join key without exposing the Secure
/// Enclave public key (which rotates) or `identifierForVendor`
/// (which resets on uninstall).
///
/// The Live implementation lazy-creates a UUID v4 on first read and
/// persists it via `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
/// Subsequent reads return the persisted value verbatim.
public protocol DeviceIdentityStore: Sendable {
    /// Returns the stable device UUID, generating + persisting one
    /// on first call. Throws if the keychain backend is unavailable
    /// (rare — kSecAttrAccessibleAfterFirstUnlock means we can read
    /// even when the device is locked, post-boot).
    func deviceID() async throws -> String
}

// MARK: - Live (keychain-backed)

public actor LiveDeviceIdentityStore: DeviceIdentityStore {

    /// Keychain service namespace. Distinct from the auth namespace
    /// (`com.databricks.lakeloom.auth`) so a "reset all auth" sweep
    /// doesn't wipe the device identity — the UUID is per-device
    /// physical identity, not per-paired-session.
    public static let service = "com.databricks.lakeloom.device"
    public static let account = "device_id"

    /// In-memory cache after first read; avoids the SecItem round
    /// trip on every event send.
    private var cached: String?

    public init() {}

    public func deviceID() async throws -> String {
        if let cached { return cached }
        if let existing = try loadExisting() {
            cached = existing
            return existing
        }
        let new = UUID().uuidString
        try persist(new)
        cached = new
        return new
    }

    // MARK: SecItem helpers

    private func loadExisting() throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecAttrSynchronizable: false,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let string = String(data: data, encoding: .utf8),
                  !string.isEmpty else {
                throw DeviceIdentityError.decodeFailed
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw DeviceIdentityError.keychainStatus(status)
        }
    }

    private func persist(_ uuid: String) throws {
        let data = Data(uuid.utf8)
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecAttrSynchronizable: false
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw DeviceIdentityError.keychainStatus(updateStatus)
        }

        var addQuery = baseQuery
        for (key, value) in attributes {
            addQuery[key] = value
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw DeviceIdentityError.keychainStatus(addStatus)
        }
    }
}

// MARK: - In-memory (tests)

/// Test-only impl. Same lazy-create-then-cache contract as the Live
/// store; the difference is the backing is an actor-local property
/// rather than the Security framework, so unit tests don't have to
/// touch the real keychain.
public actor InMemoryDeviceIdentityStore: DeviceIdentityStore {
    private var stored: String?

    public init(preloaded: String? = nil) {
        self.stored = preloaded
    }

    public func deviceID() async throws -> String {
        if let stored { return stored }
        let new = UUID().uuidString
        stored = new
        return new
    }

    /// Test helper — current value without triggering lazy create.
    public func currentValue() -> String? { stored }
}

// MARK: - Errors

public enum DeviceIdentityError: Error, Sendable, Equatable {
    case keychainStatus(OSStatus)
    case decodeFailed
}
