import SwiftUI
import UIKit

/// Lakeloom brand color tokens.
///
/// Sourced from Genie's 2026-05-15 Databricks brand guidelines note
/// (`architecture/hey_isaac/2026-05-15_brand-guidelines-and-ios-icon.md`).
/// Two layers:
///
///   1. **Palette** — raw color values keyed by their Databricks brand
///      names (`lava600`, `navy800`, etc.). These are not meant for
///      direct use in views — they're the source-of-truth values that
///      semantic tokens compose from. Treat them as constants.
///   2. **Semantic tokens** — `accentPrimary`, `textPrimary`,
///      `surfacePrimary`, etc. These automatically swap between the
///      brand's documented light/dark mappings via
///      `Color(light:dark:)`. View code should use these — never the
///      raw palette — so a single retune of the brand swap layer
///      cascades everywhere.
///
/// Accessibility notes (from Genie's spec):
///   - Body text contrast ≥ 4.5:1 required.
///   - Large text (≥ 18 pt regular or ≥ 14 pt bold) ≥ 3.0:1 required.
///   - Lava 600 on white = 3.6:1. Use only for buttons + headings
///     (≥ 14 pt bold), never for body text. `linkPrimary` (Blue 600
///     on white = 5.1:1) is the body-link choice.
public enum BrandColors {

    // MARK: - Palette (raw brand values)
    //
    // Never use these directly in views — go through the semantic
    // tokens below so light/dark swap stays consistent.

    /// `#FF3621` — primary accent (CTAs, highlights, active states)
    public static let lava600 = Color(hex: 0xFF3621)
    /// `#FF5F46` — accent in dark mode + error in dark mode
    public static let lava500 = Color(hex: 0xFF5F46)
    /// `#BD2B26` — error in light mode
    public static let lava700 = Color(hex: 0xBD2B26)

    /// `#1B3139` — primary text light, dark surface
    public static let navy800 = Color(hex: 0x1B3139)
    /// `#0B2026` — deepest dark surface
    public static let navy900 = Color(hex: 0x0B2026)
    /// `#143D4A` — raised dark surface
    public static let navy700 = Color(hex: 0x143D4A)
    /// `#1B5162` — dark-mode border
    public static let navy600 = Color(hex: 0x1B5162)
    /// `#90A5B1` — muted / disabled in both modes
    public static let navy400 = Color(hex: 0x90A5B1)

    public static let oatLight = Color(hex: 0xF9F7F4)
    public static let oatMedium = Color(hex: 0xEEEDE9)
    public static let white = Color(hex: 0xFFFFFF)

    public static let grayNav = Color(hex: 0x303F47)
    public static let grayText = Color(hex: 0x5A6F77)
    public static let grayLines = Color(hex: 0xDCE0E2)

    public static let green700 = Color(hex: 0x00875C)
    public static let green600 = Color(hex: 0x00A972)
    public static let yellow700 = Color(hex: 0xBA7B23)
    public static let yellow600 = Color(hex: 0xFFAB00)
    public static let blue600 = Color(hex: 0x2272B4)
    public static let blue400 = Color(hex: 0x8ACAFF)

    // MARK: - Semantic tokens (light / dark adaptive)

    /// Primary accent — Lava 600 light / Lava 500 dark.
    /// Use on Record CTA, primary buttons, active tab indicators.
    public static let accentPrimary = Color(light: lava600, dark: lava500)

    /// Surface backgrounds. "Primary" is the dominant fill behind
    /// the main content; "Secondary" is the recessed/inset fill
    /// (e.g., list-row backgrounds); "Raised" is the elevated fill
    /// (e.g., card backgrounds).
    public static let surfacePrimary = Color(light: white, dark: navy800)
    public static let surfaceSecondary = Color(light: oatLight, dark: navy900)
    public static let surfaceRaised = Color(light: white, dark: navy700)

    /// Text foreground tokens.
    public static let textPrimary = Color(light: navy800, dark: white)
    public static let textSecondary = Color(light: grayText, dark: navy400)
    public static let textMuted = Color(light: navy400, dark: navy400)
    /// Body links — chosen over `accentPrimary` for body text
    /// because Blue 600 on white is 5.1:1 (vs Lava 600's 3.6:1).
    public static let linkPrimary = Color(light: blue600, dark: blue400)

    /// Borders + dividers.
    public static let borderDefault = Color(light: grayLines, dark: navy600)

    // Status colors (light / dark per brand spec).
    public static let statusSuccess = Color(light: green700, dark: green600)
    public static let statusWarning = Color(light: yellow700, dark: yellow600)
    public static let statusError = Color(light: lava700, dark: lava500)
    public static let statusInfo = Color(light: blue600, dark: blue400)
}

// MARK: - Color extensions

extension Color {

    /// Construct a SwiftUI `Color` from a 24-bit RGB hex literal.
    ///
    /// `Color(hex: 0xFF3621)` is equivalent to
    /// `Color(red: 1.0, green: 0.212, blue: 0.129)`. The literal form
    /// keeps brand definitions readable and grep-able against the
    /// design source.
    public init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    /// Construct a SwiftUI `Color` that picks between `light` and
    /// `dark` based on the rendering trait collection. Backed by
    /// `UIColor { traits in ... }` so a single instance adapts at
    /// render time — no `@Environment(\.colorScheme)` plumbing needed
    /// at the call site.
    public init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            switch traits.userInterfaceStyle {
            case .dark:
                return UIColor(dark)
            case .light, .unspecified:
                return UIColor(light)
            @unknown default:
                return UIColor(light)
            }
        })
    }
}
