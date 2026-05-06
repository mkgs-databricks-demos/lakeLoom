import Foundation

/// The set of value types that can appear in ``LogMetadata``.
///
/// Closed-by-design so call sites are forced to pick a redaction-safe
/// shape. Raw `String` from user input cannot be passed via the typed
/// metadata path — callers must wrap it in `.redacted(label:)` (which
/// records only the *label*, not the value) or the dedicated typed
/// shapes below.
///
/// See Module 09 §3.1 and §5.3 for the redaction policy.
public enum LogValue: Sendable, Equatable, Codable {

    /// A string value the caller has confirmed is safe to log:
    /// enum names, status codes, HTTP method names, etc. Free-text
    /// user input must NOT be wrapped in this case — use
    /// ``redacted(label:)`` or ``uuidPrefix(_:)`` instead.
    case string(String)

    case int(Int64)
    case double(Double)
    case bool(Bool)

    /// A Duration (or duration-like thing). Encoded as integer
    /// nanoseconds for Codable round-tripping.
    case duration(Duration)

    /// Marks a redacted value. The label describes what was redacted
    /// (e.g. `"workspace_url"`, `"token"`) but never carries the
    /// original value. Logs render this as `<<redacted: label>>`.
    case redacted(label: String)

    /// First 8 characters of a UUID-shaped string. Useful for
    /// correlating events across logs without leaking the full ID.
    case uuidPrefix(String)

    /// A typed error case name. Carries no payload — just the case
    /// label, e.g. `"refreshFailed"` or `"http_503"`.
    case errorCode(String)

    /// Render to a stable string form for log output. Sensitive data
    /// is replaced with redaction markers.
    public func render() -> String {
        switch self {
        case .string(let s):
            return s
        case .int(let n):
            return String(n)
        case .double(let d):
            return String(d)
        case .bool(let b):
            return b ? "true" : "false"
        case .duration(let d):
            // Duration → "<seconds>.<fractionalSeconds>s"
            let nanos = d.components.attoseconds / 1_000_000_000
            let seconds = d.components.seconds
            return "\(seconds).\(String(format: "%09d", nanos))s"
        case .redacted(let label):
            return "<<redacted: \(label)>>"
        case .uuidPrefix(let id):
            let prefix = id.prefix(8)
            return prefix.count == id.count ? String(prefix) : "\(prefix)…"
        case .errorCode(let code):
            return code
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
        case label
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "string": self = .string(try container.decode(String.self, forKey: .value))
        case "int": self = .int(try container.decode(Int64.self, forKey: .value))
        case "double": self = .double(try container.decode(Double.self, forKey: .value))
        case "bool": self = .bool(try container.decode(Bool.self, forKey: .value))
        case "duration":
            let nanos = try container.decode(Int64.self, forKey: .value)
            self = .duration(.nanoseconds(nanos))
        case "redacted": self = .redacted(label: try container.decode(String.self, forKey: .label))
        case "uuidPrefix": self = .uuidPrefix(try container.decode(String.self, forKey: .value))
        case "errorCode": self = .errorCode(try container.decode(String.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "unknown LogValue kind: \(kind)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let s):
            try container.encode("string", forKey: .kind)
            try container.encode(s, forKey: .value)
        case .int(let n):
            try container.encode("int", forKey: .kind)
            try container.encode(n, forKey: .value)
        case .double(let d):
            try container.encode("double", forKey: .kind)
            try container.encode(d, forKey: .value)
        case .bool(let b):
            try container.encode("bool", forKey: .kind)
            try container.encode(b, forKey: .value)
        case .duration(let d):
            try container.encode("duration", forKey: .kind)
            // Pack into nanoseconds; sufficient resolution for our needs.
            let nanos = d.components.seconds * 1_000_000_000
                + d.components.attoseconds / 1_000_000_000
            try container.encode(nanos, forKey: .value)
        case .redacted(let label):
            try container.encode("redacted", forKey: .kind)
            try container.encode(label, forKey: .label)
        case .uuidPrefix(let id):
            try container.encode("uuidPrefix", forKey: .kind)
            try container.encode(id, forKey: .value)
        case .errorCode(let code):
            try container.encode("errorCode", forKey: .kind)
            try container.encode(code, forKey: .value)
        }
    }
}
