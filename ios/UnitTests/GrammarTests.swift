import XCTest
@testable import JapaneseReader

final class GrammarTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GrammarTest-" + UUID().uuidString)
        try GrammarFixture.write(to: root)
        return root
    }

    func testIndexPageIsReadWithItsOwnScripts() throws {
        let index = try GrammarIndexParser.parse(root: try fixture())
        XCTAssertEqual(index.levels, ["N5", "N2"])
        XCTAssertEqual(index.entries.count, 5)
        XCTAssertEqual(index.meta["N2"], "中高級：書面機能語")
        let nuku = try XCTUnwrap(index.entries.first { $0.pattern == "〜ぬく" })
        XCTAssertEqual(nuku.code, "N2-001")
        XCTAssertEqual(nuku.file, "N2_ぬく.html")
        XCTAssertEqual(nuku.revision, "20260927-v2")
        XCTAssertEqual(nuku.refs.first?.pattern, "〜きる")
        XCTAssertEqual(nuku.id, "N2|〜ぬく")
        let kiru = try XCTUnwrap(index.entries.first { $0.pattern == "〜きる" })
        XCTAssertNil(kiru.revision)
        XCTAssertNil(index.entries.first { $0.pattern == "〜が（主語）" }?.file)
    }

    func testMissingIndexPageIsReported() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("GrammarEmpty-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try GrammarIndexParser.parse(root: empty))
    }

    func testNormalizeMatchesDesktopSearch() {
        XCTAssertEqual(GrammarIndexParser.normalize("〜が（主語）"), "が")
        XCTAssertEqual(GrammarIndexParser.normalize("〜ところに・〜ところへ"), "ところにところへ")
    }

    func testLessonPageDropsScriptsAndMovesReadings() {
        let html = GrammarLessonHTML.make(source: GrammarFixture.lesson(level: "N2", title: "〜ぬく", reading: "ぬく", summary: "s", link: "N2_きる.html"),
                                          css: "/*theme*/")
        XCTAssertFalse(html.contains("alert(1)"))
        XCTAssertFalse(html.contains("color:red"))
        XCTAssertFalse(html.contains("class=\"back\""))
        XCTAssertTrue(html.contains("<ruby>抜<rt data-r=\"ぬ\"></rt></ruby>"))
        XCTAssertFalse(html.contains("<rt>"))
        XCTAssertTrue(html.contains("href=\"N2_きる.html\""))
        XCTAssertTrue(html.contains("/*theme*/"))
        XCTAssertTrue(html.contains("script-src 'none'"))
    }

    @MainActor func testStoreLoadsImportedFolderAndKeepsProgress() throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent("GrammarDocs-" + UUID().uuidString)
        try GrammarFixture.write(to: documents.appendingPathComponent("Grammar"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "GrammarTests-" + UUID().uuidString))
        let store = GrammarStore(documents: documents, preferences: defaults, bundled: nil)
        let loaded = expectation(description: "index loaded")
        func poll() {
            if store.index != nil { loaded.fulfill() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll) }
        }
        poll()
        wait(for: [loaded], timeout: 10)
        let nuku = try XCTUnwrap(store.entry(id: "N2|〜ぬく"))
        XCTAssertNotNil(store.lessonURL(nuku))
        XCTAssertEqual(store.entry(file: "N2_きる.html")?.pattern, "〜きる")
        XCTAssertEqual(store.neighbour(of: nuku, step: 1)?.pattern, "〜きる")
        XCTAssertNil(store.neighbour(of: nuku, step: -1))
        XCTAssertEqual(store.search("ぬく").map(\.pattern), ["〜ぬく"])
        XCTAssertEqual(store.search("貫徹").map(\.pattern), ["〜ぬく"])
        store.toggleLearned(nuku)
        XCTAssertTrue(store.isLearned(nuku))
        XCTAssertEqual(defaults.stringArray(forKey: GrammarStore.learnedKey), ["N2|〜ぬく"])
        let exported = try store.progressExport()
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: exported)) as? [String: Any]
        XCTAssertEqual(object?["done"] as? [String], ["N2|〜ぬく"])
        XCTAssertEqual(object?["app"] as? String, "JLPT文法總目錄N5-N1")
    }
}
