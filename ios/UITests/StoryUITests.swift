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
        XCTAssertTrue(app.buttons["storySave"].exists, "The page on the web offers to save the story on the phone")
        word.press(forDuration: 1.2)
        let card = app.otherElements["lookupPeek"]
        let opened = card.waitForExistence(timeout: 10)
        shot(app, "Story lookup")
        XCTAssertTrue(opened, "Selecting a word in the story opens the dictionary card")
    }

    /// The story saved on the phone (存到手機) opens from the app's own files, keeps its storage, and
    /// a word selected in it opens the dictionary card.
    func testTheStorySavedOnThePhoneOpensAndLooksUpWords() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-dictionary-fixture", "--ui-reset-search-keyboard", "--ui-story-local-fixture"]
        app.launch()
        app.tabBars.buttons["Stories"].tap()
        let page = app.webViews["storyPage"]
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        let word = page.staticTexts["意思"]
        let loaded = word.waitForExistence(timeout: 20)
        shot(app, "Saved story")
        XCTAssertTrue(loaded, "The saved page must load its data from the phone (texts: \(page.staticTexts.allElementsBoundByIndex.prefix(6).map(\.label)))")
        XCTAssertTrue(page.staticTexts["storage ok"].waitForExistence(timeout: 5), "The saved page has its storage and knows it is the copy on the phone")
        XCTAssertFalse(app.buttons["storySave"].exists, "A saved story is not offered for saving")
        sleep(1)
        word.press(forDuration: 1.2)
        let card = app.otherElements["lookupPeek"]
        let opened = card.waitForExistence(timeout: 10)
        shot(app, "Saved story lookup")
        XCTAssertTrue(opened, "Selecting a word in the saved story opens the dictionary card")
    }
}
