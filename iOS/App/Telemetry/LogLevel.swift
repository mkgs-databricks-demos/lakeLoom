import Foundation
import OSLog

/// Severity ladder for ``AppLogger`` calls. Mirrors Apple's `OSLogType`
/// plus an explicit `notice` and `warning` to cover the common "important
/// but not an error" cases without callers having to pick between
/// `.info` and `.error`.
///
/// See Module 09 §5.2 for the per-level guidance table.
public enum LogLevel: String, Sendable, Codable, CaseIterable, Comparable {
    case trace
    case debug
    case info
    case notice
    case warning
    case error
    case fault

    private var ordinal: Int {
        switch self {
        case .trace: return 0
        case .debug: return 1
        case .info: return 2
        case .notice: return 3
        case .warning: return 4
        case .error: return 5
        case .fault: return 6
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.ordinal < rhs.ordinal
    }

    /// Closest `OSLogType` for delegation to Apple's unified logging.
    /// `notice` and `warning` collapse onto `.default` and `.error`
    /// respectively — Console.app filtering still works because we also
    /// emit the level as part of the log message metadata.
    public var osLogType: OSLogType {
        switch self {
        case .trace, .debug: return .debug
        case .info: return .info
        case .notice: return .default
        case .warning: return .error
        case .error: return .error
        case .fault: return .fault
        }
    }
}
