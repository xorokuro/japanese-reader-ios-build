import XCTest

final class StoryUITests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 物語 is the fifth tab; with no link it asks for one. The other four tabs are all still there.
    func testStoriesTabAsksForALink() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-dictionary-fixture", "--ui-reset-search-keyboard", "--ui-story-reset"]
        app.launch()
        for tab in ["Read", "Search", "Library", "Grammar", "Stories"] {
            XCTAssertTrue(app.tabBars.buttons[tab].waitForExistence(timeout: 10), "The \(tab) tab must be there")
        }
        app.tabBars.buttons["Stories"].tap()
        XCTAssertTrue(app.staticTexts["storySetupTitle"].waitForExistence(timeout: 10), "Without a link the tab asks for one")
        XCTAssertTrue(app.textFields["storyLinkField"].exists)
        shot(app, "Stories setup")
    }

    /// A word selected in the story opens the dictionary card, as in 文法 lessons.
    func testSelectingAWordInTheStoryOpensTheCard() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-dictionary-fixture", "--ui-reset-search-keyboard", "--ui-story-fixture"]
        app.launch()
        app.tabBars.buttons["Stories"].tap()
        let page = app.webViews["storyPage"]
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        let word = page.staticTexts["意思"]
        XCTAssertTrue(word.waitForExistence(timeout: 20), "The story page must render")
        sleep(1)
        shot(app, "Story page")
        word.press(forDuration: 1.2)
        let card = app.otherElements["lookupPeek"]
        let opened = card.waitForExistence(timeout: 10)
        shot(app, "Story lookup")
        XCTAssertTrue(opened, "Selecting a word in the story opens the dictionary card")
    }
}
