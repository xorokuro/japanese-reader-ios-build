import XCTest
@testable import JapaneseReader

final class DeinflectorTests: XCTestCase {
    func testCommonConjugationsReachTheDictionaryForm() {
        let cases: [(String, String)] = [
            ("食べました", "食べる"), ("書いていた", "書く"), ("高かった", "高い"), ("勉強しています", "勉強"),
            ("読まない", "読む"), ("泳いでも", "泳ぐ"), ("書けない", "書く"), ("行った", "行く"),
            ("見られる", "見る"), ("来ました", "来る"), ("静かな", "静か"), ("走っちゃった", "走る"),
            ("食べさせられた", "食べる"), ("飲みたかった", "飲む"), ("進み", "進む"), ("構えていられる", "構える")
        ]
        for (inflected, dictionary) in cases {
            XCTAssertTrue(Deinflector.deinflect(inflected).contains(dictionary), "\(inflected) → \(dictionary)")
        }
    }
    func testCandidatesPreferTheLongestText() {
        let candidates = Deinflector.lookupCandidates("干しえびを")
        XCTAssertEqual(candidates.first, "干しえびを")
        let whole = candidates.firstIndex(of: "干しえび")
        let part = candidates.firstIndex(of: "干し")
        XCTAssertNotNil(whole)
        XCTAssertNotNil(part)
        if let whole, let part { XCTAssertLessThan(whole, part) }
        XCTAssertTrue(Deinflector.lookupCandidates("").isEmpty)
    }
}
