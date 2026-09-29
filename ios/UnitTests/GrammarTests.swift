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

    func testListRowsAreFlatUniqueAndInOrder() {
        func entry(_ number: Int, _ category: String, _ pattern: String) -> GrammarEntry {
            GrammarEntry(level: "N1", category: category, pattern: pattern, meaning: "", number: number,
                         refs: [], file: nil, revision: nil)
        }
        let entries = [entry(1, "時間", "〜が早いか"), entry(2, "時間", "〜や"), entry(3, "限定", "〜をもって"),
                       entry(4, "時間", "〜そばから"), entry(5, "時間", "〜や")]
        let items = GrammarListItem.build(entries, grouped: true)
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "every row needs its own id")
        let headers = items.compactMap { item -> String? in
            if case .header(let title, let count, _) = item.kind { return "\(title)\(count)" }
            return nil
        }
        XCTAssertEqual(headers, ["時間2", "限定1", "時間2"])
        let numbers = items.compactMap { item -> Int? in
            if case .entry(let entry) = item.kind { return entry.number }
            return nil
        }
        XCTAssertEqual(numbers, [1, 2, 3, 4, 5])
        let flat = GrammarListItem.build(entries, grouped: false)
        XCTAssertEqual(flat.count, 5)
        XCTAssertEqual(Set(flat.map(\.id)).count, 5)
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

    func testBuiltInLessonsWithPlainFileNamesAreRestored() throws {
        let original = try fixture()
        let packed = FileManager.default.temporaryDirectory.appendingPathComponent("GrammarPacked-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: packed.appendingPathComponent("lessons"), withIntermediateDirectories: true)
        var names: [String: String] = [:]
        let files = ["JLPT文法總目錄N5-N1.html", "lessons/manifest.js", "lessons/N2_ぬく.html", "lessons/N2_きる.html", "lessons/N5_は.html"]
        for (index, file) in files.enumerated() {
            let plain = index == 0 ? "index.html" : "lessons/g\(index).dat"
            try FileManager.default.copyItem(at: original.appendingPathComponent(file), to: packed.appendingPathComponent(plain))
            names[plain] = file
        }
        try JSONEncoder().encode(names).write(to: packed.appendingPathComponent("names.json"))
        let root = try XCTUnwrap(GrammarStore.unpackBuiltIn(packed))
        let index = try GrammarIndexParser.parse(root: root)
        XCTAssertEqual(index.entries.count, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("lessons/N2_ぬく.html").path))
        XCTAssertEqual(GrammarStore.unpackBuiltIn(packed), root, "Unpacked once per build")
    }

    @MainActor func testOpenLessonsScrollAndListPlaceSurviveARelaunch() throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent("GrammarDocs-" + UUID().uuidString)
        try GrammarFixture.write(to: documents.appendingPathComponent("Grammar"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "GrammarTests-" + UUID().uuidString))
        func loaded(_ store: GrammarStore) {
            let done = expectation(description: "index loaded")
            func poll() { if store.index != nil { done.fulfill() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll) } }
            poll()
            wait(for: [done], timeout: 10)
        }
        let store = GrammarStore(documents: documents, preferences: defaults, bundled: nil)
        loaded(store)
        store.path = ["N2|〜ぬく", "N2|〜きる"]
        store.offsets["N2|〜きる"] = CGPoint(x: 0, y: 1500)
        store.listTop["N2"] = "N2|〜きる"
        var state = SessionState()
        store.fill(&state)
        let session = documents.appendingPathComponent("session.json")
        state.write(to: session)

        let reopened = GrammarStore(documents: documents, preferences: defaults, bundled: nil)
        var saved = try XCTUnwrap(SessionState.load(from: session))
        saved.grammarPath.append("N2|〜なくなった句型")
        reopened.restore(saved)
        loaded(reopened)
        XCTAssertEqual(reopened.path, ["N2|〜ぬく", "N2|〜きる"], "Open lessons come back; ones no longer in the index are dropped")
        XCTAssertEqual(reopened.offsets["N2|〜きる"]?.y, 1500)
        XCTAssertEqual(reopened.listTop["N2"], "N2|〜きる")
    }

    @MainActor func testListPlaceMapsBetweenRowsAndPatterns() {
        func entry(_ number: Int, _ category: String, _ pattern: String) -> GrammarEntry {
            GrammarEntry(level: "N1", category: category, pattern: pattern, meaning: "", number: number,
                         refs: [], file: nil, revision: nil)
        }
        let items = GrammarListItem.build([entry(1, "時間", "〜が早いか"), entry(2, "時間", "〜や"), entry(3, "限定", "〜をもって")], grouped: true)
        guard case .header = items[0].kind, case .header = items[3].kind else { return XCTFail("expected group headings") }
        XCTAssertEqual(GrammarTab.pattern(at: items[0].id, in: items), "N1|〜が早いか", "A heading stands for its first pattern")
        XCTAssertEqual(GrammarTab.pattern(at: items[2].id, in: items), "N1|〜や")
        XCTAssertEqual(GrammarTab.listRow(for: "N1|〜をもって", in: items), items[3].id, "The first pattern of a group comes back with its heading")
        XCTAssertEqual(GrammarTab.listRow(for: "N1|〜や", in: items), items[2].id)
        XCTAssertNil(GrammarTab.listRow(for: "N1|missing", in: items))
    }

    func testCardButtonOrderIsKeptAndRepaired() {
        XCTAssertEqual(PeekAction.order(from: PeekAction.standard), [.results, .translate, .copy, .share])
        XCTAssertEqual(PeekAction.order(from: "copy,bogus,copy,results"), [.copy, .results, .translate, .share],
                       "Unknown or repeated names are dropped and missing buttons come back")
        let order = PeekAction.order(from: PeekAction.standard)
        XCTAssertEqual(PeekAction.moving(.copy, to: .results, in: order), [.copy, .results, .translate, .share])
        XCTAssertEqual(PeekAction.moving(.results, to: .copy, in: order), [.translate, .copy, .results, .share])
        XCTAssertEqual(order.filter { $0.applies(long: false) }, [.results, .translate, .copy])
        XCTAssertEqual(order.filter { $0.applies(long: true) }, [.translate, .copy, .share])
    }
}
