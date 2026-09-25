import XCTest

/// Remote-navigation regressions: focus lost after a page closes, a Back (Menu) press swallowed
/// or taken by the wrong layer, a screen that never appears. Offline fixture scenarios only
/// (`--fixtures shell|who`): no network, no account, no playback. Focus is only asserted where
/// the app places it itself (Home's first-focus seed, Search's keyboard seed, the Settings column's
/// Back, Who's watching's active-profile and PIN-pad returns); everything else is polled.
final class NavigationTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var remote: XCUIRemote { XCUIRemote.shared }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--fixtures", scenario]
        app.launch()
        return app
    }

    // MARK: helpers

    /// A failed check leaves a screenshot and the element tree behind, then stops the test.
    private func require(_ ok: Bool, _ message: @autoclosure () -> String, _ app: XCUIApplication) {
        guard !ok else { return }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "failure-screen"
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "failure-hierarchy"
        tree.lifetime = .keepAlways
        add(tree)
        XCTFail(message())
    }

    /// The identifier of the focused button, if one has focus.
    private func focusedId(_ app: XCUIApplication) -> String? {
        let f = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return f.exists ? f.identifier : nil
    }

    /// Polls until the focused button's identifier matches; returns it, or nil on timeout.
    @discardableResult
    private func waitForFocus(_ app: XCUIApplication, timeout: TimeInterval, where match: (String) -> Bool) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let id = focusedId(app), match(id) { return id }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return nil
    }

    /// Presses `button` until the focus matches (checked before the first press too).
    @discardableResult
    private func press(_ button: XCUIRemote.Button, _ app: XCUIApplication, max presses: Int, until match: (String) -> Bool) -> String? {
        if let id = waitForFocus(app, timeout: 1, where: match) { return id }
        for _ in 0..<presses {
            remote.press(button)
            if let id = waitForFocus(app, timeout: 1, where: match) { return id }
        }
        return nil
    }

    /// Walks a row (the top bar, Who's watching) to the element with `id`: one way first, then back
    /// the other, so neither the starting cell nor an overshoot matters.
    private func seek(_ id: String, _ app: XCUIApplication, max presses: Int = 25, first: XCUIRemote.Button = .right) -> Bool {
        let then: XCUIRemote.Button = first == .right ? .left : .right
        if press(first, app, max: presses, until: { $0 == id }) != nil { return true }
        return press(then, app, max: presses, until: { $0 == id }) != nil
    }

    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    private static func isHomeCard(_ id: String) -> Bool { id.hasPrefix("cw-") || id.hasPrefix("tile-") }
    private static func inBar(_ id: String) -> Bool { id.hasPrefix("tab-") || id == "profile-chip" || id == "account-menu" }

    /// Fixture Home is up and its first-focus seed (Continue Watching, else the first row) has landed.
    /// Waiting for the seed first keeps it from pulling the ring off the bar mid-walk.
    private func waitForHome(_ app: XCUIApplication) {
        require(app.buttons["tile-trending-0"].waitForExistence(timeout: 30), "fixture Home rows never appeared", app)
        let seeded = waitForFocus(app, timeout: 20, where: Self.isHomeCard)
        require(seeded != nil, "Home never seeded focus on a card (focus: \(focusedId(app) ?? "none"))", app)
    }

    /// Up from Home's cards until the ring is in the top bar.
    private func goToBar(_ app: XCUIApplication) {
        let at = press(.up, app, max: 5, until: Self.inBar)
        require(at != nil, "Up never reached the top bar (focus: \(focusedId(app) ?? "none"))", app)
    }

    // MARK: tests

    /// Home → a catalog tile → Detail → Menu closes Detail, and the ring is back on a Home card
    /// (not lost, not on the top bar).
    func testDetailBackKeepsHomeFocus() {
        let app = launch("shell")
        waitForHome(app)
        // Down from Jump back in to the first catalog row (the Live TV row is empty in fixtures).
        let tile = press(.down, app, max: 5, until: { $0.hasPrefix("tile-") })
        require(tile != nil, "Down never reached a catalog tile (focus: \(focusedId(app) ?? "none"))", app)
        remote.press(.select)
        let play = app.buttons["detail-play"]
        require(play.waitForExistence(timeout: 30), "Detail did not open from \(tile ?? "?")", app)
        sleep(2)
        remote.press(.menu)
        require(waitForGone(play, timeout: 15), "Menu did not close Detail", app)
        let back = waitForFocus(app, timeout: 15, where: Self.isHomeCard)
        require(back != nil, "after Detail closed the ring was not on a Home card (focus: \(focusedId(app) ?? "none"))", app)
        require(app.buttons["tab-home"].isSelected, "Menu on Detail left Home", app)
    }

    /// Settings: open a category, Menu steps back to the column with that category focused, and a
    /// second Menu is not swallowed there: it reaches the shell, which goes Home.
    func testSettingsBackSteps() {
        let app = launch("shell")
        waitForHome(app)
        goToBar(app)
        require(seek("tab-settings", app), "could not walk the top bar to the Settings cog (focus: \(focusedId(app) ?? "none"))", app)
        remote.press(.select)
        require(app.staticTexts["Settings"].waitForExistence(timeout: 15), "Settings did not open", app)
        let anyCategory = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings-cat-'")).firstMatch
        require(anyCategory.waitForExistence(timeout: 30), "the Settings category column never loaded", app)
        sleep(1)
        remote.press(.down)
        let category = waitForFocus(app, timeout: 10, where: { $0.hasPrefix("settings-cat-") })
        require(category != nil, "Down from the cog did not land in the category column (focus: \(focusedId(app) ?? "none"))", app)
        guard let category else { return }
        remote.press(.select)
        require(waitForGone(app.buttons[category], timeout: 10), "Select on \(category) did not open its controls", app)
        // The column moves the ring onto the first control once the rows are in.
        let inControls = waitForFocus(app, timeout: 10, where: { !Self.inBar($0) && !$0.hasPrefix("settings-cat-") })
        require(inControls != nil, "the ring did not enter \(category)'s controls (focus: \(focusedId(app) ?? "none"))", app)
        sleep(2)
        remote.press(.menu)
        require(app.buttons[category].waitForExistence(timeout: 10), "Menu in \(category) did not step back to the categories", app)
        let refocused = waitForFocus(app, timeout: 10, where: { $0 == category })
        require(refocused != nil, "Back did not return the ring to \(category) (focus: \(focusedId(app) ?? "none"))", app)
        require(app.staticTexts["Settings"].exists, "the first Menu left Settings", app)
        remote.press(.menu)
        require(waitForGone(app.staticTexts["Settings"], timeout: 15), "Menu at the category column was swallowed (still on Settings)", app)
        require(waitUntil(timeout: 15) { app.buttons["tab-home"].isSelected }, "Menu from Settings did not go Home", app)
        require(app.buttons["tile-trending-0"].waitForExistence(timeout: 30), "Home rows did not come back", app)
    }

    /// Who's watching at launch: the PIN pad's Menu closes it with the ring back on its tile, and
    /// picking a profile without a PIN lands in the shell.
    func testWhoPinBackAndPick() {
        let app = launch("who")
        require(app.buttons["who-tile-p_fix_2"].waitForExistence(timeout: 30), "Who's watching did not appear", app)
        require(waitForFocus(app, timeout: 10, where: { $0.hasPrefix("who-tile-") }) != nil, "no profile tile took focus", app)
        require(seek("who-tile-p_fix_2", app, max: 4), "could not reach the PIN profile tile (focus: \(focusedId(app) ?? "none"))", app)
        remote.press(.select)
        let key = app.buttons["pin-key-1"]
        require(key.waitForExistence(timeout: 10), "the PIN pad did not open", app)
        // The pad's own Back handler needs the ring on one of its keys (the faces behind are disabled).
        require(waitForFocus(app, timeout: 10, where: { $0.hasPrefix("pin-key-") }) != nil, "the PIN pad did not take the ring (focus: \(focusedId(app) ?? "none"))", app)
        remote.press(.menu)
        require(waitForGone(key, timeout: 10), "Menu did not close the PIN pad", app)
        let back = waitForFocus(app, timeout: 10, where: { $0 == "who-tile-p_fix_2" })
        require(back != nil, "closing the PIN pad did not return the ring to its tile (focus: \(focusedId(app) ?? "none"))", app)
        require(seek("who-tile-p_fix_1", app, max: 4, first: .left), "could not reach the first profile tile (focus: \(focusedId(app) ?? "none"))", app)
        remote.press(.select)
        require(app.buttons["tab-home"].waitForExistence(timeout: 30), "picking a profile did not open the shell", app)
        require(waitForGone(app.buttons["who-tile-p_fix_1"], timeout: 10), "Who's watching stayed up after a pick", app)
    }

    /// The top bar's profile chip opens Who's watching on the active profile, and Menu closes it
    /// back to the shell (a profile is active, so Back is not left to the system).
    func testProfileChipWhoBack() {
        let app = launch("shell")
        waitForHome(app)
        goToBar(app)
        require(seek("profile-chip", app), "could not walk the top bar to the profile chip (focus: \(focusedId(app) ?? "none"))", app)
        remote.press(.select)
        let active = app.buttons["who-tile-p_fix_1"]
        require(active.waitForExistence(timeout: 15), "the profile chip did not open Who's watching", app)
        let ring = waitForFocus(app, timeout: 10, where: { $0 == "who-tile-p_fix_1" })
        require(ring != nil, "Who's watching did not open on the active profile (focus: \(focusedId(app) ?? "none"))", app)
        remote.press(.menu)
        require(waitForGone(active, timeout: 10), "Menu on Who's watching was swallowed", app)
        require(app.buttons["tab-home"].waitForExistence(timeout: 30), "Menu on Who's watching did not return to the shell", app)
        require(waitUntil(timeout: 15) { app.buttons["tab-home"].isSelected }, "the shell came back on another room", app)
    }

    /// Search opens with the ring on the on-screen keyboard, and a key pressed there shows in the query.
    func testSearchKeyTypesIntoQuery() {
        let app = launch("shell")
        waitForHome(app)
        goToBar(app)
        require(seek("tab-search", app), "could not walk the top bar to Search (focus: \(focusedId(app) ?? "none"))", app)
        remote.press(.select)
        require(app.buttons["key-q"].waitForExistence(timeout: 20), "the Search keyboard did not appear", app)
        // Search seeds the ring on the keyboard's first key.
        require(waitForFocus(app, timeout: 10, where: { $0 == "key-1" }) != nil, "Search did not put the ring on the keyboard (focus: \(focusedId(app) ?? "none"))", app)
        // Down to the letter row; whichever single-character key takes the ring is typed.
        remote.press(.down)
        let key = waitForFocus(app, timeout: 5, where: { $0.hasPrefix("key-") && $0.count == 5 && $0 != "key-1" })
        require(key != nil, "Down on the keyboard left the keys (focus: \(focusedId(app) ?? "none"))", app)
        guard let key else { return }
        let ch = String(key.suffix(1))
        remote.press(.select)
        // The query line is a TextField (the TV keyboard and dictation type into it): its value is the query.
        let fields = app.descendants(matching: .any).matching(identifier: "search-query")
        require(fields.firstMatch.waitForExistence(timeout: 5), "the query field is missing", app)
        let typed = waitUntil(timeout: 10) {
            // Exactly the one key: an empty field reads as its placeholder ("Search Harbor").
            fields.allElementsBoundByIndex.contains { ($0.value as? String) == ch }
        }
        let values = fields.allElementsBoundByIndex.map { String(describing: $0.value) }
        require(typed, "the query did not show \"\(ch)\" (values: \(values))", app)
    }
}
