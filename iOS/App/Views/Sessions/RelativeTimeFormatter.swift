import Foundation

/// Renders a past `Date` as a brief human-readable string keyed off
/// "now". Used by capture rows + upload rows so the list reads
/// "5m ago" / "Yesterday" / "Mar 15" instead of an ISO timestamp.
///
/// Pure function — `now` is injected so tests are deterministic.
/// View call sites pass `Date()` or a `TimelineView.Context.date` for
/// live-ticking displays.
///
/// Format ladder:
/// * < 60s         → "Just now"
/// * < 60m         → "Nm ago"
/// * < 24h         → "Nh ago"
/// * Same calendar day or yesterday → "Yesterday"
/// * Same calendar year → "MMM d" (e.g. "Mar 15")
/// * Earlier year  → "MMM d, yyyy" (e.g. "Feb 12, 2024")
///
/// Future dates aren't expected in this app (`startedAt` is a
/// recorded past timestamp), but a future date renders as the
/// calendar form rather than negative-minute nonsense.
enum RelativeTimeFormatter {

    static func format(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let interval = now.timeIntervalSince(date)

        if interval < 60 && interval >= -60 {
            return "Just now"
        }
        if interval < 60 * 60 && interval > 0 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        }
        if interval < 60 * 60 * 24 && interval > 0 {
            let hours = Int(interval / (60 * 60))
            return "\(hours)h ago"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return calendarString(for: date, now: now, calendar: calendar)
    }

    private static func calendarString(for date: Date, now: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMMdyyyy")
        }
        return formatter.string(from: date)
    }
}
