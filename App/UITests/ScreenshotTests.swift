import XCTest

final class ScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func dump(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(string: app.debugDescription)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
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
        let app = launch("spikes")
        XCTAssertTrue(app.buttons["spike-engine"].waitForExistence(timeout: 30))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["spike-status"].waitForExistence(timeout: 60))
        capture("16-engine-spike")
        XCTAssertEqual(app.staticTexts["spike-status"].label, "PASS")
    }

    func testTabHint() {
        let app = launch("shell")
        XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 30))
        sleep(1)
        dump(app, "hierarchy-shell-initial")
        XCUIRemote.shared.press(.up)
        XCUIRemote.shared.press(.right)
        sleep(1)
        capture("17-tab-focus-discover")
        dump(app, "hierarchy-shell-after-right")
        XCTAssertTrue(app.staticTexts["Discover"].exists)
    }
}
