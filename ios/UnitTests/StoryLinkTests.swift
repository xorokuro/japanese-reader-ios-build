import XCTest
@testable import JapaneseReader

final class StoryLinkTests: XCTestCase {
    func testTheKeyIsOpenedOnceAndNotKept() throws {
        let link = try XCTUnwrap(StoryLink.parse("  https://example.github.io/reader/#k=abcDEF123_-  "))
        XCTAssertEqual(link.open.absoluteString, "https://example.github.io/reader/#k=abcDEF123_-")
        XCTAssertEqual(link.keep.absoluteString, "https://example.github.io/reader/")
    }

    func testTheLinkIsFoundInsideCopiedText() throws {
        let link = try XCTUnwrap(StoryLink.parse("Open this in Safari:\nhttps://example.github.io/reader/#k=abc and enjoy"))
        XCTAssertEqual(link.keep.absoluteString, "https://example.github.io/reader/")
    }

    func testOnlyHttpsLinksAreTaken() {
        XCTAssertNil(StoryLink.parse("http://example.com/reader/"))
        XCTAssertNil(StoryLink.parse("not a link"))
        XCTAssertNil(StoryLink.parse(""))
    }

    func testOnlyThePagesOwnSiteOpensInsideTheTab() throws {
        let home = try XCTUnwrap(URL(string: "https://example.github.io/reader/"))
        XCTAssertTrue(StoryLink.sameSite(try XCTUnwrap(URL(string: "https://example.github.io/reader/?v=2")), as: home))
        XCTAssertTrue(StoryLink.sameSite(try XCTUnwrap(URL(string: "https://EXAMPLE.github.io/other/")), as: home))
        XCTAssertFalse(StoryLink.sameSite(try XCTUnwrap(URL(string: "https://github.com/settings")), as: home))
        XCTAssertFalse(StoryLink.sameSite(try XCTUnwrap(URL(string: "http://example.github.io/reader/")), as: home))
    }

    /// 存到手機 fetches the story's files from the page's folder.
    func testThePagesFolderIsWhereItsFilesAre() throws {
        func folder(_ text: String) throws -> String? { StoryLink.folder(of: try XCTUnwrap(URL(string: text)))?.absoluteString }
        XCTAssertEqual(try folder("https://example.github.io/reader/"), "https://example.github.io/reader/")
        XCTAssertEqual(try folder("https://example.github.io/reader/index.html?v=2#k=abc"), "https://example.github.io/reader/")
        XCTAssertEqual(try folder("https://example.github.io/reader"), "https://example.github.io/reader/")
        XCTAssertEqual(try folder("https://example.github.io"), "https://example.github.io/")
        XCTAssertNil(try folder("http://example.github.io/reader/"))
        XCTAssertNil(try folder("jpstory://story/index.html"))
    }
}
