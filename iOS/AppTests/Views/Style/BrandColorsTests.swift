import SwiftUI
import Testing
import UIKit

@testable import LakeloomApp

@Suite("BrandColors")
struct BrandColorsTests {

    @Test("Color(hex:) parses 24-bit RGB literals correctly")
    func hexInit() {
        // Lava 600 → red dominant, near-zero blue.
        let lava = Color(hex: 0xFF3621)
        let lavaComponents = UIColor(lava).cgColor.components ?? []
        #expect(lavaComponents.count >= 3)
        #expect(abs(Double(lavaComponents[0]) - 1.0) < 0.005)        // R = 255 → 1.0
        #expect(abs(Double(lavaComponents[1]) - (54.0 / 255)) < 0.01) // G = 0x36 = 54
        #expect(abs(Double(lavaComponents[2]) - (33.0 / 255)) < 0.01) // B = 0x21 = 33
    }

    @Test("Color(hex:) handles black + white edge cases")
    func hexInitExtremes() {
        let black = Color(hex: 0x000000)
        let white = Color(hex: 0xFFFFFF)
        let blackComponents = UIColor(black).cgColor.components ?? []
        let whiteComponents = UIColor(white).cgColor.components ?? []
        #expect(Double(blackComponents[0]) == 0.0)
        #expect(Double(blackComponents[1]) == 0.0)
        #expect(Double(blackComponents[2]) == 0.0)
        #expect(Double(whiteComponents[0]) == 1.0)
        #expect(Double(whiteComponents[1]) == 1.0)
        #expect(Double(whiteComponents[2]) == 1.0)
    }

    @Test("Color(light:dark:) picks light in .light trait collection")
    func lightDarkTraitLight() {
        // Use explicit sRGB to avoid SwiftUI's named colors which
        // are system-defined dynamic shades that don't match pure
        // (1,0,0) / (0,0,1).
        let pureRed = Color(.sRGB, red: 1, green: 0, blue: 0)
        let pureBlue = Color(.sRGB, red: 0, green: 0, blue: 1)
        let token = Color(light: pureRed, dark: pureBlue)
        let resolved = UIColor(token).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .light)
        )
        let components = resolved.cgColor.components ?? []
        #expect(components.count >= 3)
        #expect(Double(components[0]) > 0.95)
        #expect(Double(components[1]) < 0.05)
        #expect(Double(components[2]) < 0.05)
    }

    @Test("Color(light:dark:) picks dark in .dark trait collection")
    func lightDarkTraitDark() {
        let pureRed = Color(.sRGB, red: 1, green: 0, blue: 0)
        let pureBlue = Color(.sRGB, red: 0, green: 0, blue: 1)
        let token = Color(light: pureRed, dark: pureBlue)
        let resolved = UIColor(token).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .dark)
        )
        let components = resolved.cgColor.components ?? []
        #expect(components.count >= 3)
        #expect(Double(components[0]) < 0.05)
        #expect(Double(components[1]) < 0.05)
        #expect(Double(components[2]) > 0.95)
    }

    @Test("Palette values match Genie's brand-spec hex literals")
    func paletteValues() {
        // Smoke-check a representative sample. The init-from-hex
        // path is tested above; here we're just making sure the
        // exposed properties point at the right numeric values.
        let lava = UIColor(BrandColors.lava600).cgColor.components ?? []
        let navy = UIColor(BrandColors.navy800).cgColor.components ?? []
        let oat = UIColor(BrandColors.oatLight).cgColor.components ?? []
        // Lava 600 = #FF3621
        #expect(abs(Double(lava[0]) - 1.0) < 0.005)
        // Navy 800 = #1B3139 → R = 0x1B = 27
        #expect(abs(Double(navy[0]) - (27.0 / 255)) < 0.01)
        // Oat Light = #F9F7F4 → R = 0xF9 = 249
        #expect(abs(Double(oat[0]) - (249.0 / 255)) < 0.01)
    }
}
