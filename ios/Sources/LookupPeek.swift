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

/// How much blank space pages keep at their edges and before indented lines.
enum PageMargins: String, CaseIterable, Identifiable {
    case compact, normal, wide
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: return "Compact"
        case .normal: return "Normal"
        case .wide: return "Wide"
        }
    }
    /// Dictionary page edge padding (CSS px).
    /// Compact still keeps text clear of the 16 pt swipe-back strip at the edges.
    var pagePadding: Int { self == .compact ? 12 : self == .normal ? 14 : 16 }
    /// Multiplier for the publishers' own indents.
    var indentScale: Double { self == .compact ? 0.4 : self == .normal ? 0.7 : 1 }
    /// Space between the screen edge and a card.
    var cardInset: CGFloat { self == .compact ? 4 : self == .normal ? 7 : 10 }
    /// Reading passage side inset inside its card.
    var readerInset: CGFloat { self == .compact ? 12 : self == .normal ? 16 : 20 }
    static func resolve(_ raw: String) -> PageMargins { PageMargins(rawValue: raw) ?? .compact }
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
    /// Longer than the lookup limit: shown as text to copy, translate or share.
    var long = false

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
    /// Set when a tap on a still-selected passage asks for the card again, so the
    /// next `select` of exactly this text reopens it (see `SelectionReopenTap`).
    var reopenText: String?

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
    /// The selection that was last copied; the Copy button stays greyed out
    /// ("Copied") until the selection changes.
    @State private var copiedText: String?
    @State private var showCopiedNote = false
    @State private var hideNote: DispatchWorkItem?
    /// The order of the icon buttons along the bottom, changed by dragging them.
    @AppStorage(PeekAction.storageKey) private var actionOrder = PeekAction.standard
    @State private var dropTarget: PeekAction?

    private var copied: Bool { copiedText == peek.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if peek.long {
                passage
            } else {
                RefineStrip(characters: peek.characters, selection: peek.selected, style: style, commit: refine)
                results
            }
            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .sketchCard(style, radius: 22, tape: .marker, tapeTrailing: true)
        .overlay(alignment: .top) {
            if showCopiedNote {
                CopiedNote(style: style)
                    .offset(y: -18)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: showCopiedNote)
        .animation(.snappy(duration: 0.22), value: copied)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lookupPeek")
    }

    private func doCopy() {
        guard !copied else { return }
        copy()
        copiedText = peek.text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        hideNote?.cancel()
        showCopiedNote = true
        let work = DispatchWorkItem { showCopiedNote = false }
        hideNote = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            HandSeal(text: peek.long ? "選" : "辞", style: style, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(peek.long ? "選取 · Selection" : "辞書 · Dictionary")
                    .font(HandFont.title(13))
                    .foregroundStyle(style.secondary)
                HStack(spacing: 6) {
                    if peek.long {
                        Text("\(peek.text.count) 字")
                            .font(HandFont.title(17))
                            .foregroundStyle(style.accent)
                            .monospacedDigit()
                        Text("too long to look up · copy or translate")
                            .font(HandFont.body(12.5))
                            .foregroundStyle(style.faint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else {
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

    /// The whole long selection, so you can see what will be copied or translated.
    private var passage: some View {
        ScrollView {
            Text(peek.text)
                .font(HandFont.body(15.5))
                .foregroundStyle(style.ink)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
        }
        .frame(maxHeight: 150)
        .fixedSize(horizontal: false, vertical: true)
        .background(style.raised.opacity(0.55), in: SketchShape(radius: 12, variant: 1))
        .overlay(SketchShape(radius: 12, variant: 1).stroke(style.lineStrong.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .accessibilityIdentifier("peekPassage")
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

    private var copyButton: some View {
        Button(action: doCopy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(PeekIconButtonStyle(style: style))
        .disabled(copied)
        .opacity(copied ? 0.5 : 1)
        .saturation(copied ? 0 : 1)
        .accessibilityLabel(copied ? "Copied" : "Copy")
        .accessibilityIdentifier("peekCopy")
    }

    @ViewBuilder private func actionButton(_ action: PeekAction) -> some View {
        switch action {
        case .results:
            Button(action: showAll) {
                Image(systemName: peek.hits.isEmpty ? "magnifyingglass" : "list.bullet")
            }
            .buttonStyle(PeekIconButtonStyle(style: style, prominent: true))
            .accessibilityLabel(peek.hits.isEmpty ? "Search" : "All \(peek.hits.count) results")
            .accessibilityIdentifier("peekAllResults")
        case .translate:
            Button { translating = true } label: { Image(systemName: "character.bubble") }
                .buttonStyle(PeekIconButtonStyle(style: style))
                .accessibilityLabel("Translate")
                .accessibilityIdentifier("peekTranslate")
        case .copy:
            copyButton
        case .share:
            ShareLink(item: peek.text) { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(PeekIconButtonStyle(style: style))
                .accessibilityLabel("Share")
                .accessibilityIdentifier("peekShare")
        }
    }

    /// Icon buttons in the reader's own order. Touch and hold one, then drag it
    /// onto another to swap places; the order is remembered.
    private var footer: some View {
        let shown = PeekAction.order(from: actionOrder).filter { $0.applies(long: peek.long) }
        return HStack(spacing: 10) {
            ForEach(shown) { action in
                actionButton(action)
                    .scaleEffect(dropTarget == action ? 1.12 : 1)
                    .animation(.snappy(duration: 0.18), value: dropTarget)
                    .draggable(action.rawValue) {
                        Image(systemName: action.symbol)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(style.accent)
                            .frame(width: 52, height: 40)
                            .background(style.accentSoft, in: SketchShape(radius: 12))
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard let raw = items.first, let dragged = PeekAction(rawValue: raw), dragged != action else { return false }
                        withAnimation(.snappy(duration: 0.22)) {
                            actionOrder = PeekAction.moving(dragged, to: action, in: PeekAction.order(from: actionOrder)).map(\.rawValue).joined(separator: ",")
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        return true
                    } isTargeted: { targeted in
                        if targeted { dropTarget = action } else if dropTarget == action { dropTarget = nil }
                    }
            }
            Spacer(minLength: 0)
        }
        .translationPresentation(isPresented: $translating, text: peek.text)
    }
}

/// The dictionary card's action buttons, in an order the reader can change.
enum PeekAction: String, CaseIterable, Identifiable {
    case results, translate, copy, share
    var id: String { rawValue }
    static let storageKey = "peekActionOrder"
    static let standard = "results,translate,copy,share"
    var symbol: String {
        switch self {
        case .results: return "list.bullet"
        case .translate: return "character.bubble"
        case .copy: return "doc.on.doc"
        case .share: return "square.and.arrow.up"
        }
    }
    /// Results needs a word to look up; Share is for long selections only.
    func applies(long: Bool) -> Bool {
        switch self {
        case .results: return !long
        case .share: return long
        case .translate, .copy: return true
        }
    }
    /// The stored order, with unknown names dropped and any missing action appended.
    static func order(from raw: String) -> [PeekAction] {
        var result: [PeekAction] = []
        for name in raw.split(separator: ",") {
            if let action = PeekAction(rawValue: String(name)), !result.contains(action) { result.append(action) }
        }
        for action in allCases where !result.contains(action) { result.append(action) }
        return result
    }
    /// Dropping one button on another puts it in that button's place.
    static func moving(_ dragged: PeekAction, to target: PeekAction, in order: [PeekAction]) -> [PeekAction] {
        guard let from = order.firstIndex(of: dragged), let to = order.firstIndex(of: target), from != to else { return order }
        var result = order
        result.remove(at: from)
        result.insert(dragged, at: to)
        return result
    }
}

/// A square hand-drawn icon button for the dictionary card.
struct PeekIconButtonStyle: ButtonStyle {
    let style: ReaderStyle
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(prominent ? style.accent : style.ink)
            .frame(width: 52, height: 40)
            .background(prominent ? style.accentSoft : style.surface, in: SketchShape(radius: 12))
            .overlay(SketchShape(radius: 12).stroke(style.lineStrong, lineWidth: 1.3))
            .background(SketchShape(radius: 12).fill(style.shade).offset(x: configuration.isPressed ? 1 : 2, y: configuration.isPressed ? 1 : 3))
            .offset(x: configuration.isPressed ? 1 : 0, y: configuration.isPressed ? 2 : 0)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A small "copied" note that floats above a card for a moment.
struct CopiedNote: View {
    let style: ReaderStyle
    var text = "已複製 · Copied to clipboard"

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(HandFont.title(14))
            .foregroundStyle(style.onAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(style.accent, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            .allowsHitTesting(false)
            .accessibilityIdentifier("copiedNote")
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
