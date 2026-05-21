import SwiftUI

/// Lakeloom typography tokens.
///
/// Per Genie's 2026-05-15 brand guidelines: DM Sans for UI text,
/// DM Mono for code, three weights (Regular 400 / Medium 500 /
/// Bold 700), and a fixed type scale.
///
/// **Font choice:** the brand spec accepts either bundled DM Sans /
/// DM Mono or `.system` with matching weights. Lakeloom v1 ships
/// with `.system` to avoid the font-bundle + licensing-overhead
/// path; the iOS HIG also nudges toward SF Pro for native-feeling
/// chrome. If we later bundle DM Sans, swapping it in is a
/// single-place change inside the `Font.brand(...)` helpers.
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
    public static let monospaceCode = Font.system(.footnote, design: .monospaced)
}

extension Font {

    /// Construct a brand font for an explicit `Size` + `Weight`.
    ///
    /// Wraps `Font.system(size:weight:design:)` today; the design
    /// argument is `.default`, which resolves to SF Pro on iOS. When
    /// we later bundle DM Sans / DM Mono, this is the one place that
    /// changes — every `BrandTypography` token flows through here.
    public static func brand(
        _ size: BrandTypography.Size,
        weight: BrandTypography.Weight = .regular
    ) -> Font {
        Font.system(size: size.rawValue, weight: weight.swiftUI, design: .default)
    }
}
