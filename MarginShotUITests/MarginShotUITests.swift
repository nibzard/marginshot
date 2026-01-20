import XCTest

final class MarginShotUITests: XCTestCase {
    func testOnboardingAppearsOnFreshLaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome to MarginShot"].waitForExistence(timeout: 5))
        app.buttons["Get Started"].tap()
        XCTAssertTrue(app.staticTexts["Enable Access"].waitForExistence(timeout: 2))
    }
}
