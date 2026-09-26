import SwiftUI
import UIKit
import WebKit
import Translation

// The selection peek: selecting text no longer jumps to another page. A card slides
// up with the best dictionary matches while the native selection handles stay in
// place, so the range can still be dragged shorter or longer. The character strip
// on the card selects any exact part of the phrase, one character at a time.

/// The longest selection (in characters) that is looked up and handled by the
/// dictionary card; longer selections keep the normal iPhone menu.
/// Library → Dictionary search changes it.
enum SelectionLimit {
    static let key = "selectionLookupLimit"
    static let range = 5...200
    static let standard = 40
    static var current: Int {
        let stored = UserDefaults.standard.integer(forKey: key)
        return stored == 0 ? standard : min(max(stored, range.lowerBound), range.upperBound)
    }
}

/// What was selected and the characters around it (same line / paragraph only).
struct SelectionContext: Equatable {
    var text = ""
    var before = ""
    var after = ""
    /// UTF-16 location of `text` in the reading passage; -1 inside dictionary pages.
    var location = -1
}

struct PeekState: Equatable {
    let id = UUID()
    var text: String
    var before: String
    var after: String
    var location: Int
    var inDictionary: Bool
    /// The headword actually found (after de-inflection or trimming).
    var matched = ""
    var hits: [DictionaryHit] = []
    var busy = true

    var characters: [String] { (before + text + after).map { String($0) } }
    var selected: ClosedRange<Int> {
        let last = max(characters.count - 1, 0)
        let start = min(before.count, last)
        return start...min(max(start, start + text.count - 1), last)
    }
}

/// Weak links to the native views that own the live selection, so the peek card's
/// character strip can move the real selection (and its handles) as well.
final class SelectionBridge {
    static let shared = SelectionBridge()
    weak var readerView: UITextView?
    weak var dictionaryView: WKWebView?
    var readerContext = SelectionContext()
    var dictionaryContext = SelectionContext()

    /// Moves the native selection. Returns false when the view is gone, in which
    /// case the caller looks the new text up directly.
    func refine(_ peek: PeekState, offset: Int, length: Int, fallback: @escaping () -> Void) -> Bool {
        let beforeLength = peek.before.utf16.count, textLength = peek.text.utf16.count
        if peek.inDictionary {
            guard let view = dictionaryView, view.window != nil else { return false }
            let startDelta = offset - beforeLength
            let endDelta = offset + length - beforeLength - textLength
            DictionaryPage.evaluateSelectionScript("window.__jpRefine ? window.__jpRefine(\(startDelta), \(endDelta)) : false", in: view) { value, _ in
                if (value as? Bool) != true { fallback() }
            }
            return true
        }
        guard let view = readerView, view.window != nil, peek.location >= 0 else { return false }
        let target = NSRange(location: peek.location - beforeLength + offset, length: length)
        let total = (view.text ?? "").utf16.count
        guard target.location >= 0, target.length > 0, target.location + target.length <= total else { return false }
        if !view.isFirstResponder { view.becomeFirstResponder() }
        view.selectedRange = target
        view.delegate?.textViewDidChangeSelection?(view)
        return true
    }
}

/// Finds the best dictionary match for a selection: the exact text, then its
/// dictionary forms, then ever-shorter leading parts (Yomitan-style scanning).
enum PeekSearch {
    static func bestMatch(for text: String, in dictionaries: [InstalledDictionary]) -> (query: String, hits: [DictionaryHit]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", []) }
        let stores: [(InstalledDictionary, DictionaryStore)] = dictionaries.compactMap { dictionary in
            guard let store = try? DictionaryStore.shared(root: dictionary.root) else { return nil }
            return (dictionary, store)
        }
        guard !stores.isEmpty else { return (trimmed, []) }
        func exists(_ word: String) -> Bool {
            stores.contains { pair in (try? pair.1.contains(word, code: pair.0.code)) ?? false }
        }
        func lookup(_ word: String) -> [DictionaryHit] {
            let all = stores.flatMap { pair in (try? pair.1.search(word, codes: [pair.0.code], mode: .prefix)) ?? [] }
            let key = DictionaryStore.normalize(word)
            let exact = all.filter { DictionaryStore.normalize($0.word) == key }
            let rest = all.filter { DictionaryStore.normalize($0.word) != key }
            return exact + rest
        }
        for candidate in Deinflector.lookupCandidates(trimmed) where exists(candidate) {
            return (candidate, lookup(candidate))
        }
        return (trimmed, lookup(trimmed))
    }
}

// MARK: - Card

struct LookupPeekCard: View {
    let peek: PeekState
    let style: ReaderStyle
    let refine: (ClosedRange<Int>) -> Void
    let open: (DictionaryHit) -> Void
    let showAll: () -> Void
    let copy: () -> Void
    let close: () -> Void
    @State private var expanded = false
    @State private var translating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            RefineStrip(characters: peek.characters, selection: peek.selected, style: style, commit: refine)
            results
            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .sketchCard(style, radius: 22, tape: .marker, tapeTrailing: true)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lookupPeek")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            HandSeal(text: "辞", style: style, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("辞書 · Dictionary")
                    .font(HandFont.title(13))
                    .foregroundStyle(style.secondary)
                HStack(spacing: 6) {
                    Text("「\(peek.text)」")
                        .font(HandFont.title(17))
                        .foregroundStyle(style.accent)
                        .lineLimit(1)
                    if !peek.matched.isEmpty && peek.matched != peek.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(style.faint)
                        Text(peek.matched)
                            .font(HandFont.title(17))
                            .foregroundStyle(style.ink)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            if peek.busy { ProgressView().controlSize(.small) }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(style.secondary)
                    .frame(width: 32, height: 32)
                    .sketchPill(style)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close dictionary card")
            .accessibilityIdentifier("closePeek")
        }
    }

    @ViewBuilder private var results: some View {
        if peek.hits.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: peek.busy ? "hourglass" : "questionmark.circle")
                    .foregroundStyle(style.accent)
                Text(peek.busy ? "Looking up…" : "No match. Drag across fewer characters above.")
                    .font(HandFont.body(15))
                    .foregroundStyle(style.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(peek.hits.prefix(expanded ? 30 : 6)), id: \.identity) { hit in
                        Button { open(hit) } label: { row(hit) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("peekResult_" + hit.word)
                    }
                    if peek.hits.count > 6 && !expanded {
                        Button { withAnimation(.snappy(duration: 0.22)) { expanded = true } } label: {
                            Text("Show \(min(peek.hits.count, 30) - 6) more")
                                .font(HandFont.title(14))
                                .foregroundStyle(style.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
                .padding(.trailing, 2)
            }
            .frame(maxHeight: expanded ? 330 : 214)
            .scrollIndicators(.hidden)
        }
    }

    private func row(_ hit: DictionaryHit) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(hit.word)
                        .font(HandFont.title(19))
                        .foregroundStyle(style.ink)
                        .lineLimit(1)
                    Text(ReaderText.shortDictionaryName(hit.dictionary))
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(style.accent)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(style.accentSoft, in: SketchShape(radius: 7))
                        .lineLimit(1)
                }
                if !hit.preview.isEmpty {
                    Text(hit.preview)
                        .font(.system(size: 14))
                        .foregroundStyle(style.secondary)
                        .lineLimit(expanded ? 4 : 2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(style.faint)
                .padding(.top, 6)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.raised.opacity(0.7), in: SketchShape(radius: 12, variant: 1))
        .overlay(SketchShape(radius: 12, variant: 1).stroke(style.lineStrong.opacity(0.7), lineWidth: 1))
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: showAll) {
                Label(peek.hits.isEmpty ? String("Search") : String("Results · \(peek.hits.count)"), systemImage: "list.bullet")
            }
            .buttonStyle(HandSoftButtonStyle(style: style, prominent: true))
            .accessibilityIdentifier("peekAllResults")
            Button { translating = true } label: {
                Label("Translate", systemImage: "character.bubble")
            }
            .buttonStyle(HandSoftButtonStyle(style: style))
            .accessibilityIdentifier("peekTranslate")
            Button(action: copy) {
                Label("Copy", systemImage: "doc.on.doc").labelStyle(.iconOnly)
            }
            .buttonStyle(HandSoftButtonStyle(style: style))
            .accessibilityLabel("Copy")
            .accessibilityIdentifier("peekCopy")
            Spacer(minLength: 0)
        }
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .translationPresentation(isPresented: $translating, text: peek.text)
    }
}

/// Word boundaries for stepping the selection word by word (Apple's Japanese
/// word segmentation). Offsets are character indices; punctuation is skipped.
enum WordSteps {
    static func words(in text: String) -> [Range<Int>] {
        guard !text.isEmpty else { return [] }
        // UTF-16 offset → character index, so results line up with the strip cells.
        var characterAt: [Int] = []
        for (index, character) in text.enumerated() {
            for _ in 0..<character.utf16.count { characterAt.append(index) }
        }
        let characterCount = text.count
        characterAt.append(characterCount)
        let length = (text as NSString).length
        let tokenizer = CFStringTokenizerCreate(nil, text as CFString, CFRange(location: 0, length: length),
                                                kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale)
        let skip = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).union(.symbols)
        var words: [Range<Int>] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard range.location >= 0, range.length > 0, range.location + range.length <= length else { continue }
            let token = (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
            if token.unicodeScalars.allSatisfy({ skip.contains($0) }) { continue }
            let start = characterAt[range.location], end = characterAt[range.location + range.length]
            if start < end { words.append(start..<end) }
        }
        return words
    }

    /// The next (`direction` 1) or previous (-1) word next to `selection`.
    static func step(from selection: ClosedRange<Int>, direction: Int, in text: String) -> ClosedRange<Int>? {
        let words = words(in: text)
        if direction > 0 {
            guard let word = words.first(where: { $0.lowerBound > selection.upperBound }) else { return nil }
            return word.lowerBound...(word.upperBound - 1)
        }
        guard let word = words.last(where: { $0.upperBound <= selection.lowerBound }) else { return nil }
        return word.lowerBound...(word.upperBound - 1)
    }
}

/// Big characters of the selection and its neighbours. Drag slowly across them
/// (or tap one) to look up exactly those characters; flick left or right, or use
/// the arrows, to jump to the next or previous word. The real selection follows.
struct RefineStrip: View {
    let characters: [String]
    let selection: ClosedRange<Int>
    let style: ReaderStyle
    let commit: (ClosedRange<Int>) -> Void
    @State private var dragging: ClosedRange<Int>?
    @State private var dragBegan: Date?

    private func window(fitting cells: Int) -> Range<Int> {
        let count = characters.count
        guard count > cells else { return 0..<count }
        let selected = selection.count
        guard selected < cells else { return selection.lowerBound..<min(count, selection.lowerBound + max(cells, 1)) }
        var start = max(0, selection.lowerBound - (cells - selected) / 2)
        let end = min(count, start + cells)
        start = max(0, end - cells)
        return start..<end
    }

    private func step(_ direction: Int) {
        guard let next = WordSteps.step(from: selection, direction: direction, in: characters.joined()),
              next.upperBound < characters.count else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        commit(next)
    }

    private func arrow(_ direction: Int) -> some View {
        Button { step(direction) } label: {
            Image(systemName: direction > 0 ? "chevron.right" : "chevron.left")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(style.accent)
                .frame(width: 30, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(direction > 0 ? "Next word" : "Previous word")
        .accessibilityIdentifier(direction > 0 ? "peekNextWord" : "peekPreviousWord")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                arrow(-1)
                strip
                arrow(1)
            }
            Text("Drag across characters to pick part of it · flick ← → for the next word")
                .font(HandFont.body(11.5))
                .foregroundStyle(style.faint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var strip: some View {
        GeometryReader { proxy in
            let visible = window(fitting: max(1, Int(proxy.size.width / 26)))
            let count = max(visible.count, 1)
            let cell = max(1, min(34, proxy.size.width / CGFloat(count)))
            let active = dragging ?? selection
            HStack(spacing: 0) {
                ForEach(Array(visible), id: \.self) { index in
                    let inside = active.contains(index)
                    Text(characters[index] == "\n" ? "↵" : characters[index])
                        .font(HandFont.title(min(22, cell * 0.72)))
                        .foregroundStyle(inside ? style.ink : style.faint)
                        .frame(width: cell, height: 40)
                        .background(inside ? style.marker.opacity(style.isDark ? 0.34 : 0.45) : Color.clear)
                }
            }
            .frame(width: cell * CGFloat(count), height: 40)
            .background(style.raised.opacity(0.55), in: SketchShape(radius: 10))
            .overlay(SketchShape(radius: 10).stroke(style.lineStrong.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragBegan == nil { dragBegan = Date() }
                        let first = visible.lowerBound + clamp(Int(value.startLocation.x / cell), count)
                        let last = visible.lowerBound + clamp(Int(value.location.x / cell), count)
                        let range = min(first, last)...max(first, last)
                        if range != dragging {
                            dragging = range
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                    }
                    .onEnded { value in
                        let quick = Date().timeIntervalSince(dragBegan ?? Date()) < 0.3
                        let dx = value.translation.width
                        dragBegan = nil
                        // A quick sideways flick steps word by word: left = next, right = previous.
                        if quick && abs(dx) > 24 && abs(dx) > abs(value.translation.height) {
                            dragging = nil
                            step(dx < 0 ? 1 : -1)
                            return
                        }
                        if let range = dragging, range != selection { commit(range) }
                        dragging = nil
                    }
            )
            .frame(maxWidth: .infinity)
        }
        .frame(height: 40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Refine selection")
        .accessibilityValue(characters.indices.contains(selection.upperBound) ? characters[selection].joined() : "")
    }

    private func clamp(_ value: Int, _ count: Int) -> Int { min(max(value, 0), count - 1) }
}
