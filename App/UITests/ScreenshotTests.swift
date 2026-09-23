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
        // Down from the cog must reach the settings buttons.
        XCUIRemote.shared.press(.down)
        sleep(1)
        let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        XCTAssertTrue(focused.exists && !focused.identifier.hasPrefix("tab-"), "Down from Settings cog did not enter the room (focus: \(focused.identifier) \(focused.label))")
        capture("15b-settings-focus")
        dump(app, "hierarchy-settings-down")
        // And Up must return to the top bar.
        XCUIRemote.shared.press(.up)
        sleep(1)
        let back = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        dump(app, "hierarchy-settings-up")
        XCTAssertTrue(back.exists && back.identifier.hasPrefix("tab-"), "Up from the settings panel did not reach the top bar (focus: \(back.identifier) \(back.label))")
    }

    func testHomeRail() {
        let app = launch("shell")
        XCTAssertTrue(app.buttons["tile-trending-0"].waitForExistence(timeout: 30))
        sleep(1)
        capture("18-home-rail")
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.down)
        sleep(1)
        capture("19-home-rail-second-row")
        dump(app, "hierarchy-home")
    }

    func testMoviesRoom() {
        let app = launch("shell")
        XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 30))
        XCUIRemote.shared.press(.up)
        // From wherever Up landed, walk left until Home, then right to Movies.
        for _ in 0..<10 { XCUIRemote.shared.press(.left) }
        for _ in 0..<4 { XCUIRemote.shared.press(.right) }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["tile-bp-top10-0"].waitForExistence(timeout: 30))
        XCUIRemote.shared.press(.down)
        sleep(1)
        capture("20-movies-top10")
    }

    func testLiveHome() {
        let app = launch("live")
        XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 30))
        // Real Cinemeta rows through the engine; first tile of the first live row.
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tile-'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 90), "no live rows arrived")
        sleep(3)
        capture("21-live-home")
        dump(app, "hierarchy-live-home")
    }

    func testSearchRoom() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixtures", "live", "--query", "dune"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 30))
        XCUIRemote.shared.press(.up)
        for _ in 0..<10 { XCUIRemote.shared.press(.left) }
        for _ in 0..<7 { XCUIRemote.shared.press(.right) }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["key-q"].waitForExistence(timeout: 20))
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tile-'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 60), "no search results for dune")
        sleep(2)
        capture("22-search-dune")
        dump(app, "hierarchy-search")
    }

    func testDiscoverRoom() {
        let app = launch("live")
        XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 30))
        XCUIRemote.shared.press(.up)
        for _ in 0..<10 { XCUIRemote.shared.press(.left) }
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["queue-band"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.buttons["genre-Action"].waitForExistence(timeout: 30))
        sleep(2)
        capture("24-discover")
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        sleep(2)
        capture("25-discover-rails")
        dump(app, "hierarchy-discover")
    }

    func testDetailAndPicker() {
        let app = launch("live")
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tile-'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 90))
        sleep(2)
        dump(app, "hierarchy-before-select")
        XCUIRemote.shared.press(.select)
        sleep(4)
        capture("26-detail")
        dump(app, "hierarchy-after-select")
        XCTAssertTrue(app.buttons["detail-play"].waitForExistence(timeout: 30), "detail page did not open; state: \(app.state.rawValue)")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Play"].waitForExistence(timeout: 20))
        sleep(6)
        capture("27-play-picker")
        dump(app, "hierarchy-picker")
    }

    func testSpikesStillPass() {
        let app = launch("spikes")
        XCTAssertTrue(app.buttons["spike-engine"].waitForExistence(timeout: 30))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["spike-status"].waitForExistence(timeout: 60))
        capture("16-engine-spike")
        XCTAssertEqual(app.staticTexts["spike-status"].label, "PASS")
    }

    func testEngineHostSpike() {
        let app = launch("spikes")
        XCTAssertTrue(app.buttons["spike-host"].waitForExistence(timeout: 30))
        for _ in 0..<4 { XCUIRemote.shared.press(.right) }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["spike-status"].waitForExistence(timeout: 120))
        capture("23-engine-host")
        dump(app, "hierarchy-engine-host")
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
        capture("17-tab-focus-hint")
        let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        XCTAssertTrue(focused.exists)
        XCTAssertTrue(focused.identifier.hasPrefix("tab-"), "focus should be in the top bar, was \(focused.identifier)")
        XCTAssertTrue(app.staticTexts[focused.label].exists, "hint label for \(focused.label) missing")
    }
}
