import SwiftUI

// Shared iOS look: cards, chips, buttons and labels used by the reader screens.
// Nothing here is shared with the Windows desktop interface.

private struct ReaderStyleKey: EnvironmentKey {
    // A fallback only: it must not become the app's current design. It used to, so a
    // dictionary page opened just after SwiftUI read this default came up without the theme.
    static var defaultValue: ReaderStyle {
        ReaderStyle.resolve(themeID: ReaderTheme.systemID, customPaper: false,
                            paperRGB: 0xFFFFFF, customAccentRGB: 0x1F7A73, systemDark: false, activate: false)
    }
}

extension EnvironmentValues {
    var readerStyle: ReaderStyle {
        get { self[ReaderStyleKey.self] }
        set { self[ReaderStyleKey.self] = newValue }
    }
}

enum ReaderMetrics {
    static let cardRadius: CGFloat = 18
    static let innerRadius: CGFloat = 13
    static let gutter: CGFloat = 16
    static let stack: CGFloat = 12
}

// MARK: - Surfaces

struct ReaderCardModifier: ViewModifier {
    let style: ReaderStyle
    var padding: CGFloat = ReaderMetrics.gutter
    var radius: CGFloat = ReaderMetrics.cardRadius
    var elevated = true
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(style.surface, in: RoundedRectangle(cornerRadius: style.isYohaku ? 0 : radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: style.isYohaku ? 0 : radius, style: .continuous)
                    .strokeBorder(style.hairline, lineWidth: 1)
            )
            .shadow(color: elevated ? style.shadow : .clear, radius: elevated && !style.isYohaku ? 14 : 0, x: 0, y: style.isYohaku ? 0 : 7)
    }
}

struct ReaderInsetModifier: ViewModifier {
    let style: ReaderStyle
    var padding: CGFloat = 13
    var radius: CGFloat = ReaderMetrics.innerRadius
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(style.raised, in: RoundedRectangle(cornerRadius: style.isYohaku ? 0 : radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: style.isYohaku ? 0 : radius, style: .continuous)
                    .strokeBorder(style.hairline, lineWidth: 1)
            )
    }
}

extension View {
    func readerCard(_ style: ReaderStyle, padding: CGFloat = ReaderMetrics.gutter,
                    radius: CGFloat = ReaderMetrics.cardRadius, elevated: Bool = true) -> some View {
        modifier(ReaderCardModifier(style: style, padding: padding, radius: radius, elevated: elevated))
    }
    func readerInset(_ style: ReaderStyle, padding: CGFloat = 13,
                     radius: CGFloat = ReaderMetrics.innerRadius) -> some View {
        modifier(ReaderInsetModifier(style: style, padding: padding, radius: radius))
    }
}

// MARK: - Labels

/// Small accent heading. Only used for fixed English wording, never for dictionary
/// names, so assistive technology and UI tests keep reading the original strings.
struct SectionLabel: View {
    let text: String
    var symbol: String?
    let style: ReaderStyle
    init(_ text: String, symbol: String? = nil, style: ReaderStyle) {
        self.text = text
        self.symbol = symbol
        self.style = style
    }
    var body: some View {
        if style.isYohaku {
            // RESULTS ───── : letter-spaced Hanken capitals over a navy hairline.
            HStack(spacing: 8) {
                Text(YohakuFont.caps(text)).font(YohakuFont.label(10)).tracking(style.isFable ? 0.3 : 1.8).foregroundStyle(style.secondary)
                BrushLine(width: 1.5).fill(style.rule).frame(height: 6)
            }
            .accessibilityAddTraits(.isHeader)
        } else {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                }
                Text(text).font(.system(size: 11, weight: .bold)).tracking(1.1)
                Rectangle().fill(
                    LinearGradient(colors: [style.accent.opacity(0.35), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                ).frame(height: 1)
            }
            .foregroundStyle(style.accent)
            .accessibilityAddTraits(.isHeader)
        }
    }
}

/// A short status line with a matching symbol.
struct StatusNote: View {
    let text: String
    let style: ReaderStyle
    var symbol = "info.circle"
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(style.accent)
            Text(text).font(.footnote).foregroundStyle(style.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(style.accentSoft, in: RoundedRectangle(cornerRadius: style.isYohaku ? 0 : 11, style: .continuous))
    }
}

/// Centered placeholder for empty result and library areas.
struct EmptyHint: View {
    let symbol: String
    let title: String
    let detail: String
    let style: ReaderStyle
    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(style.accent.opacity(0.75))
            Text(title).font(.headline).foregroundStyle(style.ink)
            Text(detail)
                .font(.footnote).foregroundStyle(style.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }
}

// MARK: - Buttons

private struct EnabledOpacity: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View { content.opacity(enabled ? 1 : 0.42) }
}

struct PrimaryActionStyle: ButtonStyle {
    let style: ReaderStyle
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(style.onAccent)
            .padding(.horizontal, 22)
            .frame(minHeight: 44)
            .background {
                if style.isYohaku {
                    if style.isFable { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(style.ink.opacity(0.9)) }
                    else { TornRect().fill(style.navy) }
                } else {
                    Capsule(style: .continuous).fill(LinearGradient(colors: [style.accent, style.accent.opacity(0.86)],
                                                                     startPoint: .top, endPoint: .bottom))
                }
            }
            .shadow(color: style.isYohaku ? .clear : style.accent.opacity(style.isDark ? 0.35 : 0.28), radius: style.isYohaku ? 0 : 10, x: 0, y: style.isYohaku ? 0 : 5)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
            .modifier(EnabledOpacity())
    }
}

struct SoftActionStyle: ButtonStyle {
    let style: ReaderStyle
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(prominent ? style.accent : style.ink)
            .padding(.horizontal, 17)
            .frame(minHeight: 40)
            .background(style.isYohaku ? (prominent ? style.accentSoft : Color.clear) : (prominent ? style.accentSoft : style.raised),
                        in: RoundedRectangle(cornerRadius: style.isYohaku ? 0 : 99, style: .continuous))
            .overlay {
                if style.isYohaku { BrushBox(width: 1.6).fill(style.rule).allowsHitTesting(false) }
                else { Capsule(style: .continuous).strokeBorder(style.hairline, lineWidth: 1) }
            }
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
            .modifier(EnabledOpacity())
    }
}

/// Toolbar-sized circular button for symbol-only actions.
struct GlyphActionStyle: ButtonStyle {
    let style: ReaderStyle
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(style.accent)
            .frame(width: 38, height: 38)
            .background(style.accentSoft, in: Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
            .modifier(EnabledOpacity())
    }
}

// MARK: - Theme picker

/// Miniature of a theme: page, card, ink and accent, in the theme's own colors.
struct ThemeSwatch: View {
    let theme: ReaderTheme
    let style: ReaderStyle
    let selected: Bool
    /// The Custom entry shows the colors this person actually picked.
    var accentOverride: Int?
    var backgroundOverride: Int?
    /// Small, label-free version for list rows.
    var compact = false
    /// Colors of the theme being previewed, not of the active one.
    private var preview: (background: Color, surface: Color, accent: Color, ink: Color) {
        let accent = Palette.color(accentOverride ?? theme.accentRGB)
        guard let background = backgroundOverride ?? theme.backgroundRGB else {
            return (style.background, style.surface, accent, style.ink)
        }
        return (Palette.color(background),
                Palette.color(theme.surfaceRGB ?? Palette.raised(background)),
                accent, Palette.ink(background))
    }
    var body: some View {
        let colors = preview
        let width: CGFloat = compact ? 54 : 92
        let height: CGFloat = compact ? 40 : 66
        return VStack(spacing: 7) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: compact ? 10 : 14, style: .continuous).fill(colors.background)
                if theme.design == .fable {
                    FableSwatch(theme: theme, compact: compact)
                } else if theme.design == .yohaku {
                    // 余白 paper: 儚い in the paper's ink, a brush rule and an accent dot.
                    let line = Palette.color(theme.accentRGB)
                    VStack(alignment: .leading, spacing: compact ? 2 : 5) {
                        Text("儚い").font(.custom(YohakuFont.minchoBold, size: compact ? 13 : 19))
                            .foregroundStyle(Palette.color(theme.inkRGB ?? 0x1A1A18))
                        BrushLine(width: 1.4).fill(line).frame(height: 5)
                        Circle().fill(Palette.color(theme.highlightRGB ?? theme.accentRGB)).frame(width: compact ? 4 : 6, height: compact ? 4 : 6)
                    }
                    .padding(compact ? 6 : 9)
                    .frame(width: width, height: height, alignment: .topLeading)
                } else {
                VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                    HStack(spacing: 4) {
                        Text("あ").font(.system(size: compact ? 12 : 17, weight: .semibold, design: .serif))
                            .foregroundStyle(colors.ink)
                        Circle().fill(colors.accent).frame(width: compact ? 5 : 7, height: compact ? 5 : 7)
                    }
                    RoundedRectangle(cornerRadius: compact ? 4 : 6, style: .continuous)
                        .fill(colors.surface)
                        .frame(height: compact ? 11 : 20)
                        .overlay(alignment: .leading) {
                            Capsule().fill(colors.accent.opacity(0.85))
                                .frame(width: compact ? 14 : 24, height: compact ? 2.5 : 3.5)
                                .padding(.leading, compact ? 4 : 6)
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: compact ? 4 : 6, style: .continuous)
                                .strokeBorder(colors.ink.opacity(0.10), lineWidth: 1)
                        )
                }
                .padding(compact ? 6 : 9)
                }
                if theme.id == ReaderTheme.systemID && !compact {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(colors.accent)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(style.onAccent, style.accent)
                        .padding(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(width: width, height: height)
            // Every swatch (paper, drawings, check mark) is clipped to the same rounded
            // corners as its outline, so no square paper shows behind the curve.
            .clipShape(RoundedRectangle(cornerRadius: compact ? 10 : 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 10 : 14, style: .continuous)
                    .strokeBorder(selected ? style.accent : style.hairline, lineWidth: selected ? 2.5 : 1)
            )
            .shadow(color: selected ? style.accent.opacity(0.25) : .clear, radius: 8, x: 0, y: 3)
            if !compact {
                Text(theme.name)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? style.accent : style.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(width: compact ? width : 96)
        .contentShape(Rectangle())
    }
}

// MARK: - Search helpers

/// Holds the scroll anchor outside SwiftUI state so scrolling does not re-render.
final class ScrollTracker {
    var anchor: CGFloat = 0
}

struct SearchHeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ResultsScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

enum ReaderText {
    /// Compact dictionary name for filter chips: drops publisher, edition and the
    /// trailing 辞典 so more dictionaries fit on one row. Full names stay elsewhere.
    static func shortDictionaryName(_ full: String) -> String {
        let base = full
            .replacingOccurrences(of: #"\s*[（(]?第\s*\d+\s*版[）)]?"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let short = base
            .replacingOccurrences(of: #"^[（(][^）)]*[）)]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^(大修館|旺文社|小学館|三省堂|研究社|講談社|朝日出版社|くろしお出版|岩波書店)\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(新|大)?(辞典|辞書)(?=\s|·|［|$)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return short.count >= 2 ? short : base
    }
}

/// Pull-down-and-release on a SwiftUI ScrollView, measured on the real UIKit
/// scroll view: how far the list is pulled past its top, and whether the finger
/// was lifted past the threshold (like pull to refresh). Put it in the scroll
/// view's content, e.g. `.background(PullRelease(...))`.
struct PullRelease: UIViewRepresentable {
    var threshold: CGFloat = 70
    /// Current pull distance (0 when not pulled); called while dragging.
    var pulled: (CGFloat) -> Void
    /// Finger lifted after pulling at least `threshold`.
    var released: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }
    func updateUIView(_ view: ProbeView, context: Context) {
        context.coordinator.threshold = threshold
        context.coordinator.pulled = pulled
        context.coordinator.released = released
        DispatchQueue.main.async { view.attach() }
    }
    static func dismantleUIView(_ view: ProbeView, coordinator: Coordinator) { coordinator.detach() }

    final class ProbeView: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }
        func attach() {
            var node = superview
            while let current = node, !(current is UIScrollView) { node = current.superview }
            if let scroll = node as? UIScrollView { coordinator?.attach(scroll) }
        }
    }

    final class Coordinator: NSObject {
        var threshold: CGFloat = 70
        var pulled: ((CGFloat) -> Void)?
        var released: (() -> Void)?
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var lastPull: CGFloat = 0

        func attach(_ scroll: UIScrollView) {
            guard scrollView !== scroll else { return }
            detach()
            scrollView = scroll
            scroll.alwaysBounceVertical = true
            scroll.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
            observation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                DispatchQueue.main.async { self?.report(scroll) }
            }
        }
        func detach() {
            scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(panned(_:)))
            observation?.invalidate(); observation = nil
            scrollView = nil
        }
        private func pull(of scroll: UIScrollView) -> CGFloat {
            max(0, -(scroll.contentOffset.y + scroll.adjustedContentInset.top))
        }
        private func report(_ scroll: UIScrollView) {
            // While the finger is down, or while the list springs back.
            let value = pull(of: scroll)
            guard abs(value - lastPull) > 0.5 || (value == 0 && lastPull != 0) else { return }
            lastPull = value
            pulled?(value)
        }
        @objc private func panned(_ pan: UIPanGestureRecognizer) {
            guard let scroll = scrollView else { return }
            switch pan.state {
            case .ended:
                if pull(of: scroll) >= threshold { released?() }
            default: break
            }
        }
    }
}

/// A navigation destination that is built when it is shown. A NavigationLink
/// evaluates its destination closure with the row, so a large page placed there
/// directly is constructed (on the caller's stack) every time the list is drawn.
struct LazyPage: View {
    let build: () -> AnyView
    var body: some View { build() }
}

// MARK: - Paste

private struct PasteWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The system Paste button with a stand-in. iOS draws that button itself (which is why it
/// needs no "Allow Paste" question), and on some phones it comes out with no size at all:
/// the button is simply not there. When that happens the app's own button is shown in its
/// place; it reads the clipboard directly, so iOS may ask "Allow Paste".
struct PasteControl<System: View, StandIn: View>: View {
    let paste: ([String]) -> Void
    @ViewBuilder let system: () -> System
    @ViewBuilder let standIn: (@escaping () -> Void) -> StandIn
    @State private var width: CGFloat = 0
    /// The system button gets a moment to be drawn before it is counted as missing.
    @State private var waited = false

    var body: some View {
        HStack(spacing: 0) {
            system()
                .background(GeometryReader { box in Color.clear.preference(key: PasteWidthKey.self, value: box.size.width) })
                .onPreferenceChange(PasteWidthKey.self) { width = $0 }
            if waited && width < 20 {
                standIn {
                    guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
                    paste([text])
                }
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(900))
            waited = true
        }
    }
}
