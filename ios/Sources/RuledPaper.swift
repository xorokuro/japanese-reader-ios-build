import UIKit

/// Ruled notebook paper behind the reading passage, like the desktop reader's
/// `#latest` card: a faint rule between every line of text and a double margin
/// line down the left edge.
///
/// The rules are not a fixed-pitch background image. After every layout pass
/// the view asks TextKit where each line's glyphs actually landed and draws a
/// rule halfway through the gap between one line and the next, so the text
/// always sits between two rules — at any text size (two-finger swipe / pinch),
/// line spacing, typeface, page width or rotation. Below the last line the
/// same pitch continues to the bottom of the page.
final class RuledTextView: UITextView {
    /// Rule colour (the desktop's accent-2 at about a quarter strength).
    var ruleColor: UIColor = .clear { didSet { if ruleColor != oldValue { applyColors() } } }
    /// Margin line colour (the desktop's accent); the inner line is drawn lighter.
    var marginColor: UIColor = .clear { didSet { if marginColor != oldValue { applyColors() } } }
    /// Where the double margin line sits, from the left edge. Nil hides it.
    var marginX: CGFloat? { didSet { if marginX != oldValue { setNeedsLayout() } } }
    var ruled = true {
        didSet {
            guard ruled != oldValue else { return }
            [rules, marginOuter, marginInner].forEach { $0.isHidden = !ruled }
            invalidateRules()
        }
    }

    private let rules = CAShapeLayer()
    private let marginOuter = CAShapeLayer()
    private let marginInner = CAShapeLayer()
    private var rulesKey = ""
    private var textVersion = 0

    /// The text view does not own its text storage; keep it alive here.
    private let storage: NSTextStorage

    init() {
        // TextKit 1: its layout manager reports every line's baseline directly.
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        self.storage = storage
        super.init(frame: .zero, textContainer: container)
        for layer in [rules, marginOuter, marginInner] {
            layer.fillColor = nil
            layer.lineCap = .butt
            layer.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
            self.layer.insertSublayer(layer, at: 0)
        }
        rules.lineWidth = 1.5
        marginOuter.lineWidth = 1.5
        marginInner.lineWidth = 1
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var attributedText: NSAttributedString! {
        didSet { invalidateRules() }
    }
    override var textContainerInset: UIEdgeInsets {
        didSet { if textContainerInset != oldValue { invalidateRules() } }
    }

    func invalidateRules() {
        textVersion &+= 1
        setNeedsLayout()
    }

    private func applyColors() {
        rules.strokeColor = ruleColor.cgColor
        marginOuter.strokeColor = marginColor.cgColor
        marginInner.strokeColor = marginColor.withAlphaComponent(marginColor.cgColor.alpha * 0.58).cgColor
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        applyColors()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard ruled else { return }
        layoutMargin()
        let key = "\(textVersion)|\(bounds.width)|\(bounds.height)|\(contentSize.height)"
        if key != rulesKey {
            rulesKey = key
            rules.path = rulePath()
        }
    }

    /// The margin line spans whatever is on screen (plus bounce room), so it
    /// never ends while scrolling.
    private func layoutMargin() {
        guard let marginX else {
            marginOuter.path = nil; marginInner.path = nil
            return
        }
        let top = bounds.minY - bounds.height
        let bottom = bounds.maxY + bounds.height
        let outer = UIBezierPath()
        outer.move(to: CGPoint(x: marginX, y: top)); outer.addLine(to: CGPoint(x: marginX, y: bottom))
        let inner = UIBezierPath()
        inner.move(to: CGPoint(x: marginX + 3.5, y: top)); inner.addLine(to: CGPoint(x: marginX + 3.5, y: bottom))
        marginOuter.path = outer.cgPath
        marginInner.path = inner.cgPath
    }

    /// One rule between every pair of lines, then the same pitch to the page end.
    private func rulePath() -> CGPath {
        let path = UIBezierPath()
        let scale = max(traitCollection.displayScale, 1)
        for y in ruleOffsets() {
            let y = (y * scale).rounded() / scale
            path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: bounds.width, y: y))
        }
        return path.cgPath
    }

    /// Y positions of the rules, in content coordinates.
    func ruleOffsets() -> [CGFloat] {
        let lines = RuledTextView.lineBoxes(layoutManager: layoutManager, textContainer: textContainer,
                                            storage: textStorage, top: textContainerInset.top)
        var offsets: [CGFloat] = []
        let pageEnd = max(contentSize.height, bounds.height) + bounds.height
        var y: CGFloat
        var pitch: CGFloat
        if lines.isEmpty {
            let font = (typingAttributes[.font] as? UIFont) ?? UIFont.systemFont(ofSize: 23)
            pitch = max(font.lineHeight * 1.35, 24)
            y = textContainerInset.top + pitch
        } else {
            for index in 0..<(lines.count - 1) {
                offsets.append((lines[index].glyphBottom + lines[index + 1].glyphTop) / 2)
            }
            let last = lines[lines.count - 1]
            pitch = max(last.height, 12)
            // Same gap the text would have to a following line of the same kind.
            y = (last.glyphBottom + last.glyphTop + pitch) / 2
        }
        while y < pageEnd && offsets.count < 4000 {
            offsets.append(y); y += pitch
        }
        return offsets
    }

    /// Paragraph style for ruled paper: every line (passage or translation) gets
    /// the same fixed height and no extra paragraph gap, so the rules keep one
    /// even pitch like a notebook. The height matches `lineHeightMultiple`.
    static func paragraph(font: UIFont, lineSpacing: CGFloat) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        let height = (font.lineHeight * max(lineSpacing, 1)).rounded(.up)
        paragraph.minimumLineHeight = height
        paragraph.maximumLineHeight = height
        paragraph.paragraphSpacing = 0
        return paragraph
    }

    struct LineBox: Equatable {
        /// Top and bottom of the visible glyphs (the ideographic em box).
        var glyphTop: CGFloat
        var glyphBottom: CGFloat
        /// Height of the whole line fragment, i.e. the line pitch.
        var height: CGFloat
    }

    /// Where every laid-out line's glyphs sit, in text-view coordinates.
    static func lineBoxes(layoutManager: NSLayoutManager, textContainer: NSTextContainer,
                          storage: NSTextStorage, top: CGFloat) -> [LineBox] {
        layoutManager.ensureLayout(for: textContainer)
        let glyphs = layoutManager.glyphRange(for: textContainer)
        var boxes: [LineBox] = []
        guard glyphs.length > 0 else { return boxes }
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, lineGlyphs, _ in
            let baseline = rect.minY + layoutManager.location(forGlyphAt: lineGlyphs.location).y + top
            let char = layoutManager.characterIndexForGlyph(at: lineGlyphs.location)
            let font = char < storage.length ? (storage.attribute(.font, at: char, effectiveRange: nil) as? UIFont) : nil
            let size = font?.pointSize ?? 17
            // Japanese glyphs fill an em box from 0.88 em above to 0.12 em below the baseline.
            boxes.append(LineBox(glyphTop: baseline - size * 0.88, glyphBottom: baseline + size * 0.12,
                                 height: rect.height))
        }
        return boxes
    }
}
