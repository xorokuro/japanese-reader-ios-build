import XCTest
import SQLite3
@testable import JapaneseReader

@MainActor final class SearchBehaviorTests: XCTestCase {
    func testUncompressedDictionaryPreviewAndGlobalSwitcher() async throws {
        let root = UITestFixture.documents()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ReaderModel(documents: root)
        try await settle(model)
        model.searchScope = "base:DEMO_A"
        model.word = "みほん"
        model.search(dismissKeyboard: false)
        try await settle(model)
        XCTAssertEqual(model.hits.count, 2)
        let first = try XCTUnwrap(model.hits.first)
        XCTAssertTrue(first.preview.contains("見本"))
        model.open(first)
        try await settle(model)
        XCTAssertTrue(model.entryHTML.contains("見本"))
        XCTAssertEqual(Set(model.entryMatches.map(\.code)), Set(["DEMO_A", "DEMO_B"]))
    }
    func testPromptUsesActualSelectionAndFallsBackToPassage() throws {
        let (model, root, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        model.text = "今日は日本語を勉強します。"
        model.word = "stale search query"
        XCTAssertTrue(model.prompt().hasSuffix(model.text))
        XCTAssertFalse(model.prompt().contains("stale search query"))
        model.readerSelection = "日本語"
        XCTAssertTrue(model.prompt().hasSuffix("\n\n日本語"))
        XCTAssertFalse(model.prompt().contains(model.text))
        model.dictionarySelection = "勉強"
        XCTAssertTrue(model.prompt(inDictionary: true).hasSuffix("\n\n勉強"))
        model.dictionarySelection = ""
        XCTAssertTrue(model.prompt(inDictionary: true).hasSuffix(model.text))
        model.readerSelection = "  "
        XCTAssertTrue(model.prompt().hasSuffix(model.text))
        model.readerSelection = "日本語"
        model.text = "新しい文章"
        XCTAssertEqual(model.readerSelection, "")
        XCTAssertTrue(model.prompt().hasSuffix("新しい文章"))
    }
    func testBackFromNestedSelectionResultsRestoresPreviousEntry() async throws {
        let (model, root, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        try await settle(model)
        model.word = "原因"; model.search(dismissKeyboard: false)
        try await settle(model)
        model.open(try XCTUnwrap(model.hits.first))
        try await settle(model)
        let entry = model.entryID
        model.entryOffsets[entry] = CGPoint(x: 0, y: 150)
        model.select("原因論", inDictionary: true)
        try await settle(model)
        XCTAssertFalse(model.showingEntry)
        XCTAssertTrue(model.canGoBack)
        model.open(try XCTUnwrap(model.hits.first))
        try await settle(model)
        model.backToPreviousEntry()
        XCTAssertFalse(model.showingEntry, "Back returns to the results page that opened this entry")
        XCTAssertEqual(model.word, "原因論")
        model.backToPreviousEntry()
        XCTAssertEqual(model.entryID, entry)
        XCTAssertTrue(model.showingEntry)
        XCTAssertEqual(model.entryOffsets[entry]?.y, 150)
        model.backToPreviousEntry()
        XCTAssertFalse(model.showingEntry)
        XCTAssertEqual(model.word, "原因")
        XCTAssertFalse(model.canGoBack)
    }
    private func fixture() throws -> (ReaderModel, URL, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dictionaries = root.appendingPathComponent("dictionaries")
        try FileManager.default.createDirectory(at: dictionaries, withIntermediateDirectories: true)
        try Data().write(to: dictionaries.appendingPathComponent("test.mdx"))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dictionaries.appendingPathComponent("mdict-index.sqlite3").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE dictionaries(code TEXT,name TEXT,root TEXT,css TEXT);
        CREATE TABLE files(id INTEGER,code TEXT,path TEXT,kind TEXT,size INTEGER,encoding TEXT);
        CREATE TABLE records(id INTEGER,file INTEGER,word TEXT,norm TEXT,start INTEGER,end INTEGER);
        CREATE TABLE blocks(file INTEGER,start INTEGER,end INTEGER,offset INTEGER,size INTEGER);
        INSERT INTO dictionaries VALUES('TEST','Test dictionary','.','');
        INSERT INTO files VALUES(1,'TEST','test.mdx','.mdx',0,'utf-8');
        INSERT INTO records VALUES(1,1,'原因','原因',0,0);
        INSERT INTO records VALUES(2,1,'原因論','原因論',0,0);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let suite = "SearchBehaviorTests." + UUID().uuidString
        let model = ReaderModel(documents: root, preferences: UserDefaults(suiteName: suite)!)
        return (model, root, suite)
    }
    private func settle(_ model: ReaderModel) async throws {
        // A serial queue barrier delivers completion after all queued lookups.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            model.queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
    }
    func testExactModeLiveTypingAndClearCancelOldResults() async throws {
        let (model, root, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        try await settle(model)
        model.searchMode = .exact
        model.word = "原因"; model.search(dismissKeyboard: false)
        try await settle(model)
        XCTAssertEqual(model.hits.map(\.word), ["原因"])
        model.searchMode = .prefix
        model.typedSearch("原因")
        model.typedSearch("")
        try await Task.sleep(nanoseconds: 250_000_000)
        try await settle(model)
        XCTAssertTrue(model.hits.isEmpty)
        model.typedSearch("原")
        try await Task.sleep(nanoseconds: 250_000_000)
        try await settle(model)
        XCTAssertEqual(model.hits.map(\.word), ["原因", "原因論"])
        XCTAssertFalse(model.showingEntry)
    }
    func testEntryLinkBackAndDictionarySwitchHistory() async throws {
        let (model, root, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        try await settle(model)
        model.word = "原因"; model.search(dismissKeyboard: false)
        try await settle(model)
        let first = try XCTUnwrap(model.hits.first)
        model.open(first)
        try await settle(model)
        let originalID = model.entryID
        model.entryOffsets[originalID] = CGPoint(x: 0, y: 120)
        XCTAssertEqual(model.visits.count, 1)
        model.followEntryLink("原因論")
        try await settle(model); try await settle(model)
        XCTAssertEqual(model.entryTitle, "原因論")
        XCTAssertEqual(model.visits.count, 2)
        model.open(first, replacingCurrent: true)
        try await settle(model)
        XCTAssertEqual(model.visits.count, 2, "Changing dictionaries replaces the current visit")
        model.backToPreviousEntry()
        XCTAssertEqual(model.entryID, originalID)
        XCTAssertEqual(model.entryOffsets[originalID]?.y, 120)
        model.backToPreviousEntry()
        XCTAssertFalse(model.showingEntry)
    }
    func testIndependentDefaultsPersistenceAndManualSearch() async throws {
        let (model, root, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        try await settle(model)
        XCTAssertTrue(model.readerAutoSearch)
        XCTAssertTrue(model.dictionaryAutoSearch)
        model.readerAutoSearch = false
        model.select("原", inDictionary: false)
        XCTAssertEqual(model.readerSelection, "原")
        XCTAssertFalse(model.showingLookup)
        XCTAssertTrue(model.dictionaryAutoSearch)
        model.searchSelected(inDictionary: false)
        try await settle(model)
        XCTAssertTrue(model.showingLookup)
        XCTAssertEqual(model.hits.map(\.word), ["原因", "原因論"])
        model.closeLookup()
        model.select("原因", inDictionary: true)
        try await settle(model)
        XCTAssertTrue(model.showingLookup)
        XCTAssertFalse(model.showingEntry)
        model.closeLookup()
        model.dictionaryAutoSearch = false
        model.readerAutoSearch = true
        model.select("原因", inDictionary: true)
        XCTAssertFalse(model.showingLookup)
        model.select("原因", inDictionary: false)
        try await settle(model)
        XCTAssertTrue(model.showingLookup)
        let restored = ReaderModel(documents: root, preferences: UserDefaults(suiteName: suite)!)
        try await settle(restored)
        XCTAssertTrue(restored.readerAutoSearch)
        XCTAssertFalse(restored.dictionaryAutoSearch)
    }
    func testNoMatchAndCancelledSearchDoNotNavigate() async throws {
        let (model, root, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        try await settle(model)
        model.select("not found", inDictionary: false)
        try await settle(model)
        XCTAssertFalse(model.showingLookup)
        XCTAssertTrue(model.hits.isEmpty)
        model.select("原因", inDictionary: false)
        model.closeLookup()
        try await settle(model)
        XCTAssertFalse(model.showingLookup)
        model.select("原因", inDictionary: false)
        model.readerAutoSearch = false
        try await settle(model)
        XCTAssertFalse(model.showingLookup)
    }
}
