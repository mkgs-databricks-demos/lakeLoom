import Foundation

/// Snapshot of how close the active QR-paired session is to expiry.
///
/// Used by `AccountSettingsView` (the Pairing section) and by the
/// home toolbar warning pill. Pure value-type — feed it
/// `sessionExpiresAt` from the workspace credential plus a clock and
/// it tells you both the urgency bucket and the user-visible text.
///
/// Reading `now` from the caller (rather than `Date.init()`) keeps the
/// type fully unit-testable; production wiring passes `Date()`.
public struct PairingStatus: Sendable, Equatable {

    /// Urgency bucket. Maps onto color + iconography in the UI.
    public enum WarningLevel: Sendable, Equatable {
        /// >7 days remaining. Treat as healthy; no chip, no banner.
        case healthy
        /// 48 h – 7 days. Soft heads-up; yellow chip on Account
        /// page, no home-toolbar pill yet.
        case soft
        /// 12 h – 48 h. Prompt-to-act; orange chip on Account AND a
        /// pill on the home toolbar.
        case warning
        /// <12 h or already expired. Strong nudge; red chip + pill.
        case urgent
    }

    public let level: WarningLevel
    /// Compact summary suitable for a toolbar pill, e.g.
    /// `"Expires in 3 days"` or `"Expired"`.
    public let shortDescription: String
    /// Full sentence for an Account-page row, e.g.
    /// `"Paired until May 31, 2026 at 4:00 PM"`.
    public let longDescription: String
    /// Cached for callers who want to compose their own text. Always
    /// non-negative — clamped to `0` once we're past the expiry.
    public let secondsUntilExpiry: TimeInterval

    public init(expiresAt: Date, now: Date) {
        let remaining = max(0, expiresAt.timeIntervalSince(now))
        self.secondsUntilExpiry = remaining

        if remaining <= 0 {
            self.level = .urgent
        } else if remaining < 12 * 3600 {
            self.level = .urgent
        } else if remaining < 48 * 3600 {
            self.level = .warning
        } else if remaining < 7 * 86400 {
            self.level = .soft
        } else {
            self.level = .healthy
        }

        self.shortDescription = Self.formatShort(remaining: remaining)
        self.longDescription = Self.formatLong(expiresAt: expiresAt, remaining: remaining)
    }

    // MARK: - Formatting

    /// Hand-rolled relative-time formatter so the message reads as a
    /// recorder-friendly heads-up rather than `RelativeDateTimeFormatter`'s
    /// "in 3 days" / "in 4 hours" cadence. We want the exact same
    /// "Expires in X" shape for both the pill and the chip so the
    /// translation between surfaces stays trivial.
    private static func formatShort(remaining: TimeInterval) -> String {
        if remaining <= 0 {
            return "Expired"
        }
        // Sub-48h always renders in hours so warning/urgent states
        // read as action-driving — "Expires in 36 hours" is sharper
        // than "Expires tomorrow" when we want the user to re-pair
        // before walking into a meeting. Days are used only when
        // the soft/healthy windows are wide enough that finer
        // resolution stops adding signal.
        if remaining >= 48 * 3600 {
            let days = Int(remaining / 86400)
            return "Expires in \(days) days"
        }
        let hours = Int(remaining / 3600)
        if hours >= 2 {
            return "Expires in \(hours) hours"
        }
        if hours == 1 {
            return "Expires in 1 hour"
        }
        let minutes = max(1, Int(remaining / 60))
        if minutes >= 2 {
            return "Expires in \(minutes) minutes"
        }
        return "Expires in 1 minute"
    }

    private static func formatLong(expiresAt: Date, remaining: TimeInterval) -> String {
        if remaining <= 0 {
            return "Pairing expired — scan a fresh QR code to keep using this device."
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Paired until \(formatter.string(from: expiresAt))"
    }
}
