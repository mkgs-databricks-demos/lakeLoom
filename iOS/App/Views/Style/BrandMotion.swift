import SwiftUI
import UIKit

/// Lakeloom motion tokens.
///
/// Per Genie's 2026-05-15 brand guidelines:
///
/// | Duration | Use |
/// |----------|-----|
/// | 100 ms | Button press, toggle, tooltip |
/// | 200 ms | Dropdown, accordion, tab switch |
/// | 300 ms | Modal enter, sidebar collapse |
/// | 400 ms | Page transitions, skeleton reveal |
///
/// Easing: `.easeOut` for entrances (default), `.easeIn` for exits.
/// Exits faster than entrances.
///
/// Accessibility: `UIAccessibility.isReduceMotionEnabled` is honored
/// via `Animation.brandRespectingReduceMotion(_:)` — when the user
/// has Reduce Motion turned on, the animation flattens to a `.linear`
/// with the same duration so transitions still happen but without
/// secondary motion (springs, scale, transforms).
public enum BrandMotion {

    /// Button press, toggle, tooltip — fast acknowledgement.
    public static let buttonPress: Double = 0.1
    /// Dropdown, accordion, tab switch.
    public static let dropdown: Double = 0.2
    /// Modal enter, sidebar collapse.
    public static let modal: Double = 0.3
    /// Page transitions, skeleton reveal.
    public static let pageTransition: Double = 0.4

    /// Returns true when the system or the user has asked for
    /// reduced motion. Views and animation factories should check
    /// this and downgrade to subtler effects.
    ///
    /// `UIAccessibility.isReduceMotionEnabled` is `@MainActor`-isolated,
    /// so this accessor must be called from the main actor (true for
    /// any SwiftUI view body and any view-render callback).
    @MainActor
    public static var prefersReducedMotion: Bool {
        UIAccessibility.isReduceMotionEnabled
    }
}

extension Animation {

    /// 100 ms easeOut — button press feedback.
    public static let brandPress: Animation = .easeOut(duration: BrandMotion.buttonPress)
    /// 200 ms easeOut — dropdowns / tab switches.
    public static let brandDropdown: Animation = .easeOut(duration: BrandMotion.dropdown)
    /// 300 ms easeOut — modal entrance.
    public static let brandModal: Animation = .easeOut(duration: BrandMotion.modal)
    /// 200 ms easeIn — modal/dropdown exit (faster than entrance).
    public static let brandModalExit: Animation = .easeIn(duration: BrandMotion.dropdown)
    /// 400 ms easeOut — page transitions / skeleton reveals.
    public static let brandPageTransition: Animation = .easeOut(duration: BrandMotion.pageTransition)

    /// Wrap any brand animation so it downgrades to `.linear` (no
    /// springs, no overshoot) when Reduce Motion is on. Duration is
    /// preserved so the timing-driven UX still progresses.
    ///
    /// `@MainActor` because the underlying probe
    /// (`UIAccessibility.isReduceMotionEnabled`) is main-actor
    /// isolated; SwiftUI view bodies are already main-actor so the
    /// call site is free of friction.
    @MainActor
    public static func brandRespectingReduceMotion(_ base: Animation, duration: Double) -> Animation {
        BrandMotion.prefersReducedMotion ? .linear(duration: duration) : base
    }
}
