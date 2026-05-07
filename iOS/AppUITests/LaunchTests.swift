import XCTest

/// XCUITest smoke check — verifies the app launches and lands on the
/// onboarding consent screen (the expected first-launch state with no
/// prior workspace credentials).
final class LaunchTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppLaunchesAndReachesConsentStep() throws {
        let app = XCUIApplication()
        app.launch()

        // Module 05 routes a fresh install through coldStart →
        // recovering → onboarding(.consent). We assert on the consent
        // step's headline, which is the first user-visible screen.
        let consentHeadline = app.staticTexts["Capture conversations to build with Databricks"]
        XCTAssertTrue(consentHeadline.waitForExistence(timeout: 10))

        let understandButton = app.buttons["I understand"]
        XCTAssertTrue(understandButton.exists)
    }
}
