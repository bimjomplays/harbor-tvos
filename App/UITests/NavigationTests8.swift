import XCTest

/// Remote-navigation checks, eighth batch: the primary editing ANOTHER profile's kid setup through
/// Manage profiles (App/Sources/Profiles/ManageProfilesView.swift, ProfileEditorView.swift) actually
/// writes and is visible back on the list, and the eBook detail page's Mark as Read action
/// (App/Sources/EBook/EBookDetailView.swift). `--fixtures shell` for the first, `--fixtures ebook`
/// for the second.
///
/// NavigationTests6/7 proved the Manage profiles route *opens* Guest's editor with the kid toggle
/// and PIN & sidebar locks reachable, but never turned the toggle on or saved — this batch closes
/// that gap: turning Kids on, picking an age and a curfew, and Save actually persists (checked via
/// the Manage list's own row, not just the editor closing without error), and reopening the same
/// profile shows the same choices selected, matching kids-setup-panel.tsx's own round trip.
/// ManageProfilesView's row already showed "Kid profile" as `subtitle(p)` text once `p.kid != nil`,
/// but that Text sits inside the row's own Button, which (like every other row in this file's
/// family — who-tile-<id>, manage-profile-<id>) carries an explicit `.accessibilityLabel` that
/// replaces its children's combined text; a Button that overrides its label this way collapses to
/// one accessibility element on tvOS, so the subtitle was never queryable as a value of its own.
/// This batch adds `.accessibilityValue(Text(verbatim: subtitle(p)))` to that row (the same
/// technique BPTileView.swift already uses for its mark chips text, read here the same way
/// NavigationTests/NavigationTests4 already read a PIN field's value: `.value as? String`) rather
/// than a second identifier, since the row's own `manage-profile-<id>` already names it uniquely.
///
/// The second test was asked for as "the eBook reader restores its chapter position", ported from
/// upstream's own resume behaviour (EBookDetails resume/EBookReaderModel). That path needs a real
/// EPUB byte stream: EBookDetailModel.loadChapters calls the engine's `ebook.epub` (which itself
/// calls out to Gutendex) for a URL, then `EPUBLibrary.book(key:url:)` (EPUBBook.swift) fetches that
/// URL with `URLSession.shared.data(for:)` — a real network request, unconditionally, with no local
/// or bundled EPUB fallback anywhere in this port. `Fixtures.installEBookSource` (App/Sources/App/
/// Fixtures.swift) only pre-installs the Gutendex *source* locally (a config write); it never seeds
/// a catalog page, a book detail or an EPUB body, so even the Popular rail's cards and every field on
/// the detail page beyond the cached title/cover need `gutendex.com` and, to open the reader at all,
/// the book's actual archive.org (or equivalent) EPUB URL too. There is no way to reach the reader
/// under any offline fixture, so this covers the Detail page instead, guarded the same way
/// NavigationTests7 (XCTSkip precedent) already tolerate the runner's own flaky network: `waitUntil` on the
/// Popular rail's first card, `XCTSkip` (not a failure) if it never appears within the timeout. Once
/// on the Detail page, the action row's Mark as Read toggle (`ebook-mark-read`, added by this batch)
/// needs no further network to flip: `EBookDetailModel.toggleRead` persists the tracking entry
/// locally before it ever reaches AniList, per its own doc comment.
final class NavigationTests8: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var remote: XCUIRemote { XCUIRemote.shared }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--fixtures", scenario]
        app.launch()
        return app
    }

    // MARK: helpers (as NavigationTests7, verbatim)

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
        // Any element type, not only buttons: this file is the suite's first to walk a tvOS
        // `.contextMenu`, whose rows may not be reported as XCUIElementTypeButton.
        let f = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
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

    private static func isHomeCard(_ id: String) -> Bool { id.hasPrefix("cw-") || id.hasPrefix("tile-") }
    private static func inBar(_ id: String) -> Bool { id.hasPrefix("tab-") || id == "profile-chip" || id == "account-menu" }

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

    // MARK: Settings/Profiles helpers (as NavigationTests6, verbatim)

    /// Walks the top bar to Settings and opens it (as testSpoilersMasterToggleAndMenu does).
    private func openSettings(_ app: XCUIApplication) {
        goToBar(app)
        require(seek("tab-settings", app), "could not walk the top bar to Settings (focus: \(focusNote(app)))", app)
        remote.press(.select)
        require(app.staticTexts["Settings"].waitForExistence(timeout: 15), "Settings did not open", app)
    }

    /// The Profiles section's own row is far down the Settings page; every visit walks Down to it
    /// from wherever the ring currently is (the top of a fresh page, or already on that row), then
    /// lands on whichever of its buttons is nearest and seeks the exact one — Down between
    /// sections does not always keep the same column. Four buttons for a non-primary active
    /// profile, five (a trailing "Manage profiles") for the primary (SettingsView.swift).
    private static func inProfilesRow(_ id: String) -> Bool {
        ["settings-switch-profile", "settings-pin-button", "settings-edit-profile", "settings-add-profile", "settings-manage-profiles"].contains(id)
    }

    private func openProfilesRow(_ app: XCUIApplication) {
        require(press(.down, app, max: 200, until: Self.inProfilesRow) != nil,
                "Down never reached the Profiles row (focus: \(focusNote(app)))", app)
        require(seek("settings-switch-profile", app, max: 4), "could not reach Switch profile within the Profiles row (focus: \(focusNote(app)))", app)
    }

    // MARK: tests

    /// Manage profiles → Guest's editor (App/Sources/Profiles/ManageProfilesView.swift,
    /// ProfileEditorView.swift): the fixture's primary (Skipper) is active throughout, so Manage
    /// profiles (unlike Settings' own "Edit profile") can open the PIN-protected Guest's ("p_fix_2")
    /// editor directly, same route NavigationTests6.testManageProfilesOpensGuestEditor proved reaches
    /// the kid toggle and "PIN & sidebar locks" — this test is the write half that one left undone:
    /// turns Kids on, picks age 9 and the 30 min curfew, Saves, and checks the Manage list's own
    /// Guest row (its subtitle, exposed as this batch's added `.accessibilityValue`, since the row's
    /// explicit `.accessibilityLabel` already collapses its child Text into one element — see the
    /// class doc comment) now reads "Kid profile" instead of "Standard profile". Reopens Guest to
    /// confirm the same choices come back selected (kids-setup-panel.tsx's own round trip: age and
    /// curfew are read straight off `editing?.kid`), then turns Kids back off and Saves — the fixture
    /// resets on the next launch regardless (`Fixtures.installIfRequested` calls `profiles.reset()`
    /// before every `--fixtures shell` launch, confirmed by reading it directly, as NavigationTests6's
    /// own doc comment already established), but leaving Guest as it started keeps this test not
    /// order-dependent on whichever other `--fixtures shell` test the runner picks next.
    func testManageProfilesKidSetupWrites() {
        let app = launch("shell")
        waitForHome(app)
        openSettings(app)
        openProfilesRow(app)
        require(seek("settings-manage-profiles", app, max: 5), "could not reach Manage profiles from Switch profile (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(app.staticTexts["Manage profiles"].waitForExistence(timeout: 15), "Manage profiles did not open", app)
        let guestRow = app.buttons["manage-profile-p_fix_2"]
        require(guestRow.waitForExistence(timeout: 10), "Guest's row is missing from Manage profiles", app)
        require((guestRow.value as? String) == "Standard profile", "Guest's row did not start as \"Standard profile\" (was \"\(guestRow.value ?? "nil")\")", app)
        require(seek("manage-profile-p_fix_2", app, max: 6, first: .down), "could not reach Guest's row in Manage profiles (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(app.staticTexts["Edit profile"].waitForExistence(timeout: 15), "Select on Guest's row did not open its editor", app)

        // Turn Kids on, pick age 9 and the 30 min curfew (same navigation NavigationTests6's create-
        // form flow uses: the kid toggle sits right after the Colour swatches, the toggle's own row is
        // full width so Down from it lands on the age row, and so on down to the curfew row).
        let kidToggle = app.buttons["profile-kid-toggle"]
        require(kidToggle.waitForExistence(timeout: 10), "the kid toggle is missing while the primary edits Guest through Manage profiles", app)
        require(kidToggle.label == "Off", "Guest's kid toggle did not start Off (was \"\(kidToggle.label)\")", app)
        sleep(1)
        require(press(.down, app, max: 8, until: { $0 == "profile-kid-toggle" }) != nil, "Down never reached the kid toggle (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { kidToggle.label == "On" }, "Select on the kid toggle did not turn Kids on (now \"\(kidToggle.label)\")", app)
        require(app.buttons["profile-kid-age-9"].waitForExistence(timeout: 10), "turning Kids on did not show the age pills", app)
        require(app.buttons["profile-kid-curfew-30"].waitForExistence(timeout: 5), "turning Kids on did not show the curfew pills", app)
        sleep(1)
        require(press(.down, app, max: 8, until: { $0.hasPrefix("profile-kid-age-") }) != nil, "Down never reached the age pills (focus: \(focusNote(app)))", app)
        require(seek("profile-kid-age-9", app, max: 6), "could not reach the age 9 pill (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { app.buttons["profile-kid-age-9"].isSelected }, "Select on the age 9 pill did not select it", app)
        sleep(1)
        require(press(.down, app, max: 8, until: { $0.hasPrefix("profile-kid-curfew-") }) != nil, "Down never reached the curfew pills (focus: \(focusNote(app)))", app)
        require(seek("profile-kid-curfew-30", app, max: 6), "could not reach the 30 min curfew pill (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { app.buttons["profile-kid-curfew-30"].isSelected }, "Select on the 30 min curfew pill did not select it", app)
        sleep(1)

        // Past the (unfocusable) parent PIN field and the avatar catalog to the form's Save/Cancel row.
        require(press(.down, app, max: 120, until: { $0 == "profile-save" || $0 == "profile-cancel" }) != nil, "Down never reached the Save/Cancel row (focus: \(focusNote(app)))", app)
        require(seek("profile-save", app, max: 3), "could not reach Save from the Save/Cancel row (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(waitForGone(app.staticTexts["Edit profile"], timeout: 15), "Save did not close Guest's editor", app)
        require(guestRow.waitForExistence(timeout: 10), "closing the editor did not return to Manage profiles' list", app)
        require(waitUntil(timeout: 10) { (guestRow.value as? String) == "Kid profile" }, "Guest's row did not read \"Kid profile\" after Save (was \"\(guestRow.value ?? "nil")\")", app)

        // Reopen Guest: the same choices come back selected (kids-setup-panel.tsx's own round trip).
        sleep(1)
        require(seek("manage-profile-p_fix_2", app, max: 6, first: .down), "could not reach Guest's row again (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(app.staticTexts["Edit profile"].waitForExistence(timeout: 15), "reopening Guest's row did not open its editor", app)
        require(waitUntil(timeout: 10) { kidToggle.label == "On" }, "reopening Guest did not show Kids back On (was \"\(kidToggle.label)\")", app)
        require(app.buttons["profile-kid-age-9"].waitForExistence(timeout: 10), "reopening Guest did not show the age pills", app)
        require(app.buttons["profile-kid-age-9"].isSelected, "reopening Guest did not keep age 9 selected", app)
        require(app.buttons["profile-kid-curfew-30"].waitForExistence(timeout: 5), "reopening Guest did not show the curfew pills", app)
        require(app.buttons["profile-kid-curfew-30"].isSelected, "reopening Guest did not keep the 30 min curfew selected", app)

        // Turn Kids back off and Save, leaving Guest as the fixture started it.
        sleep(1)
        require(press(.down, app, max: 8, until: { $0 == "profile-kid-toggle" }) != nil, "Down never reached the kid toggle again (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 5) { kidToggle.label == "Off" }, "Select on the kid toggle did not turn Kids off again (now \"\(kidToggle.label)\")", app)
        sleep(1)
        require(press(.down, app, max: 120, until: { $0 == "profile-save" || $0 == "profile-cancel" }) != nil, "Down never reached the Save/Cancel row again (focus: \(focusNote(app)))", app)
        require(seek("profile-save", app, max: 3), "could not reach Save from the Save/Cancel row again (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(waitForGone(app.staticTexts["Edit profile"], timeout: 15), "the second Save did not close Guest's editor", app)
        require(waitUntil(timeout: 10) { (guestRow.value as? String) == "Standard profile" }, "Guest's row did not read \"Standard profile\" again after turning Kids off (was \"\(guestRow.value ?? "nil")\")", app)
        sleep(1)
        remote.press(.menu)
        require(waitForGone(app.staticTexts["Manage profiles"], timeout: 10), "Menu did not close the Manage profiles panel", app)
    }

    /// eBook detail page (App/Sources/EBook/EBookDetailView.swift): see the class doc comment for why
    /// the reader-restore behaviour this batch was first asked to cover has no offline path in this
    /// port at all (every step from the Popular rail's cards onward needs Gutendex, and the reader
    /// itself a real EPUB download), so this covers the Detail page's Mark as Read action instead —
    /// opened from a Popular tile, which needs `gutendex.com` too (the CI runner's own network,
    /// already known flaky per NavigationTests5's own comments on the same rail): `XCTSkip`, not a
    /// failure, if it never loads within the timeout. Once open, `EBookDetailModel.toggleRead` needs
    /// no further network to flip the label between "Mark as Read" (unread) and "Marked as read"
    /// (read) — its own doc comment: `saveEBookTracking persists locally before it ever reaches the
    /// network`. Menu closes the detail page back onto the room, still on the eBook tab.
    func testEBookDetailMarkAsReadTogglesAndMenuReturns() throws {
        let app = launch("ebook")
        waitForHome(app)
        goToBar(app)
        require(seek("tab-ebook", app), "could not walk the top bar to eBook (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 15) { app.buttons["tab-ebook"].isSelected }, "Select on the eBook tab did not open it", app)

        // The Popular rail needs gutendex.com; skip rather than fail if the runner's network never
        // lands it (NavigationTests5.testEBookFilterChipsAndCollections notes the same flakiness).
        guard waitUntil(timeout: 30, { app.buttons["tile-ebook-popular-0"].exists }) else {
            throw XCTSkip("the eBook Popular rail never loaded from gutendex.com in the simulator, so there is no book to open the detail page from")
        }
        sleep(1)
        require(press(.down, app, max: 10, until: { $0.hasPrefix("tile-ebook-popular-") }) != nil, "Down never reached the Popular rail (focus: \(focusNote(app)))", app)
        require(seek("tile-ebook-popular-0", app, max: 8, first: .left), "could not reach the Popular rail's first card (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        let markRead = app.buttons["ebook-mark-read"]
        require(markRead.waitForExistence(timeout: 20), "opening the Popular tile did not show the eBook detail page's Mark as Read action", app)
        require(markRead.label == "Mark as Read", "Mark as Read did not start unread (was \"\(markRead.label)\")", app)

        // The action row is the header's own focusSection; whichever button the page's own default
        // focus lands on, Mark as Read sits along the same row.
        require(waitForFocus(app, timeout: 10, where: { _ in true }) != nil, "no element took focus when the eBook detail page opened", app)
        require(seek("ebook-mark-read", app, max: 6), "could not reach Mark as Read in the action row (focus: \(focusNote(app)))", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 10) { markRead.label == "Marked as read" }, "Select on Mark as Read did not flip it to the read variant (now \"\(markRead.label)\")", app)
        sleep(1)
        remote.press(.select)
        require(waitUntil(timeout: 10) { markRead.label == "Mark as Read" }, "a second Select on Marked as read did not flip it back to the unread variant (now \"\(markRead.label)\")", app)

        sleep(1)
        remote.press(.menu)
        require(waitForGone(markRead, timeout: 10), "Menu did not close the eBook detail page", app)
        require(app.buttons["tile-ebook-popular-0"].waitForExistence(timeout: 10), "closing the detail page did not return to the eBook room", app)
        require(app.buttons["tab-ebook"].isSelected, "the eBook detail page left the eBook tab", app)
    }
}
