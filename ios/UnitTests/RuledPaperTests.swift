import XCTest
import UIKit
@testable import JapaneseReader

/// The ruled lines must always fall between lines of text, never through them,
/// at every text size (two-finger swipe / pinch range) and line spacing.
final class RuledPaperTests: XCTestCase {
    private let passage = "レダ\nカッシートの街\nまだあの戦争の傷跡がそのままだわ。まだあの戦争の傷跡がそのままだわ。\n\n吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。"

    private func layout(size: CGFloat, spacing: CGFloat, translations: [String] = []) -> RuledTextView {
        let view = RuledTextView()
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 640)
        view.textContainerInset = UIEdgeInsets(top: 24, left: 28, bottom: 40, right: 12)
        let font = UIFont(name: "KleeOne-Regular", size: size) ?? .systemFont(ofSize: size)
        view.attributedText = SelectableJapanese.interlinear(passage, translations: translations, ink: .black,
                                                             font: font, lineSpacing: spacing, ruled: true)
        view.layoutIfNeeded()
        return view
    }

    func testEveryLineSitsBetweenTwoRules() {
        for size: CGFloat in [16, 23, 30, 38] {
            for spacing: CGFloat in [1.05, 1.35, 2.0] {
                let view = layout(size: size, spacing: spacing)
                let rules = view.ruleOffsets()
                let lines = RuledTextView.lineBoxes(layoutManager: view.layoutManager, textContainer: view.textContainer,
                                                    storage: view.textStorage, top: view.textContainerInset.top)
                XCTAssertGreaterThan(lines.count, 6, "passage should wrap at \(size)pt")
                for (index, line) in lines.enumerated() {
                    // Rule `index` is the one just under line `index`.
                    XCTAssertGreaterThan(rules[index], line.glyphBottom, "rule crosses line \(index) at \(size)pt ×\(spacing)")
                    if index > 0 {
                        XCTAssertLessThan(rules[index - 1], line.glyphTop, "rule crosses line \(index) at \(size)pt ×\(spacing)")
                    }
                }
                // Notebook paper: one even pitch all the way down.
                let gaps = zip(rules.dropFirst(), rules).map { $0 - $1 }
                XCTAssertLessThan((gaps.max() ?? 0) - (gaps.min() ?? 0), 1.01, "uneven rules at \(size)pt ×\(spacing)")
                // Rules continue past the text to fill the page.
                XCTAssertGreaterThanOrEqual(rules.last ?? 0, view.bounds.height - (gaps.first ?? 0))
            }
        }
    }

    func testTranslationLinesAlsoSitBetweenRules() {
        let pieces = PassageSegments.split(passage)
        let view = layout(size: 23, spacing: 1.35, translations: pieces.map { _ in "A translated line." })
        let rules = view.ruleOffsets()
        let lines = RuledTextView.lineBoxes(layoutManager: view.layoutManager, textContainer: view.textContainer,
                                            storage: view.textStorage, top: view.textContainerInset.top)
        for (index, line) in lines.enumerated() {
            XCTAssertGreaterThan(rules[index], line.glyphBottom)
            if index > 0 { XCTAssertLessThan(rules[index - 1], line.glyphTop) }
        }
    }

    func testTurningRulesOffKeepsTheOriginalLayout() {
        let font = UIFont.systemFont(ofSize: 20)
        let plain = SelectableJapanese.styled("猫", ink: .black, font: font, lineSpacing: 1.3)
        let style = plain.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.lineHeightMultiple, 1.3)
        XCTAssertEqual(style?.maximumLineHeight, 0)
    }
}
