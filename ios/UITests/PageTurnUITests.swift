import XCTest

/// The page-turn swipe back (Appearance → Going back): off by default; when on, the
/// screen follows the finger, a long swipe goes back and a short one stays.
final class PageTurnUITests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch(on: Bool = true, theme: String = "fable", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-dictionary-fixture", "--ui-reset-search-keyboard", "-readerThemePreset", theme] + extra
        // Holding: the turn stays where the finger left it for 3 s, so it can be photographed.
        if on { app.launchArguments += ["--ui-page-turn", "--ui-page-turn-hold"] }
        app.launch()
        return app
    }

    /// Drags from an edge of the screen and lets go; with holding on, the page stays turned for 3 s.
    private func turn(_ app: XCUIApplication, from: CGFloat = 0.012, to: CGFloat, height: CGFloat = 0.5, drop: CGFloat = 0) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: from, dy: height))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: to, dy: height + drop))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    private func openDefinition(_ app: XCUIApplication) {
        app.tabBars.buttons["Search"].tap()
        let field = app.textFields["dictionarySearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("みほん")
        let result = app.buttons["dictionaryResult_みほん"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        result.tap()
        XCTAssertTrue(app.webViews.links["実物"].waitForExistence(timeout: 30), "The definition must render")
    }

    func testOffByDefaultAndSwitchedOnInAppearance() {
        let app = launch(on: false)
        app.tabBars.buttons["Library"].tap()
        let open = app.buttons["openAppearance"]
        for _ in 0..<6 where !open.isHittable { app.swipeUp() }
        open.tap()
        let jump = app.buttons["sectionJump"].firstMatch
        XCTAssertTrue(jump.waitForExistence(timeout: 10))
        jump.tap()
        XCTAssertTrue(app.buttons["sectionJump_7"].waitForExistence(timeout: 5))
        app.buttons["sectionJump_7"].tap()
        sleep(2)
        let toggle = app.switches["pageTurnBack"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0", "The page-turn swipe back is off until it is switched on")
        shot(app, "Page turn · setting (off by default)")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        // On: the swipe back from Appearance turns the page.
        turn(app, to: 0.75)
        XCTAssertTrue(app.buttons["openAppearance"].waitForExistence(timeout: 8), "A long swipe turns back to Library")
    }

    func testWithTheSettingOffTheSwipeGoesBackAsBefore() {
        let app = launch(on: false)
        openDefinition(app)
        turn(app, to: 0.7)
        XCTAssertTrue(app.buttons["dictionaryResult_みほん"].firstMatch.waitForExistence(timeout: 8))
    }

    func testDefinitionTurnsBackToResultsAndThenToTheTabItCameFrom() {
        let app = launch()
        openDefinition(app)
        // A short swipe: the page lifts, then lies down again.
        turn(app, to: 0.2)
        shot(app, "Page turn · short swipe (lifts)")
        sleep(4)
        XCTAssertTrue(app.webViews.links["実物"].waitForExistence(timeout: 5), "A short swipe stays on the definition")
        XCTAssertTrue(app.webViews.links["実物"].isHittable)
        shot(app, "Page turn · short swipe (laid down again)")

        // A long swipe: the results show underneath, and the turn finishes.
        turn(app, to: 0.62, height: 0.3, drop: 0.1)
        shot(app, "Page turn · definition over results")
        let result = app.buttons["dictionaryResult_みほん"].firstMatch
        sleep(4)
        XCTAssertTrue(result.waitForExistence(timeout: 8), "A long swipe turns back to the results")
        XCTAssertTrue(result.isHittable)
        shot(app, "Page turn · back on results")

        // From the results the turn goes back to the tab Search was opened from, here from the right edge.
        turn(app, from: 0.988, to: 0.3, height: 0.6)
        shot(app, "Page turn · results over Read (right edge)")
        XCTAssertTrue(app.textViews["selectablePassage"].waitForExistence(timeout: 10), "The turn ends on the Read tab")
        sleep(2)
        shot(app, "Page turn · back on Read")
    }

    /// Upside down (the window is turned by the app) and on a dark theme: the sheet
    /// still starts at the page's own left edge and the pictures stay the right way up.
    func testUpsideDownOnADarkTheme() {
        // The word arrives the way the share-sheet shortcut sends it, so nothing is typed.
        let app = launch(theme: "hand-matcha", extra: ["--ui-flip-on", "--ui-external-lookup", "みほん"])
        let result = app.buttons["dictionaryResult_みほん"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20))
        result.tap()
        XCTAssertTrue(app.webViews.links["実物"].waitForExistence(timeout: 30))
        sleep(1)
        // The page's left edge is at the right of the upside-down screen.
        turn(app, from: 0.988, to: 0.4, height: 0.55)
        shot(app, "Page turn · upside down, definition over results")
        sleep(4)
        XCTAssertTrue(result.waitForExistence(timeout: 8), "The turn goes back to the results")

        app.tabBars.buttons["Grammar"].tap()
        app.buttons["grammarLevel_N2"].tap()
        let nuku = app.buttons["grammarEntry_N2|〜ぬく"]
        XCTAssertTrue(nuku.waitForExistence(timeout: 15))
        nuku.tap()
        XCTAssertTrue(app.webViews["grammarLessonPage"].staticTexts["意思"].waitForExistence(timeout: 20))
        sleep(1)
        turn(app, from: 0.988, to: 0.45, height: 0.4)
        shot(app, "Page turn · upside down, lesson over the list")
        sleep(4)
        XCTAssertTrue(nuku.waitForExistence(timeout: 8), "The lesson turns back to the list")
    }

    func testGrammarLessonTurnsBackToTheList() {
        let app = launch()
        app.tabBars.buttons["Grammar"].tap()
        app.buttons["grammarLevel_N2"].tap()
        let nuku = app.buttons["grammarEntry_N2|〜ぬく"]
        XCTAssertTrue(nuku.waitForExistence(timeout: 15))
        nuku.tap()
        let page = app.webViews["grammarLessonPage"]
        XCTAssertTrue(page.staticTexts["意思"].waitForExistence(timeout: 20))
        sleep(1)

        turn(app, to: 0.15)
        sleep(4)
        XCTAssertTrue(page.staticTexts["意思"].isHittable, "A short swipe stays on the lesson")

        turn(app, to: 0.55, height: 0.7, drop: -0.1)
        shot(app, "Page turn · lesson over the list")
        sleep(4)
        XCTAssertTrue(nuku.waitForExistence(timeout: 8), "A long swipe turns back to the list")
        XCTAssertTrue(nuku.isHittable)
        shot(app, "Page turn · back on the list")
        // The list is really the page now: a lesson opens again from it.
        nuku.tap()
        XCTAssertTrue(page.staticTexts["意思"].waitForExistence(timeout: 20))
    }
}
