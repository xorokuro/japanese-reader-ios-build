import XCTest

/// Swiping back: the page follows the finger, from the edge or from anywhere on the page,
/// and never takes a scroll, the dictionary card's drags or a selection's handles.
final class BackSwipeUITests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch(_ extra: [String] = [], hold: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-dictionary-fixture", "--ui-reset-search-keyboard", "-readerThemePreset", "fable"] + extra
        // Holding: the page stays where the finger left it for 3 s, so it can be photographed.
        if hold { app.launchArguments.append("--ui-page-turn-hold") }
        app.launch()
        return app
    }

    /// Presses at `from` and drags to `to` (fractions of the screen), then lets go.
    private func drag(_ app: XCUIApplication, from: CGVector, to: CGVector, hold: TimeInterval = 0.2) {
        let start = app.coordinate(withNormalizedOffset: from)
        let end = app.coordinate(withNormalizedOffset: to)
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: hold)
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
        sleep(1)
    }

    private func openLesson(_ app: XCUIApplication) -> (row: XCUIElement, heading: XCUIElement) {
        app.tabBars.buttons["Grammar"].tap()
        XCTAssertTrue(app.buttons["grammarLevel_N2"].waitForExistence(timeout: 15))
        app.buttons["grammarLevel_N2"].tap()
        let row = app.buttons["grammarEntry_N2|〜ぬく"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let heading = app.webViews["grammarLessonPage"].staticTexts["意思"]
        XCTAssertTrue(heading.waitForExistence(timeout: 20), "The lesson must render")
        sleep(1)
        return (row, heading)
    }

    func testSwipeFromTheMiddleOfADefinitionAndOfTheResults() {
        let app = launch(hold: true)
        openDefinition(app)
        // Let go a third of the way: held for the picture, then it finishes.
        drag(app, from: CGVector(dx: 0.3, dy: 0.5), to: CGVector(dx: 0.72, dy: 0.53))
        shot(app, "Slide · definition over the results (from the middle of the page)")
        let result = app.buttons["dictionaryResult_みほん"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10), "A swipe from the middle of the page goes back to the results")
        sleep(1)
        XCTAssertTrue(result.isHittable)
        shot(app, "Slide · back on the results")

        // From the results the swipe goes back to the tab Search was opened from.
        drag(app, from: CGVector(dx: 0.25, dy: 0.62), to: CGVector(dx: 0.8, dy: 0.6))
        shot(app, "Slide · results over the Read page")
        XCTAssertTrue(app.textViews["selectablePassage"].waitForExistence(timeout: 10), "The swipe ends on the Read tab")
    }

    func testScrollingAndShortSwipesStayOnTheLesson() {
        let app = launch()
        let (row, heading) = openLesson(app)
        let page = app.webViews["grammarLessonPage"]
        let top = heading.frame.minY
        page.swipeUp()
        sleep(1)
        XCTAssertLessThan(heading.frame.minY, top - 60, "The lesson scrolls as before")
        XCTAssertFalse(row.exists, "Scrolling never goes back")
        page.swipeDown()
        page.swipeDown()
        sleep(1)

        // A short sideways swipe: the page comes back and stays.
        drag(app, from: CGVector(dx: 0.3, dy: 0.5), to: CGVector(dx: 0.42, dy: 0.5))
        sleep(2)
        XCTAssertTrue(heading.isHittable, "A short swipe stays on the lesson")
        XCTAssertFalse(row.exists)

        // A long one from the middle goes back to the list, which is really the page again.
        drag(app, from: CGVector(dx: 0.2, dy: 0.55), to: CGVector(dx: 0.85, dy: 0.5))
        XCTAssertTrue(row.waitForExistence(timeout: 8), "A swipe from the middle of a lesson goes back to the list")
        sleep(1)
        XCTAssertTrue(row.isHittable)
        row.tap()
        XCTAssertTrue(heading.waitForExistence(timeout: 20), "A lesson opens again from the list")
    }

    func testInFullScreenTheEdgeStillGoesBack() {
        let app = launch()
        let (row, _) = openLesson(app)
        app.buttons["grammarRelated"].tap()
        let fullScreen = app.buttons["Full screen · 全螢幕"]
        XCTAssertTrue(fullScreen.waitForExistence(timeout: 5))
        fullScreen.tap()
        let tabs = app.tabBars.firstMatch
        let hidden = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: tabs)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, "Full screen hides the tabs and the title bar")
        sleep(1)
        shot(app, "Slide · lesson in full screen")
        drag(app, from: CGVector(dx: 0.01, dy: 0.5), to: CGVector(dx: 0.8, dy: 0.5))
        XCTAssertTrue(row.waitForExistence(timeout: 8), "With the title bar hidden, the edge swipe still goes back")
    }

    func testWithFromAnywhereOffOnlyTheEdgeGoesBack() {
        let app = launch(["--ui-swipe-edge-only"])
        openDefinition(app)
        drag(app, from: CGVector(dx: 0.3, dy: 0.5), to: CGVector(dx: 0.9, dy: 0.5))
        sleep(1)
        XCTAssertTrue(app.webViews.links["実物"].isHittable, "With From anywhere off, the middle of the page stays")
        drag(app, from: CGVector(dx: 0.02, dy: 0.5), to: CGVector(dx: 0.8, dy: 0.5))
        XCTAssertTrue(app.buttons["dictionaryResult_みほん"].firstMatch.waitForExistence(timeout: 8), "The edge goes back")
    }

    func testTheDictionaryCardAndASelectionKeepTheirTouches() {
        let app = launch()
        openDefinition(app)
        let page = app.webViews["dictionaryEntryPage"]
        let word = page.staticTexts["sample"]
        XCTAssertTrue(word.waitForExistence(timeout: 10))
        word.press(forDuration: 1.2)
        let card = app.otherElements["lookupPeek"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Selecting opens the card")
        sleep(1)
        shot(app, "Slide · card open")

        // With the card open, a sideways swipe on the page stays.
        drag(app, from: CGVector(dx: 0.3, dy: 0.42), to: CGVector(dx: 0.9, dy: 0.42))
        sleep(1)
        XCTAssertTrue(page.links["実物"].isHittable, "With the card open, the middle of the page does not go back")
        XCTAssertTrue(card.exists)

        // Card closed, text still selected: away from the selection the page goes back.
        app.buttons["closePeek"].tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5))
        sleep(1)
        drag(app, from: CGVector(dx: 0.3, dy: 0.55), to: CGVector(dx: 0.9, dy: 0.55))
        let result = app.buttons["dictionaryResult_みほん"].firstMatch
        let back = result.waitForExistence(timeout: 8)
        if !back { shot(app, "Slide · still on the definition with text selected") }
        XCTAssertTrue(back, "Away from a selection's handles, a swipe on the page goes back")
    }
}
