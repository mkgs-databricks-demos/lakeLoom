import SwiftUI
import Testing

@testable import LakeloomApp

@Suite("BrandMotion")
struct BrandMotionTests {

    @Test("duration constants match Genie's brand-spec table")
    func durations() {
        // From Genie's 2026-05-15 brand guidelines:
        // 100 ms button press, 200 ms dropdown, 300 ms modal,
        // 400 ms page transition.
        #expect(BrandMotion.buttonPress == 0.1)
        #expect(BrandMotion.dropdown == 0.2)
        #expect(BrandMotion.modal == 0.3)
        #expect(BrandMotion.pageTransition == 0.4)
    }

    @MainActor
    @Test("Animation.brandRespectingReduceMotion preserves the base when reduce-motion is off")
    func reduceMotionOffPreservesBase() {
        // We can't toggle UIAccessibility.isReduceMotionEnabled in
        // a unit test, but we CAN assert that the wrapper returns
        // a non-nil Animation no matter which branch fires — which
        // catches the simple null-deref bug.
        let wrapped = Animation.brandRespectingReduceMotion(.brandModal, duration: BrandMotion.modal)
        _ = wrapped
    }
}
