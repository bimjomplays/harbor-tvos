import XCTest

final class ScreenshotTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testHello() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["build-label"].waitForExistence(timeout: 20))
        capture("01-hello")
    }
}
