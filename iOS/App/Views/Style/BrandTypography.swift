import SwiftUI

/// Lakeloom typography tokens.
///
/// Per Genie's 2026-05-15 brand guidelines: DM Sans for UI text,
/// DM Mono for code, three weights (Regular 400 / Medium 500 /
/// Bold 700), and a fixed type scale.
///
/// **Font source:** static TTFs vendored under
/// `App/Resources/Fonts/` and registered via `UIAppFonts`. PostScript
/// names — `DMSans-Regular`, `DMSans-Medium`, `DMSans-Bold`,
/// `DMMono-Regular`, `DMMono-Medium` — are resolved by `Font.custom`.
/// Both families are SIL Open Font License 1.1; see the GoogleFonts
/// `dm-fonts` + `dm-mono` repos for upstream sources.
///
/// `Font.brand(_:weight:)` falls back to `Font.system(...)` when a
/// requested weight isn't bundled (e.g., a heavier weight added later
/// to the scale) — the app keeps rendering with the system font for
/// that one role instead of refusing to draw text.
///
/// Usage:
/// ```
/// Text("Record").font(.brand(.bodyLarge, weight: .bold))
/// Text("FE-VM HLS FDE").font(BrandTypography.titleMedium)
/// ```
public enum BrandTypography {

    /// Type scale (in points) per Genie's brand spec.
    public enum Size: CGFloat {
        case xs = 10
        case sm = 12
        /// Default base size for captions, dense table rows.
        case base = 14
        /// Default body size.
        case body = 16
        /// Section headings, large emphasized text.
        case bodyLarge = 20
        /// H3 / "card title".
        case titleSmall = 24
        /// H2 / "screen title".
        case titleMedium = 32
        /// H1 / "page hero".
        case titleLarge = 40
        /// "Display" sizes — landing screens, big numbers.
        case display = 48
        case displayLarge = 56
    }

    /// Brand weights — Regular 400 / Medium 500 / Bold 700.
    public enum Weight {
        case regular, medium, bold

        var swiftUI: Font.Weight {
            switch self {
            case .regular: return .regular
            case .medium:  return .medium
            case .bold:    return .bold
            }
        }
    }

    // MARK: - Convenience role tokens

    /// 14 pt regular — captions, secondary metadata.
    public static let caption = Font.brand(.base, weight: .regular)
    /// 14 pt medium — emphasized captions, form labels.
    public static let captionMedium = Font.brand(.base, weight: .medium)

    /// 16 pt regular — body text.
    public static let body = Font.brand(.body, weight: .regular)
    /// 16 pt medium — emphasized body, button labels.
    public static let bodyEmphasis = Font.brand(.body, weight: .medium)
    /// 20 pt regular — large body, list-row titles.
    public static let bodyLarge = Font.brand(.bodyLarge, weight: .regular)

    /// 24 pt bold — small section titles (card headers).
    public static let titleSmall = Font.brand(.titleSmall, weight: .bold)
    /// 32 pt bold — screen titles.
    public static let titleMedium = Font.brand(.titleMedium, weight: .bold)
    /// 40 pt bold — primary screen heroes.
    public static let titleLarge = Font.brand(.titleLarge, weight: .bold)

    /// Monospaced footnote — for code / identifiers / hashes.
    /// DM Mono Regular at 12 pt (matches `.footnote`'s point size on
    /// the default text style table).
    public static let monospaceCode = Font.custom("DMMono-Regular", size: Size.sm.rawValue)

    /// Monospaced footnote, medium weight — for emphasized
    /// inline identifiers (active session ID, current sha prefix).
    public static let monospaceCodeEmphasis = Font.custom("DMMono-Medium", size: Size.sm.rawValue)
}

extension Font {

    /// Construct a brand font for an explicit `Size` + `Weight`.
    ///
    /// Maps the brand `Weight` to the matching DM Sans PostScript
    /// face. If the bundled font isn't registered (e.g., test bundle
    /// running against the unit-test target which doesn't copy
    /// resources), `Font.custom` falls back to the system font at the
    /// requested size — the app still renders, just in SF Pro.
    public static func brand(
        _ size: BrandTypography.Size,
        weight: BrandTypography.Weight = .regular
    ) -> Font {
        Font.custom(weight.dmSansPostScriptName, size: size.rawValue)
    }
}

extension BrandTypography.Weight {

    /// PostScript name of the DM Sans face that backs this weight.
    /// The TTF files are bundled under `App/Resources/Fonts/` and
    /// registered through the target's `UIAppFonts` build setting.
    fileprivate var dmSansPostScriptName: String {
        switch self {
        case .regular: return "DMSans-Regular"
        case .medium:  return "DMSans-Medium"
        case .bold:    return "DMSans-Bold"
        }
    }
}
