import XCTest

/// Screenshots of every tab in the 糸 Fable (Claude style) papers.
final class FableUITests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tour(theme: String) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-dictionary-fixture", "--ui-reset-search-keyboard", "--ui-clipboard",
                               "みほんの文章です。ゆっくり読んで、知らない言葉を調べましょう。", "-readerThemePreset", theme]
        app.launch()
        let reader = app.textViews["selectablePassage"]
        XCTAssertTrue(reader.waitForExistence(timeout: 10))
        app.buttons["pastePassage"].tap()
        sleep(1)
        shot(app, "Fable \(theme) · Read")

        app.tabBars.buttons["Search"].tap()
        sleep(1)
        let field = app.textFields["dictionarySearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("みほん")
        let result = app.buttons["dictionaryResult_みほん"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        shot(app, "Fable \(theme) · Search results")
        result.tap()
        XCTAssertTrue(app.webViews.links["実物"].waitForExistence(timeout: 30))
        sleep(1)
        shot(app, "Fable \(theme) · Definition")

        app.tabBars.buttons["Library"].tap()
        sleep(1)
        shot(app, "Fable \(theme) · Library")
        let appearance = app.buttons["openAppearance"]
        if appearance.waitForExistence(timeout: 3) {
            appearance.tap()
            sleep(1)
            shot(app, "Fable \(theme) · Appearance")
            app.swipeUp()
            sleep(1)
            shot(app, "Fable \(theme) · Appearance scrolled")
            app.navigationBars.buttons.firstMatch.tap()
        }

        app.tabBars.buttons["Grammar"].tap()
        app.buttons["grammarLevel_N2"].tap()
        let nuku = app.buttons["grammarEntry_N2|〜ぬく"]
        XCTAssertTrue(nuku.waitForExistence(timeout: 15))
        shot(app, "Fable \(theme) · Grammar index")
        nuku.tap()
        let page = app.webViews["grammarLessonPage"]
        XCTAssertTrue(page.staticTexts["意思"].waitForExistence(timeout: 20))
        sleep(1)
        shot(app, "Fable \(theme) · Grammar lesson")
    }

    func testFablePaperTour() { tour(theme: "fable") }
    func testFableNightTour() { tour(theme: "fable-night") }

    /// One quick look at each variation: Read, Grammar and Library.
    func testFableVariationsGallery() {
        for theme in ["fable-graph", "fable-sundown", "fable-midnight", "fable-mist", "fable-ballpoint", "fable-echo", "fable-roots"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-dictionary-fixture", "--ui-reset-search-keyboard", "--ui-clipboard",
                                   "みほんの文章です。ゆっくり読んで、知らない言葉を調べましょう。", "-readerThemePreset", theme]
            app.launch()
            XCTAssertTrue(app.textViews["selectablePassage"].waitForExistence(timeout: 10))
            app.buttons["pastePassage"].tap()
            sleep(1)
            shot(app, "Variation \(theme) · Read")
            app.tabBars.buttons["Grammar"].tap()
            app.buttons["grammarLevel_N2"].tap()
            XCTAssertTrue(app.buttons["grammarEntry_N2|〜ぬく"].waitForExistence(timeout: 15))
            shot(app, "Variation \(theme) · Grammar")
            app.tabBars.buttons["Library"].tap()
            sleep(1)
            shot(app, "Variation \(theme) · Library")
            app.terminate()
        }
    }
}
