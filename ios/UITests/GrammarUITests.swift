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
