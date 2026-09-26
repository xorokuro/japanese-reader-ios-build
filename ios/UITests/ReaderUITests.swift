import XCTest

final class ReaderUITests: XCTestCase {
    /// Result groups collapse with an animation, so rows can linger briefly.
    private func waitForResultCount(_ app: XCUIApplication, _ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let rows = app.buttons.matching(identifier: "dictionaryResult_みほん")
        let settled = expectation(for: NSPredicate(format: "count == %d", count), evaluatedWith: rows)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed, "Expected \(count) みほん rows", file: file, line: line)
    }
    func testDictionaryResultGroupsCollapseIndependently() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-dictionary-fixture", "--ui-reset-search-keyboard"]
        app.launch()
        app.tabBars.buttons["Search"].tap()
        let field = app.textFields["dictionarySearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("みほん")
        XCTAssertTrue(app.buttons["dictionaryResult_みほん"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["dismissKeyboard"].tap()
        let first = app.buttons["dictionaryGroup_results:base:DEMO_A"]
        let second = app.buttons["dictionaryGroup_results:base:DEMO_B"]
        XCTAssertEqual(first.value as? String, "Expanded")
        first.tap()
        XCTAssertEqual(first.value as? String, "Collapsed")
        XCTAssertTrue(second.isHittable)
        waitForResultCount(app, 1)
        second.tap()
        XCTAssertEqual(second.value as? String, "Collapsed")
        XCTAssertTrue(app.buttons["dictionaryResult_みほん"].waitForNonExistence(timeout: 5))
        first.tap()
        XCTAssertEqual(first.value as? String, "Expanded")
        XCTAssertEqual(second.value as? String, "Collapsed")
        waitForResultCount(app, 1)
        app.buttons["dictionaryResult_みほん"].tap()
        XCTAssertTrue(app.webViews["dictionaryEntryPage"].waitForExistence(timeout: 10))
        app.buttons["Back"].tap()
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertEqual(second.value as? String, "Collapsed")
    }

    func testLiveJapaneseSearchDictionarySwitcherAndBack() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-dictionary-fixture", "--ui-reset-search-keyboard"]
        app.launch()
        app.tabBars.buttons["Search"].tap()
        let field = app.textFields["dictionarySearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let scope = app.buttons["searchScope_base:DEMO_A"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        scope.tap()
        field.tap()
        field.typeText("みほん")
        let result = app.buttons["dictionaryResult_みほん"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15), "Search must happen without tapping submit")
        XCTAssertTrue(app.buttons["dictionaryResult_みほんいち"].firstMatch.exists)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let searchShot = XCTAttachment(screenshot: app.screenshot())
        searchShot.name = "Live Japanese prefix results"; searchShot.lifetime = .keepAlways; add(searchShot)
        result.tap()
        XCTAssertTrue(app.webViews["dictionaryEntryPage"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.links["実物"].waitForExistence(timeout: 30), "The actual definition must render")
        XCTAssertTrue(app.tabBars.buttons["Read"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["switchDictionary"].tap()
        XCTAssertTrue(app.staticTexts["Demo English–Japanese"].waitForExistence(timeout: 5))
        let switchShot = XCTAttachment(screenshot: app.screenshot())
        switchShot.name = "Dictionary switcher"; switchShot.lifetime = .keepAlways; add(switchShot)
        app.buttons.matching(identifier: "dictionaryResult_みほん").element(boundBy: 1).tap()
        XCTAssertTrue(app.webViews.links["実物"].waitForExistence(timeout: 15))
        let entryShot = XCTAttachment(screenshot: app.screenshot())
        entryShot.name = "Entry with persistent tabs"; entryShot.lifetime = .keepAlways; add(entryShot)
        app.webViews.links["実物"].tap()
        XCTAssertTrue(app.webViews.links["製品"].waitForExistence(timeout: 15))
        app.webViews.links["製品"].tap()
        XCTAssertTrue(app.webViews.staticTexts["product"].waitForExistence(timeout: 15))
        let page = app.webViews["dictionaryEntryPage"]
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).press(forDuration: 0.1, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))
        XCTAssertTrue(app.webViews.links["製品"].waitForExistence(timeout: 15))
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).press(forDuration: 0.1, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        XCTAssertTrue(app.webViews.links["実物"].waitForExistence(timeout: 15))
        app.buttons["Back"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["searchOptions"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Show search keyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText("missing")
        XCTAssertEqual(field.value as? String, "missing")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.35)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.35)))
        XCTAssertTrue(app.textViews["selectablePassage"].waitForExistence(timeout: 5))
    }
    func testSubmittedSearchAppearsInHistoryAndCanBeReopened() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-dictionary-fixture", "--ui-reset-search-keyboard"]
        app.launch()
        app.tabBars.buttons["Search"].tap()
        let field = app.textFields["dictionarySearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("みほん")
        app.buttons["Search dictionaries"].tap()
        app.buttons["searchOptions"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Search history"].tap()
        let query = app.buttons["みほん"].firstMatch
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        query.tap()
        XCTAssertEqual(field.value as? String, "みほん")
        XCTAssertTrue(app.buttons["dictionaryResult_みほん"].firstMatch.waitForExistence(timeout: 15))
    }
    func testSearchTabAlwaysFocusesAndReplacesTextEvenWithPreferenceOff() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-reset-search-keyboard"]
        app.launch()
        app.tabBars.buttons["Search"].tap()
        let field = app.textFields["dictionarySearchField"]
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText("previous")
        app.buttons["dismissKeyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText("next")
        XCTAssertEqual(field.value as? String, "next")
        app.buttons["keyboardSearchTab"].tap()
        field.typeText("fresh")
        XCTAssertEqual(field.value as? String, "fresh")
        app.buttons["keyboardLibraryTab"].tap()
        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText("again")
        XCTAssertEqual(field.value as? String, "again")
    }
    func testPasteReadsImmediatelyAndClearCanBeUndone() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-dictionary-fixture", "--ui-clipboard", "みほん"]
        app.launch()
        let reader = app.textViews["selectablePassage"]
        XCTAssertTrue(reader.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(reader.frame.height, app.frame.height * 0.6)
        XCTAssertFalse(app.segmentedControls["Reading mode"].exists)
        XCTAssertFalse(app.buttons["openPassage"].exists)
        app.buttons["pastePassage"].tap()
        XCTAssertEqual(reader.value as? String, "みほん")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Single screen paste and read"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["clearPassage"].tap()
        XCTAssertEqual(reader.value as? String, "")
        app.buttons["undoClearPassage"].tap()
        XCTAssertEqual(reader.value as? String, "みほん")
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.09, dy: 0.045)).press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["dictionaryResult_みほん"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["Back to Main Page"].tap()
        XCTAssertEqual(reader.value as? String, "みほん")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    func testAutoSaveHappensOnPaste() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-dictionary-fixture", "--ui-clipboard", "Auto-saved passage"]
        app.launch()
        XCTAssertTrue(app.textViews["selectablePassage"].waitForExistence(timeout: 10))
        // UI fixture runs start with the normal default: auto-save off.
        app.buttons["pastePassage"].tap()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["emptyLibrary"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Read"].tap()
        app.buttons["readerOptions"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Auto-save pasted passages"].tap()
        app.buttons["pastePassage"].tap()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["Auto-saved passage"].waitForExistence(timeout: 5))
        app.buttons["Auto-saved passage"].tap()
        XCTAssertEqual(app.textViews["selectablePassage"].value as? String, "Auto-saved passage")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    func testPasteReplacementAndManualSave() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-dictionary-fixture", "--ui-clipboard", "Clipboard passage"]
        app.launch()
        let reader = app.textViews["selectablePassage"]
        XCTAssertTrue(reader.waitForExistence(timeout: 10))
        app.buttons["pastePassage"].tap()
        XCTAssertEqual(reader.value as? String, "Clipboard passage")
        app.buttons["readerOptions"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Copy learning prompt"].tap()
        app.buttons["pastePassage"].tap()
        XCTAssertTrue((reader.value as? String ?? "").contains("Help me study this Japanese passage."))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["readerOptions"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Save"].tap()
        app.tabBars.buttons["Library"].tap()
        XCTAssertFalse(app.staticTexts["emptyLibrary"].exists)
        app.tabBars.buttons["Read"].tap()
        XCTAssertTrue(reader.exists)
    }
}
