import XCTest

/// Remote-navigation checks, second batch: flows changed on 2026-09-25 that NavigationTests does
/// not drive. Offline fixture scenarios only (`--fixtures shell|who|roomfail`): Settings' Startup &
/// default rows, a Home row's See all edge, the PIN pad's cool-down, the kids shell's parent PIN and
/// a failed room's Try again. Focus is only asserted where the app places it itself; everything
/// else is polled, with the same helpers and waits as NavigationTests.
final class NavigationTests2: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var remote: XCUIRemote { XCUIRemote.shared }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--fixtures", scenario]
        app.launch()
        return app
    }

    // MARK: helpers (as NavigationTests)

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

    private func focusNote(_ app: XCUIApplication) -> String { focusedId(app) ?? "none" }

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

    /// `press` for a long walk down a page: the same checks, a shorter wait after each press.
    @discardableResult
    private func walk(_ button: XCUIRemote.Button, _ app: XCUIApplication, max presses: Int, until match: (String) -> Bool) -> String? {
        if let id = waitForFocus(app, timeout: 1, where: match) { return id }
        for _ in 0..<presses {
            remote.press(button)
            if let id = waitForFocus(app, timeout: 0.5, where: match) { return id }
        }
        return nil
    }

    /// Walks a row to the element with `id`: one way first, then back the other, so neither the
    /// starting cell nor an overshoot matters.
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

    /// Watches the ring for `seconds`: the first other button that took it, or nil if none did.
    private func focusLeft(_ app: XCUIApplication, from id: String, within seconds: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let now = focusedId(app), now != id { return now }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return nil
    }

    private static func isHomeCard(_ id: String) -> Bool { id.hasPrefix("cw-") || id.hasPrefix("tile-") }
    private static func inBar(_ id: String) -> Bool { id.hasPrefix("tab-") || id == "profile-chip" || id == "account-menu" }
    private static func inKidsBar(_ id: String) -> Bool { id == "tab-kids" || id == "tab-kids-play" || id == "profile-chip" }

    /// Fixture Home is up and its first-focus seed (Continue Watching, else the first row) has landed.
    private func waitForHome(_ app: XCUIApplication) {
        require(app.buttons["tile-trending-0"].waitForExistence(timeout: 30), "fixture Home rows never appeared", app)
        let seeded = waitForFocus(app, timeout: 20, where: Self.isHomeCard)
        require(seeded != nil, "Home never seeded focus on a card (focus: \(focusNote(app)))", app)
    }

    /// Up from Home's cards until the ring is in the top bar.
    private func goToBar(_ app: XCUIApplication) {
        let at = press(.up, app, max: 5, until: Self.inBar)
        require(at != nil, "Up never reached the top bar (focus: \(focusNote(app)))", app)
    }

    /// The kids page builds through the engine; once its hero lands it pulls the ring onto the hero
    /// (KidsView requestDefault). Wait for that (or its failure card) so the pull cannot land mid-test.
    private func waitForKidsPage(_ app: XCUIApplication) {
        let hero = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'kids-hero-'")).firstMatch
        let retry = app.buttons["kids-try-again"]
        _ = waitUntil(timeout: 60) { hero.exists || retry.exists }
        sleep(2)
    }

    // MARK: tests

    /// Settings → Startup & default (the fixtures have three profiles): Down from the category
    /// column reaches the "Who's watching" pills; Select moves the selected pill and the ring stays
    /// on it; the old value goes back the same way; Down reaches "Start as", which offers no PIN
    /// profile and has one choice selected; Menu there is not swallowed and goes Home.
    func testStartupDefaultsPills() {
        let app = launch("shell")
        waitForHome(app)
        goToBar(app)
        require(seek("tab-settings", app), "could not walk the top bar to the Settings cog (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(app.staticTexts["Settings"].waitForExistence(timeout: 15), "Settings did not open", app)
        let anyCategory = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings-cat-'")).firstMatch
        require(anyCategory.waitForExistence(timeout: 30), "the Settings category column never loaded", app)
        sleep(1)
        // The section sits near the end of the page, under every panel: walk Down to it (and back
        // Up a little if the walk went past it).
        let isPill: (String) -> Bool = { $0.hasPrefix("startup-interval-") }
        let pill = walk(.down, app, max: 160, until: isPill) ?? press(.up, app, max: 8, until: isPill)
        let listed = app.buttons["startup-interval-launch"].exists
        require(pill != nil, "Down never reached the Startup & default pills (focus: \(focusNote(app)), pills in tree: \(listed))", app)
        let values = ["launch", "15m", "30m", "never"]
        let current = values.first { app.buttons["startup-interval-\($0)"].isSelected }
        require(current != nil, "no Who's watching pill reads as selected", app)
        guard let current else { return }
        let target = current == "15m" ? "30m" : "15m"
        let targetId = "startup-interval-\(target)"
        let currentId = "startup-interval-\(current)"
        require(seek(targetId, app, max: 5), "could not walk the pills to \(target) (focus: \(focusNote(app)))", app)
        remote.press(.select)
        let moved = waitUntil(timeout: 15) { app.buttons[targetId].isSelected && !app.buttons[currentId].isSelected }
        require(moved, "Select on \(target) did not move the selected pill from \(current)", app)
        require(waitForFocus(app, timeout: 5, where: { $0 == targetId }) != nil, "the ring left the pill it picked (focus: \(focusNote(app)))", app)
        // The old value back, so the fixture profile's settings end as they started.
        require(seek(currentId, app, max: 5), "could not walk the pills back to \(current) (focus: \(focusNote(app)))", app)
        remote.press(.select)
        let restored = waitUntil(timeout: 15) { app.buttons[currentId].isSelected && !app.buttons[targetId].isSelected }
        require(restored, "Select on \(current) did not select it again", app)
        let choice = press(.down, app, max: 3, until: { $0.hasPrefix("startup-default-") })
        require(choice != nil, "Down from the pills did not reach the Start as row (focus: \(focusNote(app)))", app)
        // startup-defaults.tsx: profiles with a PIN cannot be a default.
        require(!app.buttons["startup-default-p_fix_2"].exists, "Start as offers the PIN profile", app)
        let selected = ["none", "p_fix_1", "p_fix_3"].filter { app.buttons["startup-default-\($0)"].isSelected }
        require(selected.count == 1, "Start as should have exactly one selected choice (selected: \(selected))", app)
        sleep(1)
        remote.press(.menu)
        require(waitForGone(app.staticTexts["Settings"], timeout: 15), "Menu in Startup & default was swallowed (still on Settings)", app)
        require(waitUntil(timeout: 15) { app.buttons["tab-home"].isSelected }, "Menu from Startup & default did not go Home", app)
    }

    /// A Home row's edges: Right off its last tile puts the ring on the row's own See all and it
    /// stays there (only that row shows a See all, so the row still holds the ring), and Left from
    /// See all returns to that last tile, not whatever tvOS finds nearest. Twice.
    func testRowSeeAllEdge() {
        let app = launch("shell")
        waitForHome(app)
        // Down from Jump back in to the first catalog row (the Live TV row is empty in fixtures).
        let tile = press(.down, app, max: 5, until: { $0.hasPrefix("tile-") })
        require(tile != nil, "Down never reached a catalog tile (focus: \(focusNote(app)))", app)
        guard let tile else { return }
        // "tile-<row>-<index>"; FixtureBrowseSource's Home rows hold 12 titles.
        let body = tile.dropFirst("tile-".count)
        let dash = body.lastIndex(of: "-")
        require(dash != nil, "unexpected tile identifier \(tile)", app)
        guard let dash else { return }
        let row = String(body[..<dash])
        let last = "tile-\(row)-11"
        let seeAll = "seeall-\(row)"
        require(press(.right, app, max: 14, until: { $0 == last }) != nil, "Right never reached \(last) (focus: \(focusNote(app)))", app)
        for round in 1...2 {
            sleep(1)
            remote.press(.right)
            require(waitForFocus(app, timeout: 5, where: { $0 == seeAll }) != nil, "round \(round): Right off \(last) did not reach \(seeAll) (focus: \(focusNote(app)))", app)
            let strayed = focusLeft(app, from: seeAll, within: 2)
            require(strayed == nil, "round \(round): the ring left \(seeAll) on its own (focus: \(strayed ?? "none"))", app)
            let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'seeall-'")).allElementsBoundByIndex.map(\.identifier)
            require(chips == [seeAll], "round \(round): with the ring on See all the row should be the only one showing a See all (shown: \(chips))", app)
            remote.press(.left)
            require(waitForFocus(app, timeout: 5, where: { $0 == last }) != nil, "round \(round): Left from \(seeAll) did not return to \(last) (focus: \(focusNote(app)))", app)
        }
    }

    /// Who's watching's PIN pad: three wrong PINs start the cool-down and put the ring on Back (the
    /// digit under it is disabled); Back closes the pad onto its tile; opened again inside the
    /// cool-down it starts on Back, and when the cool-down ends the ring goes to 1.
    func testPinCooldownRing() {
        let app = launch("who")
        require(app.buttons["who-tile-p_fix_2"].waitForExistence(timeout: 30), "Who's watching did not appear", app)
        require(waitForFocus(app, timeout: 10, where: { $0.hasPrefix("who-tile-") }) != nil, "no profile tile took focus", app)
        require(seek("who-tile-p_fix_2", app, max: 4), "could not reach the PIN profile tile (focus: \(focusNote(app)))", app)
        remote.press(.select)
        let one = app.buttons["pin-key-1"]
        require(one.waitForExistence(timeout: 10), "the PIN pad did not open", app)
        require(waitForFocus(app, timeout: 10, where: { $0 == "pin-key-1" }) != nil, "the PIN pad did not seed its first key (focus: \(focusNote(app)))", app)
        // "1111" three times (the fixture PIN is 1234), one press at a time with the ring on 1.
        for n in 1...12 {
            require(waitForFocus(app, timeout: 5, where: { $0 == "pin-key-1" }) != nil, "before press \(n) the ring was not on 1 (focus: \(focusNote(app)))", app)
            remote.press(.select)
            sleep(1)
        }
        let back = waitForFocus(app, timeout: 10, where: { $0 == "pin-key-‹" })
        require(back != nil, "the third wrong PIN did not put the ring on Back (focus: \(focusNote(app)))", app)
        require(!one.isEnabled, "the digits stayed enabled during the cool-down", app)
        remote.press(.select)
        require(waitForGone(one, timeout: 10), "Back on the cooling PIN pad did not close it", app)
        require(waitForFocus(app, timeout: 10, where: { $0 == "who-tile-p_fix_2" }) != nil, "closing the PIN pad did not return the ring to its tile (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(one.waitForExistence(timeout: 10), "the PIN pad did not open again", app)
        require(waitForFocus(app, timeout: 10, where: { $0 == "pin-key-‹" }) != nil, "the PIN pad opened inside the cool-down did not start on Back (focus: \(focusNote(app)))", app)
        // The cool-down is 30 s from the third miss.
        require(waitForFocus(app, timeout: 45, where: { $0 == "pin-key-1" }) != nil, "the end of the cool-down did not put the ring back on 1 (focus: \(focusNote(app)))", app)
        require(one.isEnabled, "the digits stayed disabled after the cool-down", app)
        remote.press(.menu)
        require(waitForGone(one, timeout: 10), "Menu did not close the PIN pad", app)
    }

    /// The kids shell (fixture kid with a parent PIN): the profile chip asks for the parent PIN, and
    /// both Menu and the pad's own Back key close it with the ring back on the chip (the page under
    /// the pad was disabled, so tvOS used to put it on the hero), still on the kid's profile.
    func testKidsParentPinBackToChip() {
        let app = launch("who")
        require(app.buttons["who-tile-p_fix_3"].waitForExistence(timeout: 30), "Who's watching did not appear", app)
        require(waitForFocus(app, timeout: 10, where: { $0.hasPrefix("who-tile-") }) != nil, "no profile tile took focus", app)
        require(seek("who-tile-p_fix_3", app, max: 5), "could not reach the kid profile tile (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(app.buttons["tab-kids"].waitForExistence(timeout: 30), "picking the kid profile did not open the kids shell", app)
        waitForKidsPage(app)
        require(press(.up, app, max: 8, until: Self.inKidsBar) != nil, "Up never reached the kids top bar (focus: \(focusNote(app)))", app)
        require(seek("profile-chip", app, max: 6), "could not walk the kids bar to the profile chip (focus: \(focusNote(app)))", app)
        let one = app.buttons["pin-key-1"]
        // Menu on the parent PIN pad.
        remote.press(.select)
        require(one.waitForExistence(timeout: 10), "the profile chip did not open the parent PIN pad", app)
        require(waitForFocus(app, timeout: 10, where: { $0 == "pin-key-1" }) != nil, "the parent PIN pad did not take the ring (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.menu)
        require(waitForGone(one, timeout: 10), "Menu did not close the parent PIN pad", app)
        require(waitForFocus(app, timeout: 10, where: { $0 == "profile-chip" }) != nil, "Menu on the parent PIN did not return the ring to the profile chip (focus: \(focusNote(app)))", app)
        require(app.buttons["tab-kids"].exists, "Menu on the parent PIN left the kids shell", app)
        // The pad's own Back key (‹, bottom right of the keypad).
        remote.press(.select)
        require(one.waitForExistence(timeout: 10), "the parent PIN pad did not open again", app)
        require(waitForFocus(app, timeout: 10, where: { $0 == "pin-key-1" }) != nil, "the parent PIN pad did not take the ring again (focus: \(focusNote(app)))", app)
        require(press(.down, app, max: 4, until: { $0 == "pin-key-⌫" }) != nil, "Down on the keypad never reached its bottom row (focus: \(focusNote(app)))", app)
        require(press(.right, app, max: 3, until: { $0 == "pin-key-‹" }) != nil, "Right never reached the keypad's Back (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(waitForGone(one, timeout: 10), "Back on the parent PIN pad did not close it", app)
        require(waitForFocus(app, timeout: 10, where: { $0 == "profile-chip" }) != nil, "Back on the parent PIN did not return the ring to the profile chip (focus: \(focusNote(app)))", app)
        require(app.buttons["tab-kids"].exists && !app.buttons["who-tile-p_fix_1"].exists, "Back on the parent PIN left the kid's profile", app)
    }

    /// A room whose read fails (`--fixtures roomfail`: every read fails after 2 s): the failure
    /// card's Try again keeps the ring while the retry runs (the card stays up, dimmed) and after
    /// it fails again, instead of the ring falling to the top bar. Twice.
    func testRoomTryAgainKeepsRing() {
        let app = launch("roomfail")
        let retry = app.buttons["room-try-again"]
        require(retry.waitForExistence(timeout: 30), "the failed Home did not show its Try again card", app)
        sleep(1)
        require(press(.down, app, max: 4, until: { $0 == "room-try-again" }) != nil, "Down never reached Try again (focus: \(focusNote(app)))", app)
        for round in 1...2 {
            sleep(1)
            remote.press(.select)
            let strayed = focusLeft(app, from: "room-try-again", within: 5)
            require(strayed == nil, "round \(round): the ring left Try again while it ran (focus: \(strayed ?? "none"))", app)
            require(retry.exists, "round \(round): the failure card went away after the retry failed", app)
            require(waitForFocus(app, timeout: 5, where: { $0 == "room-try-again" }) != nil, "round \(round): the ring was not on Try again after the retry (focus: \(focusNote(app)))", app)
        }
    }
}
