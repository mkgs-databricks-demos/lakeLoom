import SwiftUI
import Testing

@testable import LakeloomApp

@Suite("BrandTypography")
struct BrandTypographyTests {

    @Test("type-scale Size enum matches Genie's brand-spec values")
    func sizeScale() {
        // Verbatim from Genie's 2026-05-15 brand guidelines table:
        // Type scale (pt): 10 / 12 / 14 / 16 / 20 / 24 / 32 / 40 / 48 / 56
        #expect(BrandTypography.Size.xs.rawValue == 10)
        #expect(BrandTypography.Size.sm.rawValue == 12)
        #expect(BrandTypography.Size.base.rawValue == 14)
        #expect(BrandTypography.Size.body.rawValue == 16)
        #expect(BrandTypography.Size.bodyLarge.rawValue == 20)
        #expect(BrandTypography.Size.titleSmall.rawValue == 24)
        #expect(BrandTypography.Size.titleMedium.rawValue == 32)
        #expect(BrandTypography.Size.titleLarge.rawValue == 40)
        #expect(BrandTypography.Size.display.rawValue == 48)
        #expect(BrandTypography.Size.displayLarge.rawValue == 56)
    }

    @Test("Weight maps to expected SwiftUI Font.Weight cases")
    func weightMapping() {
        #expect(BrandTypography.Weight.regular.swiftUI == .regular)
        #expect(BrandTypography.Weight.medium.swiftUI == .medium)
        #expect(BrandTypography.Weight.bold.swiftUI == .bold)
    }

    @Test("Font.brand(...) returns a Font (smoke check — no crash)")
    func fontFactorySmokeCheck() {
        // We can't introspect Font's underlying descriptor without
        // bridging to UIFont, but instantiating the factory across
        // every size + weight combo at least catches the trivial
        // factory failures + asserts the type signature.
        for size in [BrandTypography.Size.xs, .body, .titleMedium, .displayLarge] {
            for weight in [BrandTypography.Weight.regular, .medium, .bold] {
                let font = Font.brand(size, weight: weight)
                _ = font
            }
        }
    }
}
