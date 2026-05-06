import Foundation
import Security

/// Errors returned by ``KeychainStore`` operations.
///
/// `osStatus` carries the raw `OSStatus` from the Security framework so
/// we can surface it in diagnostics. `decodeFailed` and `encodeFailed`
/// are surfaced when stored data is corrupt or the migration path can't
/// upgrade an older schema version.
public enum KeychainError: Error, Sendable, Equatable {
    case osStatus(OSStatus)
    case itemNotFound
    case decodeFailed(reason: String)
    case encodeFailed(reason: String)
    case unsupportedSchemaVersion(found: Int, supported: Int)
}

extension KeychainError {
    /// Wraps an `OSStatus` from a Keychain call, mapping `errSecItemNotFound`
    /// to the dedicated case so callers can pattern-match cleanly.
    public static func from(status: OSStatus) -> KeychainError {
        if status == errSecItemNotFound {
            return .itemNotFound
        }
        return .osStatus(status)
    }
}
