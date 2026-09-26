import XCTest
import UIKit
@testable import JapaneseReader

final class TranslationLayoutTests: XCTestCase {
    func testSentencesRejoinToTheExactPassage() {
        let passage = "ダンジョンと戦闘が1回ずつあります。「はい！」と言った。次の行\n二行目？「そう」"
        let pieces = PassageSegments.split(passage)
        XCTAssertEqual(pieces.joined(), passage)
        XCTAssertEqual(pieces, ["ダンジョンと戦闘が1回ずつあります。", "「はい！」と言った。", "次の行\n", "二行目？", "「そう」"])
        XCTAssertTrue(PassageSegments.split("").isEmpty)
    }
    func testTranslationsSitUnderEachSentenceAndAreMarked() {
        let passage = "猫です。犬です。"
        let text = SelectableJapanese.interlinear(passage, translations: ["It's a cat.", "It's a dog."],
                                                  ink: .black, font: .systemFont(ofSize: 20), lineSpacing: 1.3)
        XCTAssertEqual(text.string, "猫です。\nIt's a cat.\n犬です。\nIt's a dog.")
        let translation = (text.string as NSString).range(of: "It's a cat.")
        XCTAssertNotNil(text.attribute(SelectableJapanese.translationKey, at: translation.location, effectiveRange: nil))
        XCTAssertNil(text.attribute(SelectableJapanese.translationKey, at: 0, effectiveRange: nil))
        // A missing or mismatched translation shows the plain passage.
        XCTAssertEqual(SelectableJapanese.interlinear(passage, translations: [], ink: .black, font: .systemFont(ofSize: 20), lineSpacing: 1.3).string, passage)
    }
}
