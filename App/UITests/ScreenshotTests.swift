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

    private func status(_ app: XCUIApplication) -> String {
        XCTAssertTrue(app.staticTexts["spike-status"].waitForExistence(timeout: 60))
        return app.staticTexts["spike-status"].label
    }

    func testMenu() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["build-label"].waitForExistence(timeout: 20))
        capture("01-menu")
    }

    func testEngineSpike() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["spike-engine"].waitForExistence(timeout: 20))
        XCUIRemote.shared.press(.select)
        let result = status(app)
        capture("02-engine")
        XCTAssertEqual(result, "PASS")
    }

    func testRustSpike() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["spike-rust"].waitForExistence(timeout: 20))
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        let result = status(app)
        capture("03-rust")
        XCTAssertEqual(result, "PASS")
    }

    func testPlayerSpikeMenu() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["spike-player"].waitForExistence(timeout: 20))
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Player · mpv test clips"].waitForExistence(timeout: 20))
        capture("04-player-menu")
        XCUIRemote.shared.press(.select)
        sleep(12)
        capture("05-player-h265")
    }
}
