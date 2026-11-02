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
}
