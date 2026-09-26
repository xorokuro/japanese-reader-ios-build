import SwiftUI
import UIKit
import CoreText

// The desktop reader's "Washi" look on iPhone: pencil-drawn cards with an offset
// shadow, washi tape, highlighter titles, a wavy rule, paper grain and doodles.
// Everything here is drawn once and cached, so it costs nothing while scrolling.

enum HandFont {
    /// Klee One (SIL Open Font License), bundled: a pencil-textbook Japanese face.
    static let regular = "KleeOne-Regular"
    static let bold = "KleeOne-SemiBold"
    static func register() {
        for name in [regular, bold] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
    static func title(_ size: CGFloat) -> Font { .custom(bold, size: size) }
    static func body(_ size: CGFloat) -> Font { .custom(regular, size: size) }
}

// MARK: - Shapes

/// A rounded rectangle whose corners and edges are each a little different,
/// like the desktop's `border-radius` "wobble".
struct SketchShape: Shape {
    var radius: CGFloat = 20
    var variant = 0
    func path(in rect: CGRect) -> Path {
        let limit = max(2, min(rect.width, rect.height) / 2)
        let jitter: [CGFloat] = variant % 2 == 0
            ? [2, -3, 4, -2, -2, 3, -3, 2]
            : [6, -4, 2, 5, -1, 5, -4, 1]
        func r(_ index: Int) -> CGFloat { min(max(2, radius + jitter[index]), limit) }
        let tl = CGSize(width: r(0), height: r(4)), tr = CGSize(width: r(1), height: r(5))
        let br = CGSize(width: r(2), height: r(6)), bl = CGSize(width: r(3), height: r(7))
        let lean: CGFloat = variant % 2 == 0 ? 0.6 : -0.6
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + tl.width, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr.width, y: rect.minY + lean))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + tr.height), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - lean, y: rect.maxY - br.height))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - br.width, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + bl.width, y: rect.maxY - lean))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - bl.height), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + lean, y: rect.minY + tl.height))
        path.addQuadCurve(to: CGPoint(x: rect.minX + tl.width, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// The torn edge of a strip of washi tape.
struct TapeEdge: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [(CGFloat, CGFloat)] = [(0.03, 0), (0.97, 0.04), (1, 0.22), (0.96, 0.40), (1, 0.62),
                                            (0.97, 1), (0.02, 0.96), (0, 0.74), (0.04, 0.52), (0, 0.30)]
        var path = Path()
        for (index, point) in points.enumerated() {
            let location = CGPoint(x: rect.minX + rect.width * point.0, y: rect.minY + rect.height * point.1)
            if index == 0 { path.move(to: location) } else { path.addLine(to: location) }
        }
        path.closeSubpath()
        return path
    }
}

/// A gently wavy pencil line, used under headers.
struct WavyLine: Shape {
    var wavelength: CGFloat = 30
    var amplitude: CGFloat = 2.6
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midY
        let half = wavelength / 2
        var x = rect.minX
        var up = true
        path.move(to: CGPoint(x: x, y: mid))
        while x < rect.maxX {
            path.addQuadCurve(to: CGPoint(x: x + half, y: mid),
                              control: CGPoint(x: x + half / 2, y: up ? mid - amplitude * 2 : mid + amplitude * 2))
            x += half
            up.toggle()
        }
        return path
    }
}

// MARK: - Pieces

struct WashiTape: View {
    enum Kind { case tape, marker }
    let kind: Kind
    let style: ReaderStyle
    var width: CGFloat = 104
    var body: some View {
        let color = kind == .tape ? style.tape : style.marker
        Canvas { context, size in
            let stripe: CGFloat = 7
            var x = -size.height
            var index = 0
            while x < size.width + size.height {
                var band = Path()
                band.move(to: CGPoint(x: x, y: size.height))
                band.addLine(to: CGPoint(x: x + size.height, y: 0))
                band.addLine(to: CGPoint(x: x + size.height + stripe, y: 0))
                band.addLine(to: CGPoint(x: x + stripe, y: size.height))
                band.closeSubpath()
                context.fill(band, with: .color(color.opacity(index % 2 == 0 ? 0.62 : 0.40)))
                x += stripe
                index += 1
            }
        }
        .frame(width: width, height: 24)
        .clipShape(TapeEdge())
        .opacity(0.92)
        .rotationEffect(.degrees(kind == .tape ? -5 : 4))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Section title with a highlighter stroke behind it (desktop `.hand-title`).
struct HandTitle: View {
    let text: String
    var subtitle: String? = nil
    let style: ReaderStyle
    var size: CGFloat = 24
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .font(HandFont.title(size))
                .foregroundStyle(style.ink)
                .padding(.horizontal, 3)
                .background {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(style.marker.opacity(style.isDark ? 0.34 : 0.42))
                            .frame(width: proxy.size.width, height: proxy.size.height * 0.32)
                            .position(x: proxy.size.width / 2, y: proxy.size.height * 0.74)
                    }
                }
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(style.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The red "辞" seal of the desktop dictionary panel.
struct HandSeal: View {
    let text: String
    let style: ReaderStyle
    var size: CGFloat = 32
    var body: some View {
        Text(text)
            .font(HandFont.title(size * 0.54))
            .foregroundStyle(style.onAccent)
            .frame(width: size, height: size)
            .background(style.accent, in: SketchShape(radius: size * 0.3))
            .overlay(SketchShape(radius: size * 0.3).stroke(style.onAccent.opacity(0.3), lineWidth: 2).padding(2))
            .rotationEffect(.degrees(-4))
            .accessibilityHidden(true)
    }
}

/// Ensō brush circle around a character: the desktop logo.
struct EnsoLogo: View {
    let style: ReaderStyle
    var text = "読"
    var size: CGFloat = 42
    @State private var drawn = false
    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.04, to: drawn ? 0.93 : 0.04)
                .stroke(style.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-70))
                .padding(2)
            Text(text).font(HandFont.title(size * 0.46)).foregroundStyle(style.ink)
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(.easeOut(duration: 1.2)) { drawn = true } }
        .accessibilityHidden(true)
    }
}

/// The wavy rule under the desktop's top bar.
struct HandRule: View {
    let style: ReaderStyle
    var body: some View {
        WavyLine()
            .stroke(style.ink.opacity(0.22), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(height: 8)
            .accessibilityHidden(true)
    }
}

// MARK: - Cards

struct SketchCardModifier: ViewModifier {
    let style: ReaderStyle
    var radius: CGFloat = 20
    var tape: WashiTape.Kind? = nil
    var tapeTrailing = false
    var fill: Color? = nil
    var shadow: CGSize = CGSize(width: 4, height: 6)
    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    SketchShape(radius: radius).fill(style.shade).offset(shadow)
                    SketchShape(radius: radius).fill(fill ?? style.surface)
                    SketchShape(radius: radius).stroke(style.lineStrong, lineWidth: 1.5)
                    SketchShape(radius: radius + 4, variant: 1)
                        .stroke(style.pencil, lineWidth: 1.1)
                        .padding(-3)
                        .rotationEffect(.degrees(-0.3))
                }
                .allowsHitTesting(false)
            }
            .overlay(alignment: tapeTrailing ? .topTrailing : .topLeading) {
                if let tape {
                    WashiTape(kind: tape, style: style, width: tapeTrailing ? 92 : 108)
                        .offset(x: tapeTrailing ? -40 : 36, y: -12)
                }
            }
    }
}

/// Small sketched pill for chips and secondary buttons.
struct SketchPill: ViewModifier {
    let style: ReaderStyle
    var selected = false
    func body(content: Content) -> some View {
        content
            .background(selected ? style.accent : style.surface, in: SketchShape(radius: 13))
            .overlay(SketchShape(radius: 13).stroke(selected ? Color.clear : style.lineStrong, lineWidth: 1.3))
            .background(SketchShape(radius: 13).fill(style.shade).offset(x: 2, y: 3))
    }
}

extension View {
    func sketchCard(_ style: ReaderStyle, radius: CGFloat = 20, tape: WashiTape.Kind? = nil,
                    tapeTrailing: Bool = false, fill: Color? = nil,
                    shadow: CGSize = CGSize(width: 4, height: 6)) -> some View {
        modifier(SketchCardModifier(style: style, radius: radius, tape: tape, tapeTrailing: tapeTrailing,
                                    fill: fill, shadow: shadow))
    }
    func sketchPill(_ style: ReaderStyle, selected: Bool = false) -> some View {
        modifier(SketchPill(style: style, selected: selected))
    }
}

/// Primary action in the hand-drawn style: filled accent, pencil outline, offset shadow.
struct HandPrimaryButtonStyle: ButtonStyle {
    let style: ReaderStyle
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HandFont.title(16))
            .foregroundStyle(style.onAccent)
            .padding(.horizontal, 18)
            .frame(minHeight: 42)
            .background(style.accent, in: SketchShape(radius: 14))
            .overlay(SketchShape(radius: 14, variant: 1).stroke(style.ink.opacity(0.25), lineWidth: 1.2))
            .background(SketchShape(radius: 14).fill(style.shade).offset(x: configuration.isPressed ? 1 : 3, y: configuration.isPressed ? 1 : 4))
            .offset(x: configuration.isPressed ? 2 : 0, y: configuration.isPressed ? 3 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Secondary action: card-coloured sketched pill.
struct HandSoftButtonStyle: ButtonStyle {
    let style: ReaderStyle
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(prominent ? style.accent : style.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(prominent ? style.accentSoft : style.surface, in: SketchShape(radius: 12))
            .overlay(SketchShape(radius: 12).stroke(style.lineStrong, lineWidth: 1.3))
            .background(SketchShape(radius: 12).fill(style.shade).offset(x: configuration.isPressed ? 1 : 2, y: configuration.isPressed ? 1 : 3))
            .offset(x: configuration.isPressed ? 1 : 0, y: configuration.isPressed ? 2 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Paper

/// Deterministic pseudo-random numbers so the doodles never jump between launches.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    /// A value in 0..<1.
    mutating func unit() -> CGFloat { CGFloat(next() % 1_000_000) / 1_000_000 }
}

enum PaperTexture {
    private static var grainCache: [Bool: UIImage] = [:]
    /// A small tile of paper fibre speckles, generated once.
    static func grain(dark: Bool) -> UIImage {
        if let cached = grainCache[dark] { return cached }
        let side = 128
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        var random = SeededRandom(seed: dark ? 71 : 42)
        let tint = dark ? UIColor.white : UIColor(red: 0.45, green: 0.38, blue: 0.30, alpha: 1)
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            for _ in 0..<(side * side / 3) {
                let x = Int(random.next() % UInt64(side)), y = Int(random.next() % UInt64(side))
                let alpha = random.unit() * (dark ? 0.05 : 0.10)
                tint.withAlphaComponent(alpha).setFill()
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        grainCache[dark] = image
        return image
    }
}

/// One pre-built doodle: its pencil strokes in local coordinates, plus placement.
struct Doodle {
    struct Stroke {
        let path: Path
        let fill: Double
        let width: CGFloat
        let opacity: Double
    }
    let center: CGPoint
    let angle: Double
    let colorIndex: Int
    let strokes: [Stroke]
    let kana: String?
    let size: CGFloat
}

enum DoodleLibrary {
    static let tile = CGSize(width: 560, height: 760)
    private static var cache: [String: [Doodle]] = [:]
    private static let kanaSet = Array("あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん")

    typealias Outline = (points: [CGPoint], closed: Bool, fill: Double)

    private static func points(_ values: [CGFloat]) -> [CGPoint] {
        stride(from: 0, to: values.count - 1, by: 2).map { CGPoint(x: values[$0], y: values[$0 + 1]) }
    }
    private static func ring(_ r: CGFloat, _ n: Int, from: CGFloat = 0, to: CGFloat = .pi * 2) -> [CGPoint] {
        var result: [CGPoint] = []
        for i in 0...n {
            let a = from + (to - from) * CGFloat(i) / CGFloat(n)
            result.append(CGPoint(x: cos(a) * r, y: sin(a) * r))
        }
        return result
    }
    private static func shifted(_ list: [CGPoint], _ dx: CGFloat, _ dy: CGFloat, scale: CGFloat = 1) -> [CGPoint] {
        list.map { CGPoint(x: $0.x * scale + dx, y: $0.y * scale + dy) }
    }
    private static func radial(_ count: Int, inner: CGFloat) -> [CGPoint] {
        var result: [CGPoint] = []
        for i in 0..<count {
            let a = -CGFloat.pi / 2 + CGFloat(i) * .pi * 2 / CGFloat(count)
            let r: CGFloat = i % 2 == 1 ? inner : 1
            result.append(CGPoint(x: cos(a) * r, y: sin(a) * r))
        }
        return result
    }

    /// Motif outlines in a unit box, ported from the desktop's theme.js.
    private static func motif(_ name: String) -> [Outline] {
        let petal = points([0, -0.72, 0.2, -1, 0.46, -0.8, 0.6, -0.3, 0.46, 0.3, 0.16, 0.8, 0, 0.95,
                            -0.16, 0.8, -0.46, 0.3, -0.6, -0.3, -0.46, -0.8, -0.2, -1])
        var outlines: [Outline] = []
        switch name {
        case "star":
            outlines.append((radial(10, inner: 0.44), true, 0.18))
        case "sparkle":
            outlines.append((radial(8, inner: 0.2), true, 0.25))
        case "petal":
            outlines.append((shifted(petal, 0, 0, scale: 0.8), true, 0.22))
        case "sakura":
            for k in 0..<5 {
                let a = CGFloat(k) * .pi * 2 / 5
                var rotated: [CGPoint] = []
                for p in petal {
                    let x = p.x * 0.5, y = p.y * 0.5 - 0.52
                    rotated.append(CGPoint(x: x * cos(a) - y * sin(a), y: x * sin(a) + y * cos(a)))
                }
                outlines.append((rotated, true, 0.16))
            }
            outlines.append((ring(0.13, 6), true, 0.5))
        case "heart":
            outlines.append((points([0, -0.45, 0.35, -0.9, 0.85, -0.65, 0.8, -0.05, 0, 0.8, -0.8, -0.05, -0.85, -0.65, -0.35, -0.9]), true, 0.2))
        case "wave":
            for r in [CGFloat(1), 0.68, 0.36] {
                outlines.append((shifted(ring(r, 10, from: .pi, to: .pi * 2), 0, 0.45), false, 0))
            }
        case "cloud":
            var line: [CGPoint] = [CGPoint(x: -1, y: 0.35)]
            let bumps: [[CGFloat]] = [[-0.58, 0.38, 1.0, 1.9], [0.02, 0.55, 1.1, 1.95], [0.62, 0.36, 1.15, 2.0]]
            for bump in bumps {
                for i in 0...5 {
                    let t = CGFloat.pi * (bump[2] + (bump[3] - bump[2]) * CGFloat(i) / 5)
                    line.append(CGPoint(x: bump[0] + cos(t) * bump[1], y: 0.35 + sin(t) * bump[1]))
                }
            }
            line.append(CGPoint(x: 1, y: 0.35))
            outlines.append((line, true, 0.12))
        case "dots":
            let dots: [[CGFloat]] = [[-0.5, 0.2, 0.14], [0.1, -0.3, 0.1], [0.5, 0.35, 0.17]]
            for dot in dots { outlines.append((shifted(ring(dot[2], 6), dot[0], dot[1]), true, 0.55)) }
        case "leaf":
            outlines.append((points([0, -1, 0.46, -0.55, 0.5, 0, 0.26, 0.55, 0, 0.8, -0.26, 0.55, -0.5, 0, -0.46, -0.55]), true, 0.16))
            outlines.append(([CGPoint(x: 0, y: -0.8), CGPoint(x: 0, y: 1.02)], false, 0))
        case "moon":
            let outer = ring(0.95, 12, from: .pi * 0.35, to: .pi * 1.65)
            let inner = shifted(ring(0.72, 10, from: .pi * 1.55, to: .pi * 0.45), -0.38, 0)
            outlines.append((outer + inner, true, 0.22))
        default:
            outlines.append((ring(0.8, 14), true, 0.06))
        }
        return outlines
    }

    /// Catmull-Rom-ish smoothing through the wobbled points.
    private static func smooth(_ points: [CGPoint], closed: Bool) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        if closed {
            let count = points.count
            func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
            path.move(to: mid(points[count - 1], points[0]))
            for i in 0..<count {
                path.addQuadCurve(to: mid(points[i], points[(i + 1) % count]), control: points[i])
            }
            path.closeSubpath()
        } else {
            path.move(to: points[0])
            for i in 1..<points.count {
                let previous = points[i - 1], current = points[i]
                path.addQuadCurve(to: CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2), control: previous)
                if i == points.count - 1 { path.addLine(to: current) }
            }
        }
        return path
    }

    static func doodles(for style: ReaderStyle, count: Int = 13) -> [Doodle] {
        let signature = style.theme.id + (style.isDark ? "-dark" : "-light")
        if let cached = cache[signature] { return cached }
        var random = SeededRandom(seed: UInt64(bitPattern: Int64(signature.hashValueStable)) | 1)
        let motifs = style.isDark
            ? ["star", "sparkle", "kana", "moon", "dots", "petal", "cloud", "star"]
            : ["sakura", "cloud", "wave", "kana", "star", "petal", "dots", "heart", "leaf"]
        var placed: [Doodle] = []
        var tries = 0
        while placed.count < count && tries < count * 40 {
            tries += 1
            let size = 16 + random.unit() * 20
            let center = CGPoint(x: 30 + random.unit() * (tile.width - 60), y: 30 + random.unit() * (tile.height - 60))
            if placed.contains(where: { hypot($0.center.x - center.x, $0.center.y - center.y) < ($0.size + size) * 1.9 }) { continue }
            let name = motifs[Int(random.next() % UInt64(motifs.count))]
            let colorIndex = Int(random.next() % 4)
            let angle = Double(random.unit() - 0.5) * 50
            if name == "kana" {
                let kana = String(kanaSet[Int(random.next() % UInt64(kanaSet.count))])
                placed.append(Doodle(center: center, angle: angle * 0.6, colorIndex: colorIndex, strokes: [], kana: kana, size: size))
                continue
            }
            var strokes: [Doodle.Stroke] = []
            for outline in motif(name) {
                for pass in 0..<2 {
                    let wobble: CGFloat = pass == 0 ? 0.035 : 0.07
                    let wobbled = outline.points.map { p in
                        CGPoint(x: (p.x + (random.unit() - 0.5) * wobble) * size, y: (p.y + (random.unit() - 0.5) * wobble) * size)
                    }
                    strokes.append(Doodle.Stroke(path: smooth(wobbled, closed: outline.closed),
                                                 fill: pass == 0 ? outline.fill : 0,
                                                 width: pass == 0 ? 1.7 : 1, opacity: pass == 0 ? 0.9 : 0.45))
                }
            }
            placed.append(Doodle(center: center, angle: angle, colorIndex: colorIndex, strokes: strokes, kana: nil, size: size))
        }
        cache[signature] = placed
        return placed
    }
}

private extension String {
    /// `hashValue` changes every launch; this does not.
    var hashValueStable: Int {
        var hash = 5381
        for scalar in unicodeScalars { hash = (hash &* 33) &+ Int(scalar.value) }
        return hash
    }
}

/// Faint hand-drawn motifs scattered over the paper, tiled across the screen.
struct DoodleField: View, Equatable {
    let style: ReaderStyle
    var body: some View {
        let doodles = DoodleLibrary.doodles(for: style)
        let palette = [style.accent, style.tape, style.marker, Palette.color(style.isDark ? 0xC4B5FF : 0x7F9FC4)]
        Canvas { context, size in
            let tile = DoodleLibrary.tile
            var originY: CGFloat = 0
            while originY < size.height {
                var originX: CGFloat = 0
                while originX < size.width {
                    for doodle in doodles {
                        var layer = context
                        layer.translateBy(x: originX + doodle.center.x, y: originY + doodle.center.y)
                        layer.rotate(by: .degrees(doodle.angle))
                        let color = palette[doodle.colorIndex % palette.count]
                        if let kana = doodle.kana {
                            layer.opacity = 0.55
                            layer.draw(Text(kana).font(HandFont.body(doodle.size * 1.4)).foregroundColor(color), at: .zero)
                            continue
                        }
                        for stroke in doodle.strokes {
                            if stroke.fill > 0 { layer.fill(stroke.path, with: .color(color.opacity(stroke.fill))) }
                            layer.stroke(stroke.path, with: .color(color.opacity(stroke.opacity)),
                                         style: StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round))
                        }
                    }
                    originX += tile.width
                }
                originY += tile.height
            }
        }
    }
    static func == (lhs: DoodleField, rhs: DoodleField) -> Bool { lhs.style == rhs.style }
}

/// Paper colour, fibre grain and doodles behind a screen. Pass `texture: false`
/// for the plain look (Appearance → Hand-drawn paper).
struct PaperBackground: View, Equatable {
    let style: ReaderStyle
    var texture = true
    var body: some View {
        ZStack {
            style.background
            if texture {
                Image(uiImage: PaperTexture.grain(dark: style.isDark))
                    .resizable(resizingMode: .tile)
                    .blendMode(style.isDark ? .screen : .multiply)
                    .opacity(style.isDark ? 0.55 : 1)
                DoodleField(style: style)
                    .equatable()
                    .opacity(style.isDark ? 0.42 : 0.6)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
