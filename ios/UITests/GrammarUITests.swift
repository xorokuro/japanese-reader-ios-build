import XCTest

final class GrammarUITests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch(theme: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-dictionary-fixture", "--ui-reset-search-keyboard"]
        if let theme { app.launchArguments += ["-readerThemePreset", theme] }
        app.launch()
        return app
    }

    func testGrammarIndexLessonAndLinks() {
        let app = launch()
        app.tabBars.buttons["Grammar"].tap()
        let first = app.buttons["grammarEntry_N5|〜は"]
        XCTAssertTrue(first.waitForExistence(timeout: 15), "The index must list the N5 patterns")
        shot(app, "Grammar index N5")

        app.buttons["grammarLevel_N2"].tap()
        let nuku = app.buttons["grammarEntry_N2|〜ぬく"]
        XCTAssertTrue(nuku.waitForExistence(timeout: 5))
        app.buttons["grammarLearned_N2|〜つつある"].tap()
        shot(app, "Grammar index N2 with one 已讀")

        nuku.tap()
        let page = app.webViews["grammarLessonPage"]
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        XCTAssertTrue(page.staticTexts["意思"].waitForExistence(timeout: 20), "The lesson must render")
        sleep(1)
        shot(app, "Grammar lesson top")
        page.swipeUp()
        sleep(1)
        shot(app, "Grammar lesson examples")

        XCTAssertTrue(page.links["→ 該句型詳解"].waitForExistence(timeout: 5))
        page.links["→ 該句型詳解"].tap()
        XCTAssertTrue(app.staticTexts["〜きる"].waitForExistence(timeout: 10), "A lesson link opens that lesson")
        shot(app, "Linked lesson")

        app.buttons["grammarLessonLearned"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["〜ぬく"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(nuku.waitForExistence(timeout: 5))

        let field = app.textFields["grammarSearchField"]
        field.tap()
        field.typeText("貫徹")
        XCTAssertTrue(app.buttons["grammarEntry_N2|〜ぬく"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["grammarEntry_N2|〜きる"].exists)
        shot(app, "Grammar search")
    }

    /// Open a lesson, scroll down, put the app away, quit it and launch it again:
    /// the lesson must come back at the same place, and opening it again from the
    /// list must land there too.
    func testGrammarLessonReopensWhereItWasLeftAfterRelaunch() {
        var app = XCUIApplication()
        app.launchArguments = ["--ui-dictionary-fixture", "--ui-reset-search-keyboard", "--ui-keep-session", "--ui-clear-session"]
        app.launch()
        app.tabBars.buttons["Grammar"].tap()
        XCTAssertTrue(app.buttons["grammarLevel_N2"].waitForExistence(timeout: 15))
        app.buttons["grammarLevel_N2"].tap()
        let nuku = app.buttons["grammarEntry_N2|〜ぬく"]
        XCTAssertTrue(nuku.waitForExistence(timeout: 5))
        nuku.tap()
        let page = app.webViews["grammarLessonPage"]
        let heading = page.staticTexts["意思"]
        XCTAssertTrue(heading.waitForExistence(timeout: 20))
        sleep(1)
        let top = heading.frame.minY
        page.swipeUp()
        page.swipeUp()
        sleep(2)
        let scrolled = heading.frame.minY
        XCTAssertLessThan(scrolled, top - 80, "The lesson must scroll for this test to mean anything")
        shot(app, "Lesson scrolled before quitting")

        XCUIDevice.shared.press(.home)
        sleep(2)
        app.terminate()

        app = XCUIApplication()
        app.launchArguments = ["--ui-dictionary-fixture", "--ui-reset-search-keyboard", "--ui-keep-session"]
        app.launch()
        let reopened = app.webViews["grammarLessonPage"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 20), "The lesson that was open comes back at launch")
        let again = reopened.staticTexts["意思"]
        XCTAssertTrue(again.waitForExistence(timeout: 20))
        sleep(3)
        shot(app, "Lesson after relaunch")
        XCTAssertEqual(again.frame.minY, scrolled, accuracy: 60, "Same scroll position after relaunch")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        // The test fixture resets the chosen level at every launch.
        XCTAssertTrue(app.buttons["grammarLevel_N2"].waitForExistence(timeout: 10))
        app.buttons["grammarLevel_N2"].tap()
        let row = app.buttons["grammarEntry_N2|〜ぬく"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let third = app.webViews["grammarLessonPage"].staticTexts["意思"]
        XCTAssertTrue(third.waitForExistence(timeout: 20))
        sleep(3)
        XCTAssertEqual(third.frame.minY, scrolled, accuracy: 60, "Opening it again from the list lands at the same place")
    }

    /// Look up a word selected in a lesson, then go Back: the lesson comes back
    /// (not a result list). Pulling the card down closes it.
    func testBackFromALessonLookupReturnsToTheLessonAndTheCardPullsDown() {
        let app = launch()
        app.tabBars.buttons["Grammar"].tap()
        XCTAssertTrue(app.buttons["grammarLevel_N2"].waitForExistence(timeout: 15))
        app.buttons["grammarLevel_N2"].tap()
        app.buttons["grammarEntry_N2|〜ぬく"].tap()
        let page = app.webViews["grammarLessonPage"]
        let word = page.staticTexts["意思"]
        XCTAssertTrue(word.waitForExistence(timeout: 20))
        sleep(1)

        // Pull the card down to close it.
        word.press(forDuration: 1.2)
        let card = app.otherElements["lookupPeek"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Selecting in a lesson opens the card")
        XCTAssertTrue(app.buttons["closePeek"].waitForExistence(timeout: 5))
        sleep(1)
        // Grab the card by its title row (beside the ✕) and pull it down, on screen.
        let title = app.buttons["closePeek"].coordinate(withNormalizedOffset: CGVector(dx: -3, dy: 0.5))
        title.press(forDuration: 0.1, thenDragTo: title.withOffset(CGVector(dx: 0, dy: 260)))
        let closed = card.waitForNonExistence(timeout: 5)
        if !closed { shot(app, "Card after pulling down") }
        XCTAssertTrue(closed, "Pulling the card down closes it")

        // Look it up in Search, then Back.
        word.press(forDuration: 1.2)
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        app.buttons["peekAllResults"].tap()
        let back = app.buttons["Back to Main Page"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "The lookup opens on the Search tab")
        shot(app, "Search after a lesson lookup")
        back.tap()
        XCTAssertTrue(app.webViews["grammarLessonPage"].waitForExistence(timeout: 10), "Back returns to the lesson")
        XCTAssertTrue(app.tabBars.buttons["Grammar"].isSelected)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    func testGrammarLessonInDarkTheme() {
        let app = launch(theme: "hand-engawa")
        app.tabBars.buttons["Grammar"].tap()
        app.buttons["grammarLevel_N2"].tap()
        let nuku = app.buttons["grammarEntry_N2|〜ぬく"]
        XCTAssertTrue(nuku.waitForExistence(timeout: 15))
        shot(app, "Grammar index dark")
        nuku.tap()
        let page = app.webViews["grammarLessonPage"]
        XCTAssertTrue(page.staticTexts["意思"].waitForExistence(timeout: 20))
        sleep(1)
        shot(app, "Grammar lesson dark")
        page.swipeUp()
        page.swipeUp()
        sleep(1)
        shot(app, "Grammar lesson dark quiz")
    }
}
