import XCTest
@testable import JapaneseReader

final class DictionaryTextSizeTests: XCTestCase {
    func testEachDictionaryKeepsItsOwnSize() {
        var raw = ""
        raw = DictionaryTextSizes.setting(24, for: "MDX_NHK", in: raw)
        raw = DictionaryTextSizes.setting(16, for: "MDX_NEW_FA6F3D98", in: raw)
        XCTAssertEqual(DictionaryTextSizes.size(for: "MDX_NHK", in: raw, fallback: 19), 24)
        XCTAssertEqual(DictionaryTextSizes.size(for: "MDX_NEW_FA6F3D98", in: raw, fallback: 19), 16)
        // Not resized yet: follows the default size.
        XCTAssertEqual(DictionaryTextSizes.size(for: "MDX_KEN", in: raw, fallback: 21), 21)
    }

    func testSizesAreClampedAndCanBeReset() {
        var raw = DictionaryTextSizes.setting(99, for: "A", in: "")
        XCTAssertEqual(DictionaryTextSizes.size(for: "A", in: raw, fallback: 19), DictionaryTextSizes.range.upperBound)
        raw = DictionaryTextSizes.setting(17, for: "B", in: raw)
        raw = DictionaryTextSizes.removing("A", in: raw)
        XCTAssertEqual(DictionaryTextSizes.size(for: "A", in: raw, fallback: 19), 19)
        XCTAssertEqual(DictionaryTextSizes.size(for: "B", in: raw, fallback: 19), 17)
        XCTAssertEqual(DictionaryTextSizes.removing("B", in: raw), "")
    }

    func testBadStoredValueFallsBackToDefault() {
        XCTAssertEqual(DictionaryTextSizes.size(for: "A", in: "not json", fallback: 20), 20)
        XCTAssertEqual(DictionaryTextSizes.size(for: "", in: "{\"\":25}", fallback: 20), 20)
    }
}
