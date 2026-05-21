import Foundation
import Testing

@testable import LakeloomApp

@Suite("ElapsedTimer")
struct ElapsedTimerTests {

    @Test("zero and sub-second render as 0:00")
    func zeroAndSubSecond() {
        #expect(ElapsedTimer.format(0) == "0:00")
        #expect(ElapsedTimer.format(0.4) == "0:00")
        #expect(ElapsedTimer.format(0.999) == "0:00")
    }

    @Test("single-digit seconds within first minute")
    func subMinute() {
        #expect(ElapsedTimer.format(1) == "0:01")
        #expect(ElapsedTimer.format(5) == "0:05")
        #expect(ElapsedTimer.format(59.7) == "0:59")
    }

    @Test("M:SS for under an hour")
    func underHour() {
        #expect(ElapsedTimer.format(60) == "1:00")
        #expect(ElapsedTimer.format(83) == "1:23")
        #expect(ElapsedTimer.format(3599) == "59:59")
    }

    @Test("H:MM:SS at and above one hour")
    func atOrAboveOneHour() {
        #expect(ElapsedTimer.format(3600) == "1:00:00")
        #expect(ElapsedTimer.format(3725) == "1:02:05")
        #expect(ElapsedTimer.format(7325) == "2:02:05")
    }

    @Test("negative inputs clamp to 0:00")
    func negativeClamps() {
        #expect(ElapsedTimer.format(-1) == "0:00")
        #expect(ElapsedTimer.format(-3600) == "0:00")
    }
}
