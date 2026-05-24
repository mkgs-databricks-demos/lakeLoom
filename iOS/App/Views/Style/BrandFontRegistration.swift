import CoreText
import Foundation

/// Registers Lakeloom's bundled DM Sans + DM Mono faces with the
/// process's font manager at app launch.
///
/// Apple's `INFOPLIST_KEY_UIAppFonts` build setting is not on the
/// auto-mapped allow-list that Xcode's `GENERATE_INFOPLIST_FILE`
/// honors, so a value set there silently drops on the floor. Rather
/// than wedging in an explicit Info.plist file just to carry one
/// array, we register the bundled TTFs at runtime through CoreText —
/// it's deterministic, surfaces registration failures in logs, and
/// works identically in the test bundle.
///
/// Call once from `LakeloomApp.init()`, before any SwiftUI view that
/// uses `Font.custom(...)` renders.
enum BrandFontRegistration {

    /// PostScript names of every face bundled under
    /// `App/Resources/Fonts/`. Kept in sync with
    /// ``BrandTypography``'s `Font.custom(...)` lookups — if you add
    /// a face to one place, add it to the other.
    private static let bundledFaces = [
        "DMSans-Regular",
        "DMSans-Medium",
        "DMSans-Bold",
        "DMMono-Regular",
        "DMMono-Medium"
    ]

    /// Register every bundled face with the per-process font scope.
    /// Idempotent — a second call returns `false` for each face
    /// (already-registered) but doesn't tear anything down.
    static func registerAll() {
        for name in bundledFaces {
            register(postscriptName: name)
        }
    }

    private static func register(postscriptName: String) {
        guard let url = Bundle.main.url(forResource: postscriptName, withExtension: "ttf") else {
            // Don't crash — a missing font means the relevant
            // `Font.custom` call will fall back to `Font.system`,
            // and the app still renders.
            NSLog("[brand] font missing from bundle: \(postscriptName).ttf")
            return
        }
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if !ok, let err = error?.takeRetainedValue() {
            let code = CFErrorGetCode(err)
            // 105 = kCTFontManagerErrorAlreadyRegistered. Treat
            // re-registration as benign; everything else logs so a
            // demo doesn't quietly fall back to SF Pro.
            if code != 105 {
                NSLog("[brand] font register failed: \(postscriptName) (code=\(code))")
            }
        }
    }
}
