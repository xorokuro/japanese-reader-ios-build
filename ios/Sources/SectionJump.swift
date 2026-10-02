import SwiftUI

// 目次 — the section button. A small drawn icon that opens the list of sections on
// the current page; tapping one jumps straight to it. It sits in Library,
// Appearance, the 文法 list (one entry per category) and every 文法 lesson.
// The icon itself is a preset chosen in Appearance → Section button.

/// The drawings the section button can wear.
enum JumpIcon: String, CaseIterable, Identifiable {
    case lines, spark, ring, thread, figure, stitches, compass, moon
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lines: return "Lines"
        case .spark: return "Spark"
        case .ring: return "Ring"
        case .thread: return "Thread"
        case .figure: return "Figure"
        case .stitches: return "Stitches"
        case .compass: return "Compass"
        case .moon: return "Moon"
        }
    }
    static func resolve(_ raw: String) -> JumpIcon { JumpIcon(rawValue: raw) ?? .lines }
}

/// One preset, drawn by hand in the theme's line colour with a small spark of accent.
struct JumpIconView: View {
    let icon: JumpIcon
    let style: ReaderStyle
    var size: CGFloat = 26
    var body: some View {
        Canvas { context, canvas in
            let u = min(canvas.width, canvas.height)
            func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * u, y: y * u) }
            let line = style.accent, accent = style.isYohaku ? style.highlight : style.accent
            let weight = max(1.3, u * 0.062)
            func stroke(_ points: [CGPoint], seed: UInt64, colour: Color? = nil, width: CGFloat? = nil) {
                let path = Brush.ribbon(points.count > 3 ? points : Brush.polyline(points, step: 0.8),
                                        width: width ?? weight, seed: seed, wobble: 0.3, taper: 2)
                context.fill(path, with: .color(colour ?? line))
            }
            func dot(_ c: CGPoint, _ r: CGFloat, _ colour: Color) {
                context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(colour))
            }
            switch icon {
            case .lines:
                // A table of contents: three lines of different lengths, each with a dot.
                for (i, row) in ([(0.3, 0.9), (0.52, 0.74), (0.74, 0.84)] as [(CGFloat, CGFloat)]).enumerated() {
                    dot(P(0.14, row.0), u * 0.045, i == 0 ? accent : line)
                    stroke([P(0.3, row.0), P(row.1, row.0 - 0.01)], seed: UInt64(i + 3))
                }
            case .spark:
                var rays = Path()
                let c = P(0.5, 0.5)
                for i in 0..<8 {
                    let a = CGFloat(i) * .pi / 4 + 0.2
                    let long = u * (i % 2 == 0 ? 0.42 : 0.27)
                    rays.move(to: CGPoint(x: c.x + cos(a) * u * 0.1, y: c.y + sin(a) * u * 0.1))
                    rays.addLine(to: CGPoint(x: c.x + cos(a) * long, y: c.y + sin(a) * long))
                }
                context.stroke(rays, with: .color(accent), style: StrokeStyle(lineWidth: weight, lineCap: .round))
            case .ring:
                let start = -CGFloat.pi / 2 + 0.45, end = start + CGFloat.pi * 2 - 0.9
                stroke(FableStroke.arc(center: P(0.5, 0.52), radius: u * 0.36, from: start, to: end, seed: 21), seed: 22, width: weight * 1.5)
                dot(P(0.5, 0.52), u * 0.07, accent)
            case .thread:
                var points: [CGPoint] = []
                for i in 0...30 {
                    let t = CGFloat(i) / 30
                    points.append(P(0.5 + sin(t * .pi * 1.6 + 0.4) * 0.22, 0.08 + t * 0.84))
                }
                stroke(points, seed: 31)
                for (i, k) in [5, 15, 25].enumerated() { dot(points[k], u * 0.06, i == 1 ? accent : line) }
            case .figure:
                var path = Path()
                path.addEllipse(in: CGRect(x: u * 0.37, y: u * 0.12, width: u * 0.26, height: u * 0.28))
                path.move(to: P(0.14, 0.9))
                path.addCurve(to: P(0.5, 0.5), control1: P(0.14, 0.66), control2: P(0.3, 0.5))
                path.addCurve(to: P(0.86, 0.9), control1: P(0.7, 0.5), control2: P(0.86, 0.66))
                context.stroke(path, with: .color(line), style: StrokeStyle(lineWidth: weight, lineCap: .round, lineJoin: .round))
                dot(P(0.8, 0.2), u * 0.055, accent)
            case .stitches:
                var sewn = Path()
                for y in [0.28, 0.5, 0.72] as [CGFloat] {
                    FableArt.stitches(from: P(0.12, y), to: P(0.88, y), dash: u * 0.16, gap: u * 0.1, into: &sewn)
                }
                context.stroke(sewn, with: .color(line), style: StrokeStyle(lineWidth: weight, lineCap: .round))
                dot(P(0.2, 0.28), u * 0.05, accent)
            case .compass:
                stroke(FableStroke.arc(center: P(0.5, 0.5), radius: u * 0.38, from: 0, to: .pi * 2 + 0.15, seed: 41), seed: 42)
                var needle = Path()
                needle.addLines([P(0.66, 0.3), P(0.56, 0.56), P(0.44, 0.44)])
                needle.closeSubpath()
                context.fill(needle, with: .color(accent))
                var tail = Path()
                tail.addLines([P(0.34, 0.7), P(0.56, 0.56), P(0.44, 0.44)])
                tail.closeSubpath()
                context.stroke(tail, with: .color(line), style: StrokeStyle(lineWidth: weight * 0.7, lineJoin: .round))
            case .moon:
                var moon = Path()
                moon.addArc(center: P(0.46, 0.5), radius: u * 0.36, startAngle: .degrees(40), endAngle: .degrees(320), clockwise: false)
                moon.addArc(center: P(0.62, 0.5), radius: u * 0.27, startAngle: .degrees(300), endAngle: .degrees(60), clockwise: true)
                moon.closeSubpath()
                context.stroke(moon, with: .color(line), style: StrokeStyle(lineWidth: weight, lineCap: .round, lineJoin: .round))
                dot(P(0.82, 0.24), u * 0.05, accent)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The button. `sections` reports the page's section titles when asked (lesson pages
/// read theirs from the web page, so it is asynchronous); `jump` goes to one.
struct SectionJump: View {
    let style: ReaderStyle
    let sections: (@escaping ([String]) -> Void) -> Void
    let jump: (Int) -> Void
    @AppStorage("sectionJumpIcon") private var iconRaw = JumpIcon.lines.rawValue
    /// The list on show. Passed to the sheet as its item, so the sheet is always
    /// built with the titles that were just fetched.
    private struct Listing: Identifiable {
        let id = UUID()
        let titles: [String]
    }
    @State private var listing: Listing?

    init(style: ReaderStyle, titles: [String], jump: @escaping (Int) -> Void) {
        self.style = style
        self.sections = { $0(titles) }
        self.jump = jump
    }
    init(style: ReaderStyle, sections: @escaping (@escaping ([String]) -> Void) -> Void, jump: @escaping (Int) -> Void) {
        self.style = style
        self.sections = sections
        self.jump = jump
    }

    var body: some View {
        Button {
            sections { found in
                listing = found.isEmpty ? nil : Listing(titles: found)
            }
        } label: {
            JumpIconView(icon: JumpIcon.resolve(iconRaw), style: style, size: 26)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sections")
        .accessibilityIdentifier("sectionJump")
        .sheet(item: $listing) { shown in
            SectionJumpList(style: style, titles: shown.titles) { index in
                listing = nil
                // After the sheet starts closing, so the page underneath can scroll.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { jump(index) }
            }
            .presentationDetents(shown.titles.count > 7 ? [.medium, .large] : [.medium])
            .presentationDragIndicator(.visible)
        }
    }
}

struct SectionJumpList: View {
    let style: ReaderStyle
    let titles: [String]
    let pick: (Int) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("目次").font(HandFont.title(24)).foregroundStyle(style.isYohaku ? style.navy : style.ink)
                Text(style.isFable ? "jump to a section" : "Sections")
                    .font(style.isFable ? .custom(YohakuFont.caption, size: 17) : .system(size: 13, weight: .semibold))
                    .foregroundStyle(style.secondary)
            }
            .padding(.horizontal, 22).padding(.top, 26).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                        Button { pick(index) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Text(String(format: "%02d", index + 1))
                                    .font(style.isFable ? .custom(YohakuFont.captionLight, size: 19) : .system(size: 13, weight: .medium).monospacedDigit())
                                    .foregroundStyle(style.secondary)
                                    .frame(width: 30, alignment: .leading)
                                Text(title).font(HandFont.body(18)).foregroundStyle(style.ink)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 13)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("sectionJump_\(index)")
                        Rectangle().fill(style.isYohaku ? style.rule.opacity(0.5) : style.hairline).frame(height: 0.7)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(style.background.ignoresSafeArea())
        .preferredColorScheme(style.colorScheme)
    }
}

/// Appearance → Section button: pick the drawing.
struct JumpIconPicker: View {
    let style: ReaderStyle
    @AppStorage("sectionJumpIcon") private var iconRaw = JumpIcon.lines.rawValue
    private let columns = [GridItem(.adaptive(minimum: 64, maximum: 84), spacing: 10)]
    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(JumpIcon.allCases) { icon in
                let selected = icon.rawValue == JumpIcon.resolve(iconRaw).rawValue
                Button { iconRaw = icon.rawValue } label: {
                    VStack(spacing: 6) {
                        JumpIconView(icon: icon, style: style, size: 30)
                            .frame(width: 54, height: 54)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? style.accentSoft : Color.clear))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(selected ? style.accent : style.hairline, lineWidth: selected ? 2 : 1))
                        Text(icon.title).font(.system(size: 11, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? style.accent : style.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("jumpIcon_" + icon.rawValue)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(.vertical, 6)
    }
}

/// Section titles of a lesson page (the text of each `h2`, without its small note),
/// and the script that scrolls to one.
enum LessonOutline {
    static let titles = """
    (() => JSON.stringify([...document.querySelectorAll('section > h2')].map(h => {
        const c = h.cloneNode(true);
        c.querySelectorAll('small, rt').forEach(e => e.remove());
        return c.textContent.replace(/\\s+/g, ' ').trim();
    })))()
    """
    static func jump(_ index: Int) -> String {
        "(() => { const h = document.querySelectorAll('section > h2')[\(index)]; if (!h) return false; const s = h.closest('section') || h; window.scrollTo({ top: s.getBoundingClientRect().top + window.scrollY - 6, behavior: 'smooth' }); return true; })()"
    }
}
