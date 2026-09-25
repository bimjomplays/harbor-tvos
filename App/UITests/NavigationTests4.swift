import XCTest

/// Remote-navigation checks, fourth batch: flows fixed on 2026-09-25 (device-flow passes 7 and 10,
/// open-items sweep 2, the Browse/Search regression pass) that the first three batches do not
/// drive. Offline fixture scenarios only (`--fixtures shell|discfail|bands`): Discover's bands and
/// a failed Discover's Try again, Home's band row leads, the Collections source chips and New
/// collection row, Search's keyboard across a tab switch, and the Watch together page opened from
/// the account menu. Focus is only asserted where the app places it itself; everything else is
/// polled, with the same helpers and waits as NavigationTests3.
final class NavigationTests4: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var remote: XCUIRemote { XCUIRemote.shared }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--fixtures", scenario]
        app.launch()
        return app
    }

    // MARK: helpers (as NavigationTests3)

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

    /// Walks a row (or a column: `first` .up / .down) to the element with `id`: one way first, then
    /// back the other, so neither the starting cell nor an overshoot matters.
    private func seek(_ id: String, _ app: XCUIApplication, max presses: Int = 25, first: XCUIRemote.Button = .right) -> Bool {
        let then: XCUIRemote.Button
        switch first {
        case .left: then = .right
        case .up: then = .down
        case .down: then = .up
        default: then = .left
        }
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
    /// A cell of one of Discover's lead bands under the Discovery Queue (Awards, Genres, Voyages,
    /// Collections).
    private static func isDiscoverBandCell(_ id: String) -> Bool {
        id.hasPrefix("award-") || id.hasPrefix("anime-award-") || id.hasPrefix("genre-") || id == "voyage-band"
            || id.hasPrefix("collection-card-") || id == "collections-view-all"
    }
    /// The keyboard's bottom row (bp-keyboard.tsx: Space, Backspace, Clear, the set toggle).
    private static func isBottomKey(_ id: String) -> Bool {
        id == "key-space" || id == "key-backspace" || id == "key-clear" || id == "key-toggle"
    }

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

    // MARK: tests

    /// Discover places no first focus of its own: Down from its tab reaches the Discovery Queue
    /// band, the next Down the band under it (Awards, else Genres), and Up walks back through the
    /// queue band to the top bar, still on Discover. The page is built by the engine (its bands
    /// show whatever the network answers; the queue band and Genres are always there).
    func testDiscoverDownReachesBands() {
        let app = launch("shell")
        waitForHome(app)
        goToBar(app)
        require(seek("tab-discover", app, max: 15), "could not walk the top bar to Discover (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(waitUntil(timeout: 10) { app.buttons["tab-discover"].isSelected }, "Select on the Discover tab did not open Discover", app)
        require(app.buttons["queue-band"].waitForExistence(timeout: 60), "Discover never showed its Discovery Queue band", app)
        sleep(2)
        let queue = press(.down, app, max: 3, until: { $0 == "queue-band" })
        require(queue != nil, "Down from the top bar did not reach the Discovery Queue band (focus: \(focusNote(app)))", app)
        sleep(1)
        let next = press(.down, app, max: 3, until: Self.isDiscoverBandCell)
        require(next != nil, "Down from the Discovery Queue band did not reach the band under it (focus: \(focusNote(app)))", app)
        sleep(1)
        let back = press(.up, app, max: 3, until: { $0 == "queue-band" })
        require(back != nil, "Up from \(next ?? "?") did not return to the Discovery Queue band (focus: \(focusNote(app)))", app)
        sleep(1)
        require(press(.up, app, max: 3, until: Self.inBar) != nil, "Up from the Discovery Queue band did not reach the top bar (focus: \(focusNote(app)))", app)
        require(app.buttons["tab-discover"].isSelected, "walking Discover's bands left Discover", app)
    }

    /// `--fixtures discfail` (every Discover build fails after 2 s): the failure card's Try again
    /// is one Down from either end of the top bar (the card is centred; device-flow pass 10 made it
    /// a full-width focus section), and a retry that fails again keeps the ring on it. Twice.
    func testDiscoverFailedTryAgainReachable() {
        let app = launch("discfail")
        waitForHome(app)
        goToBar(app)
        require(seek("tab-discover", app, max: 15), "could not walk the top bar to Discover (focus: \(focusNote(app)))", app)
        remote.press(.select)
        let retry = app.buttons["discover-try-again"]
        require(retry.waitForExistence(timeout: 30), "the failed Discover did not show its Try again", app)
        sleep(1)
        let ends: [(String, XCUIRemote.Button)] = [("tab-home", .left), ("tab-settings", .right)]
        for (item, way) in ends {
            require(press(.up, app, max: 4, until: Self.inBar) != nil, "Up never reached the top bar (focus: \(focusNote(app)))", app)
            require(seek(item, app, first: way), "could not walk the top bar to \(item) (focus: \(focusNote(app)))", app)
            sleep(1)
            remote.press(.down)
            require(waitForFocus(app, timeout: 5, where: { $0 == "discover-try-again" }) != nil, "one Down from \(item) did not reach Try again (focus: \(focusNote(app)))", app)
        }
        require(app.buttons["tab-discover"].isSelected, "walking the top bar left Discover", app)
        for round in 1...2 {
            sleep(1)
            remote.press(.select)
            let strayed = focusLeft(app, from: "discover-try-again", within: 5)
            require(strayed == nil, "round \(round): the ring left Try again while it ran (focus: \(strayed ?? "none"))", app)
            require(retry.exists, "round \(round): the failure card went away after the retry failed", app)
            require(waitForFocus(app, timeout: 5, where: { $0 == "discover-try-again" }) != nil, "round \(round): the ring was not on Try again after the retry (focus: \(focusNote(app)))", app)
        }
    }

    /// `--fixtures bands` (Home also carries Your streaming, Your addons and Collections): bp-home's
    /// row leads (device-flow pass 10). Your streaming's lead reads "Manage", Your addons has none
    /// (not even at its last tile), Collections reads "View all"; Right off the last streaming tile
    /// reaches Manage, and Manage opens Settings.
    func testHomeBandRowLeads() {
        let app = launch("bands")
        waitForHome(app)
        let services = press(.down, app, max: 8, until: { $0.hasPrefix("tile-services-") })
        require(services != nil, "Down never reached the Your streaming row (focus: \(focusNote(app)))", app)
        let manage = app.buttons["seeall-services"]
        require(manage.waitForExistence(timeout: 5), "Your streaming showed no lead while it held the ring", app)
        require(manage.label == "Manage", "Your streaming's lead reads \"\(manage.label)\", not Manage", app)
        sleep(1)
        let addons = press(.down, app, max: 3, until: { $0.hasPrefix("tile-addons-") })
        require(addons != nil, "Down from Your streaming did not reach the Your addons row (focus: \(focusNote(app)))", app)
        sleep(1)
        require(!app.buttons["seeall-addons"].exists, "Your addons shows a lead (bp-home's addon row has none)", app)
        require(press(.right, app, max: 4, until: { $0 == "tile-addons-2" }) != nil, "could not walk Your addons to its last tile (focus: \(focusNote(app)))", app)
        sleep(1)
        require(!app.buttons["seeall-addons"].exists, "Your addons shows a lead at its last tile", app)
        let collections = press(.down, app, max: 3, until: { $0.hasPrefix("tile-collections-") })
        require(collections != nil, "Down from Your addons did not reach the Collections row (focus: \(focusNote(app)))", app)
        let viewAll = app.buttons["seeall-collections"]
        require(viewAll.waitForExistence(timeout: 5), "the Collections row showed no lead while it held the ring", app)
        require(viewAll.label == "View all", "the Collections row's lead reads \"\(viewAll.label)\", not View all", app)
        sleep(1)
        require(press(.up, app, max: 4, until: { $0.hasPrefix("tile-services-") }) != nil, "Up never returned to Your streaming (focus: \(focusNote(app)))", app)
        require(press(.right, app, max: 4, until: { $0 == "tile-services-2" }) != nil, "could not walk Your streaming to its last tile (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.right)
        require(waitForFocus(app, timeout: 5, where: { $0 == "seeall-services" }) != nil, "Right off the last streaming tile did not reach Manage (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 15) { app.buttons["tab-settings"].isSelected }, "Manage did not open Settings", app)
        require(app.staticTexts["Settings"].waitForExistence(timeout: 15), "the Settings page did not appear after Manage", app)
    }

    /// Collections: Down from the top bar reaches the source chips; under Mine, New collection opens
    /// its name row, and Menu inside the row closes it with the ring back on New collection, still
    /// on Collections (device-flow pass 10; it left for Home with the row open). Another tab and
    /// back, the room opens on Mine again (open-items sweep 2, bp-view-state collectionSource); Menu
    /// there, with no row open, goes Home.
    func testCollectionsNewCollectionBack() {
        let app = launch("shell")
        waitForHome(app)
        goToBar(app)
        require(seek("tab-collections", app), "could not walk the top bar to Collections (focus: \(focusNote(app)))", app)
        remote.press(.select)
        let mine = app.buttons["collections-source-mine"]
        require(mine.waitForExistence(timeout: 20), "the Collections source chips did not appear", app)
        require(waitUntil(timeout: 10) { app.buttons["tab-collections"].isSelected }, "Select on the Collections tab did not open Collections", app)
        sleep(1)
        let chip = press(.down, app, max: 3, until: { $0.hasPrefix("collections-source-") || $0 == "collections-new" })
        require(chip != nil, "Down from the top bar did not reach the source chips (focus: \(focusNote(app)))", app)
        require(seek("collections-source-mine", app, max: 8, first: .left), "could not walk the chips to Mine (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 10) { mine.isSelected }, "Select on Mine did not select it", app)
        require(waitForFocus(app, timeout: 5, where: { $0 == "collections-source-mine" }) != nil, "the ring left Mine after picking it (focus: \(focusNote(app)))", app)
        let newButton = app.buttons["collections-new"]
        require(newButton.waitForExistence(timeout: 10), "Mine offers no New collection", app)
        require(seek("collections-new", app, max: 6), "could not walk the chips to New collection (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        let cancel = app.buttons["collections-cancel"]
        require(cancel.waitForExistence(timeout: 10), "New collection did not open its name row under Mine", app)
        sleep(1)
        remote.press(.down)
        // Down lands on the name field (not a button) or on Create; Right from the field reaches Create.
        let inRow = press(.right, app, max: 3, until: { $0 == "collections-create" || $0 == "collections-cancel" })
        require(inRow != nil, "Down from New collection did not reach the name row (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.menu)
        require(waitForGone(cancel, timeout: 10), "Menu in the name row did not close it", app)
        require(waitForFocus(app, timeout: 10, where: { $0 == "collections-new" }) != nil, "closing the name row did not return the ring to New collection (focus: \(focusNote(app)))", app)
        require(app.buttons["tab-collections"].isSelected, "Menu in the name row left Collections", app)
        require(mine.isSelected, "closing the name row changed the source from Mine", app)
        // Another tab and back.
        sleep(1)
        require(press(.up, app, max: 4, until: Self.inBar) != nil, "Up from the chips never reached the top bar (focus: \(focusNote(app)))", app)
        require(seek("tab-library", app, max: 12, first: .left), "could not walk the top bar to Library (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(waitUntil(timeout: 15) { app.buttons["tab-library"].isSelected }, "Select on the Library tab did not open the Library", app)
        require(waitForGone(mine, timeout: 10), "the Collections chips stayed up on the Library", app)
        sleep(1)
        require(press(.up, app, max: 4, until: Self.inBar) != nil, "Up on the Library never reached the top bar (focus: \(focusNote(app)))", app)
        require(seek("tab-collections", app), "could not walk the top bar back to Collections (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(mine.waitForExistence(timeout: 20), "the Collections source chips did not come back", app)
        require(waitUntil(timeout: 10) { mine.isSelected }, "Collections came back on another source than Mine", app)
        sleep(1)
        remote.press(.menu)
        require(waitUntil(timeout: 15) { app.buttons["tab-home"].isSelected }, "Menu on Collections (no row open) did not go Home", app)
    }

    /// Search: a key typed on the on-screen keyboard shows in the query; with the ring on the
    /// keyboard's bottom row, Menu goes Home (not swallowed). Opened again, Search keeps the query
    /// and starts on the keyboard's first key (the regression pass: the bottom row now counts as
    /// the keyboard holding the ring, so no result is remembered over it).
    func testSearchKeyboardAcrossTabSwitch() {
        let app = launch("shell")
        waitForHome(app)
        goToBar(app)
        require(seek("tab-search", app), "could not walk the top bar to Search (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(app.buttons["key-q"].waitForExistence(timeout: 20), "the Search keyboard did not appear", app)
        require(waitForFocus(app, timeout: 10, where: { $0 == "key-1" }) != nil, "Search did not put the ring on the keyboard (focus: \(focusNote(app)))", app)
        remote.press(.down)
        let key = waitForFocus(app, timeout: 5, where: { $0.hasPrefix("key-") && $0.count == 5 && $0 != "key-1" })
        require(key != nil, "Down on the keyboard left the keys (focus: \(focusNote(app)))", app)
        guard let key else { return }
        let ch = String(key.suffix(1))
        remote.press(.select)
        let fields = app.descendants(matching: .any).matching(identifier: "search-query")
        require(fields.firstMatch.waitForExistence(timeout: 5), "the query field is missing", app)
        let typed = waitUntil(timeout: 10) {
            fields.allElementsBoundByIndex.contains { ($0.value as? String) == ch }
        }
        require(typed, "the query did not show \"\(ch)\"", app)
        let bottom = press(.down, app, max: 5, until: Self.isBottomKey)
        require(bottom != nil, "Down never reached the keyboard's bottom row (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.menu)
        require(waitForGone(app.buttons["key-q"], timeout: 15), "Menu on Search's keyboard was swallowed (still on Search)", app)
        require(waitUntil(timeout: 15) { app.buttons["tab-home"].isSelected }, "Menu from Search did not go Home", app)
        // Home seeds its first card on every visit; let it land before walking up to the bar.
        _ = waitForFocus(app, timeout: 15, where: Self.isHomeCard)
        sleep(1)
        goToBar(app)
        require(seek("tab-search", app), "could not walk the top bar back to Search (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(app.buttons["key-q"].waitForExistence(timeout: 20), "the Search keyboard did not come back", app)
        require(waitForFocus(app, timeout: 10, where: { $0 == "key-1" }) != nil, "Search opened again without the ring on the keyboard's first key (focus: \(focusNote(app)))", app)
        let kept = waitUntil(timeout: 5) {
            fields.allElementsBoundByIndex.contains { ($0.value as? String) == ch }
        }
        let values = fields.allElementsBoundByIndex.map { String(describing: $0.value) }
        require(kept, "Search opened again without the query \"\(ch)\" (values: \(values))", app)
    }

    /// The account menu's Watch together: the page opens with the ring on its first action (Use
    /// Harbor's public relay without a relay, which is the fixture's state; Start a new room with
    /// one; device-flow pass 7), its row walks Right to Back, and Back closes it with the ring back
    /// on Watch together. Opened again, Menu closes it the same way; a second Menu closes the
    /// account menu onto the bell. Nothing here reaches a relay.
    func testWatchTogetherFromAccountMenu() {
        let app = launch("shell")
        waitForHome(app)
        goToBar(app)
        require(seek("account-menu", app), "could not walk the top bar to the bell (focus: \(focusNote(app)))", app)
        remote.press(.select)
        let item = app.buttons["account-item-together"]
        require(item.waitForExistence(timeout: 15), "the bell did not open the account menu with Watch together", app)
        require(waitForFocus(app, timeout: 10, where: { $0.hasPrefix("account-item-") }) != nil, "the account menu opened without the ring on an item (focus: \(focusNote(app)))", app)
        // The menu's account read can swap its first items; let it settle before walking.
        sleep(2)
        require(seek("account-item-together", app, max: 8, first: .down), "could not walk the account menu to Watch together (focus: \(focusNote(app)))", app)
        let firstAction: (String) -> Bool = { $0 == "together-public" || $0 == "together-start" }
        let back = app.buttons["together-back"]
        for round in 1...2 {
            sleep(1)
            remote.press(.select)
            require(back.waitForExistence(timeout: 15), "round \(round): Watch together did not open its page", app)
            let seeded = waitForFocus(app, timeout: 10, where: firstAction)
            require(seeded != nil, "round \(round): the Watch together page did not put the ring on its first action (focus: \(focusNote(app)))", app)
            sleep(1)
            if round == 1 {
                require(press(.right, app, max: 4, until: { $0 == "together-back" }) != nil, "Right along the page's actions never reached Back (focus: \(focusNote(app)))", app)
                sleep(1)
                remote.press(.select)
            } else {
                remote.press(.menu)
            }
            let how: String = round == 1 ? "Back" : "Menu"
            require(waitForGone(back, timeout: 10), "\(how) did not close the Watch together page", app)
            require(waitForFocus(app, timeout: 10, where: { $0 == "account-item-together" }) != nil, "closing Watch together with \(how) did not return the ring to its item (focus: \(focusNote(app)))", app)
        }
        sleep(1)
        remote.press(.menu)
        require(waitForGone(item, timeout: 10), "Menu did not close the account menu", app)
        require(waitForFocus(app, timeout: 10, where: { $0 == "account-menu" }) != nil, "closing the account menu did not return the ring to the bell (focus: \(focusNote(app)))", app)
        require(app.buttons["tab-home"].isSelected, "the account menu and Watch together left Home", app)
    }
}
