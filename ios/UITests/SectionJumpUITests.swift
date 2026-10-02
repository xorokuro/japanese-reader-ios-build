import XCTest

/// 目次: the section button opens the list of sections and jumps to the chosen one.
final class SectionJumpUITests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch(theme: String = "fable") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-dictionary-fixture", "--ui-reset-search-keyboard", "-readerThemePreset", theme]
        app.launch()
        return app
    }

    func testLibraryAndAppearanceSections() {
        let app = launch()
        app.tabBars.buttons["Library"].tap()
        let jump = app.buttons["sectionJump"].firstMatch
        XCTAssertTrue(jump.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Translation"].isHittable, "Translation starts below the screen")
        jump.tap()
        XCTAssertTrue(app.buttons["sectionJump_8"].waitForExistence(timeout: 5))
        shot(app, "Jump · Library sections")
        app.buttons["sectionJump_8"].tap()
        sleep(2)
        shot(app, "Jump · Library at Translation")
        XCTAssertTrue(app.staticTexts["Translation"].isHittable, "The list jumped to Translation")

        // Appearance: its own list, and the icon presets.
        app.buttons["sectionJump"].firstMatch.tap()
        XCTAssertTrue(app.buttons["sectionJump_0"].waitForExistence(timeout: 5))
        app.buttons["sectionJump_0"].tap()
        sleep(2)
        app.swipeDown()
        app.swipeDown()
        app.buttons["openAppearance"].tap()
        let pageJump = app.buttons["sectionJump"].firstMatch
        XCTAssertTrue(pageJump.waitForExistence(timeout: 10))
        pageJump.tap()
        XCTAssertTrue(app.buttons["sectionJump_6"].waitForExistence(timeout: 5))
        shot(app, "Jump · Appearance sections")
        app.buttons["sectionJump_6"].tap()
        sleep(2)
        shot(app, "Jump · Appearance at Section button")
        let compass = app.buttons["jumpIcon_compass"]
        XCTAssertTrue(compass.waitForExistence(timeout: 5), "The icon presets are on screen after the jump")
        compass.tap()
        sleep(1)
        shot(app, "Jump · icon preset chosen")
    }

    func testGrammarListAndLessonSections() {
        let app = launch(theme: "fable-still")
        app.tabBars.buttons["Grammar"].tap()
        app.buttons["grammarLevel_N2"].tap()
        let nuku = app.buttons["grammarEntry_N2|〜ぬく"]
        XCTAssertTrue(nuku.waitForExistence(timeout: 15))
        shot(app, "Jump · Grammar list")
        nuku.tap()
        let page = app.webViews["grammarLessonPage"]
        XCTAssertTrue(page.staticTexts["意思"].waitForExistence(timeout: 20))
        let jump = app.buttons["sectionJump"].firstMatch
        XCTAssertTrue(jump.waitForExistence(timeout: 10))
        jump.tap()
        XCTAssertTrue(app.buttons["sectionJump_1"].waitForExistence(timeout: 8), "The lesson reports its sections")
        shot(app, "Jump · Lesson sections")
        let last = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sectionJump_'")).count - 1
        app.buttons["sectionJump_\(last)"].tap()
        sleep(2)
        shot(app, "Jump · Lesson at last section")
    }
}
