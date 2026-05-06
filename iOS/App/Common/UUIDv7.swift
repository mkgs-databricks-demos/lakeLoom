import Foundation

/// Time-ordered UUID per draft RFC 4122 v7 (now RFC 9562 §5.7).
/// First 48 bits are the unix-epoch millisecond timestamp; remaining
/// bits are random with the version (7) and variant (10) markers
/// in the right places.
///
/// Lakeloom uses these as `record_uuid` in the bronze schema and as
/// `client_generated_id` for idempotent project creation. The
/// time-ordered prefix means newer records sort after older ones —
/// useful for both row ordering on Delta and for Lakebase scans.
public enum UUIDv7 {

    /// Generate a fresh UUIDv7 from the current wall clock.
    public static func generate(now: Date = Date()) -> String {
        let unixMs = UInt64(now.timeIntervalSince1970 * 1_000)
        var bytes = [UInt8](repeating: 0, count: 16)

        // 48 bits — unix timestamp in milliseconds (big-endian).
        bytes[0] = UInt8((unixMs >> 40) & 0xFF)
        bytes[1] = UInt8((unixMs >> 32) & 0xFF)
        bytes[2] = UInt8((unixMs >> 24) & 0xFF)
        bytes[3] = UInt8((unixMs >> 16) & 0xFF)
        bytes[4] = UInt8((unixMs >> 8) & 0xFF)
        bytes[5] = UInt8(unixMs & 0xFF)

        // 12 random bits + 4-bit version (0b0111 = 7) in byte 6 and the
        // top half of byte 7. We let SecRandomCopyBytes fill 10 bytes
        // (bytes 6–15) and then overwrite the version + variant bits.
        var random = [UInt8](repeating: 0, count: 10)
        let status = random.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        if status != errSecSuccess {
            // Extremely unlikely. Fall back to arc4random_buf-equivalent
            // via Foundation's random number generator — non-cryptographic
            // but the time prefix still ensures ordering and uniqueness.
            for i in 0..<random.count {
                random[i] = UInt8.random(in: 0...0xFF)
            }
        }
        for i in 0..<10 {
            bytes[6 + i] = random[i]
        }

        // Version: high nibble of byte 6 = 0b0111.
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        // Variant: top two bits of byte 8 = 0b10.
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return formatUUIDString(bytes)
    }

    /// Lower-case canonical UUID format (8-4-4-4-12 hex with dashes).
    private static func formatUUIDString(_ bytes: [UInt8]) -> String {
        let hex: [String] = bytes.map { String(format: "%02x", $0) }
        return "\(hex[0])\(hex[1])\(hex[2])\(hex[3])-"
            + "\(hex[4])\(hex[5])-"
            + "\(hex[6])\(hex[7])-"
            + "\(hex[8])\(hex[9])-"
            + "\(hex[10])\(hex[11])\(hex[12])\(hex[13])\(hex[14])\(hex[15])"
    }
}
