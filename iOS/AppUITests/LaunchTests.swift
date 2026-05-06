import XCTest

/// XCUITest smoke check — verifies the app launches and the splash brand-mark
/// is visible. Once Module 05 (AppCoordinator) lands, this expands to cover
/// the onboarding happy path.
final class LaunchTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppLaunchesAndShowsBrandMark() throws {
        let app = XCUIApplication()
        app.launch()

        // The splash view combines its children into a single accessibility
        // element with this label (see SplashView). The launch is successful
        // if the element is reachable within the default timeout.
        let splash = app.staticTexts["lakeLoom. Weave requirements into rapid Databricks MVPs."]
        XCTAssertTrue(splash.waitForExistence(timeout: 10))
    }
}
