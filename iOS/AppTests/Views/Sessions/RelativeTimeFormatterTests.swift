import Foundation
import Testing

@testable import LakeloomApp

@Suite("RelativeTimeFormatter")
struct RelativeTimeFormatterTests {

    private static let now = Date(timeIntervalSince1970: 1_780_000_000)

    private static func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    @Test("under a minute renders Just now")
    func underMinute() {
        let cal = Self.calendar()
        #expect(RelativeTimeFormatter.format(Self.now, now: Self.now, calendar: cal) == "Just now")
        #expect(RelativeTimeFormatter.format(Self.now.addingTimeInterval(-30), now: Self.now, calendar: cal) == "Just now")
        #expect(RelativeTimeFormatter.format(Self.now.addingTimeInterval(-59), now: Self.now, calendar: cal) == "Just now")
    }

    @Test("under an hour renders Nm ago")
    func underHour() {
        let cal = Self.calendar()
        #expect(RelativeTimeFormatter.format(Self.now.addingTimeInterval(-60), now: Self.now, calendar: cal) == "1m ago")
        #expect(RelativeTimeFormatter.format(Self.now.addingTimeInterval(-5 * 60), now: Self.now, calendar: cal) == "5m ago")
        #expect(RelativeTimeFormatter.format(Self.now.addingTimeInterval(-59 * 60), now: Self.now, calendar: cal) == "59m ago")
    }

    @Test("under a day renders Nh ago")
    func underDay() {
        let cal = Self.calendar()
        #expect(RelativeTimeFormatter.format(Self.now.addingTimeInterval(-60 * 60), now: Self.now, calendar: cal) == "1h ago")
        #expect(RelativeTimeFormatter.format(Self.now.addingTimeInterval(-3 * 60 * 60), now: Self.now, calendar: cal) == "3h ago")
        #expect(RelativeTimeFormatter.format(Self.now.addingTimeInterval(-23 * 60 * 60), now: Self.now, calendar: cal) == "23h ago")
    }

    @Test("yesterday renders Yesterday")
    func yesterday() {
        let cal = Self.calendar()
        // 26 hours back puts us in the previous UTC day from now.
        let yesterday = Self.now.addingTimeInterval(-26 * 60 * 60)
        #expect(RelativeTimeFormatter.format(yesterday, now: Self.now, calendar: cal) == "Yesterday")
    }

    @Test("within same year renders MMM d (no year)")
    func sameYear() {
        let cal = Self.calendar()
        // 5 days back — well outside Yesterday but still same year as `now`.
        let earlier = Self.now.addingTimeInterval(-5 * 24 * 60 * 60)
        let formatted = RelativeTimeFormatter.format(earlier, now: Self.now, calendar: cal)
        // The exact rendering depends on the system locale; assert
        // structural properties (contains month + day, doesn't
        // contain a year).
        #expect(formatted.count >= 4) // e.g. "Aug 25" / "Aug 25"
        #expect(!formatted.contains("2026"))
        #expect(!formatted.contains("2027"))
    }

    @Test("prior year renders MMM d, yyyy")
    func priorYear() {
        let cal = Self.calendar()
        // 400 days back puts us a year+ earlier.
        let earlier = Self.now.addingTimeInterval(-400 * 24 * 60 * 60)
        let formatted = RelativeTimeFormatter.format(earlier, now: Self.now, calendar: cal)
        // Should include some 4-digit year.
        let containsFourDigitYear = formatted.contains { $0.isNumber } &&
            (formatted.range(of: "\\d{4}", options: .regularExpression) != nil)
        #expect(containsFourDigitYear)
    }
}
