import XCTest

final class ScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--fixtures", scenario]
        app.launch()
        return app
    }

    func testOnboarding() {
        let app = launch("onboarding")
        XCTAssertTrue(app.staticTexts["Choose your language"].waitForExistence(timeout: 30))
        capture("10-onboarding-language")
        XCUIRemote.shared.press(.select)
        sleep(1)
        capture("11-onboarding-stremio")
    }

    func testWhoIsWatching() {
        let app = launch("who")
        XCTAssertTrue(app.buttons["who-tile-p_fix_1"].waitForExistence(timeout: 30))
        capture("12-who-is-watching")
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["pin-key-1"].waitForExistence(timeout: 10))
        capture("13-pin-pad")
    }

    func testShell() {
        let app = launch("shell")
        XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 30))
        capture("14-shell-home")
        XCUIRemote.shared.press(.up)
        for _ in 0..<12 { XCUIRemote.shared.press(.right) }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 10))
        sleep(1)
        capture("15-settings")
    }

    func testSpikesStillPass() {
        let app = launch("shell")
        XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 30))
        XCUIRemote.shared.press(.up)
        for _ in 0..<12 { XCUIRemote.shared.press(.right) }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["Stage 0 spikes"].waitForExistence(timeout: 10))
        // Reach the Developer button, open spikes, run Engine.
        for _ in 0..<8 { XCUIRemote.shared.press(.down) }
        if app.buttons["Stage 0 spikes"].hasFocus == false {
            for _ in 0..<4 { XCUIRemote.shared.press(.down) }
        }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["spike-engine"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["spike-status"].waitForExistence(timeout: 60))
        capture("16-engine-spike")
        XCTAssertEqual(app.staticTexts["spike-status"].label, "PASS")
    }
}
