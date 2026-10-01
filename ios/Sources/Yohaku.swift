import SwiftUI
import UIKit
import CoreText

// 余白 Yohaku — the editorial theme: Swiss modernism / New Bauhaus layouts (empty
// space, asymmetry, numbered labels) made warm by two things: a fine, even paper
// grain, and hand-drawn brush lines of uneven thickness that are never ruler
// straight. Six paper palettes (ReaderTheme.editorial). The hand-drawn Washi helpers
// in HandDrawn.swift and ReaderComponents.swift switch to this look while it is on.

enum YohakuDesign {
    /// Set whenever the reader style is resolved; read by shapes and fonts that
    /// have no style of their own (SketchShape, HandFont).
    nonisolated(unsafe) static var active = false
    /// The active Yohaku style (palette), for pages built outside SwiftUI.
    nonisolated(unsafe) static var style: ReaderStyle?
}

// MARK: - Type

enum YohakuFont {
    /// Zen Kaku Gothic New: titles and interface.
    static let gothic = "ZenKakuGothicNew-Regular"
    static let gothicBold = "ZenKakuGothicNew-Bold"
    /// Shippori Mincho B1 (JIS X 0208 subset): headwords and example sentences.
    static let mincho = "ShipporiMinchoB1-Medium"
    static let minchoBold = "ShipporiMinchoB1-ExtraBold"
    /// Hanken Grotesk: numerals and small letter-spaced labels.
    static let latinLight = "HankenGrotesk-Light"
    static let latin = "HankenGrotesk-SemiBold"
    static let latinBold = "HankenGrotesk-Bold"
    static let files = [gothic, gothicBold, mincho, minchoBold, latinLight, latin, latinBold]

    static func register() {
        for name in files {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
    static func title(_ size: CGFloat) -> Font { .custom(gothicBold, size: size) }
    static func body(_ size: CGFloat) -> Font { .custom(gothic, size: size) }
    static func headword(_ size: CGFloat) -> Font { .custom(minchoBold, size: size) }
    static func example(_ size: CGFloat) -> Font { .custom(mincho, size: size) }
    static func numeral(_ size: CGFloat) -> Font { .custom(latinLight, size: size) }
    static func label(_ size: CGFloat = 10) -> Font { .custom(latinBold, size: size) }
    static func uiFont(_ name: String, _ size: CGFloat) -> UIFont { UIFont(name: name, size: size) ?? .systemFont(ofSize: size) }
}

// MARK: - Brush strokes

/// Smooth 1-D value noise from a fixed seed, so a stroke never changes between redraws.
struct BrushNoise {
    private let values: [CGFloat]
    init(seed: UInt64, count: Int = 61) {
        var random = SeededRandom(seed: seed &* 0x9E3779B97F4A7C15 | 1)
        values = (0..<count).map { _ in random.unit() * 2 - 1 }
    }
    /// A value in -1...1; `x` is in lattice units.
    func at(_ x: CGFloat) -> CGFloat {
        let n = values.count
        let cell = Int(floor(x))
        let f = x - floor(x)
        let a = values[((cell % n) + n) % n], b = values[(((cell + 1) % n) + n) % n]
        let t = (1 - cos(f * .pi)) / 2
        return a + (b - a) * t
    }
}

/// Builds filled outlines around a centre line: the line wanders off its path by
/// about 0.5–1 px and its width varies (about 0.75–1.2×), tapering at open ends.
enum Brush {
    /// Points every ~2 pt from `a` to `b`.
    static func line(_ a: CGPoint, _ b: CGPoint, step: CGFloat = 2) -> [CGPoint] {
        let length = hypot(b.x - a.x, b.y - a.y)
        let count = max(2, Int(length / step) + 1)
        return (0..<count).map { i in
            let t = CGFloat(i) / CGFloat(count - 1)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }
    static func polyline(_ corners: [CGPoint], step: CGFloat = 1.5) -> [CGPoint] {
        guard corners.count > 1 else { return corners }
        var points: [CGPoint] = []
        for i in 1..<corners.count {
            var part = line(corners[i - 1], corners[i], step: step)
            if i > 1 { part.removeFirst() }
            points += part
        }
        return points
    }
    /// A hand-drawn ring: starts at a seeded angle and overlaps itself a little.
    static func circle(center: CGPoint, radius: CGFloat, seed: UInt64) -> [CGPoint] {
        var random = SeededRandom(seed: seed | 1)
        let start = random.unit() * .pi * 2
        let sweep = CGFloat.pi * 2 + 0.22
        let squash = 1 + (random.unit() - 0.5) * 0.04
        let count = max(24, Int(radius * sweep / 2))
        let noise = BrushNoise(seed: seed &+ 77)
        return (0...count).map { i in
            let a = start + sweep * CGFloat(i) / CGFloat(count)
            let r = radius * (1 + noise.at(CGFloat(i) / 14) * 0.012)
            return CGPoint(x: center.x + cos(a) * r * squash, y: center.y + sin(a) * r / squash)
        }
    }

    static func ribbon(_ points: [CGPoint], width: CGFloat, seed: UInt64, wobble: CGFloat = 0.75, taper: CGFloat = 7) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        var lengths: [CGFloat] = [0]
        for i in 1..<points.count {
            lengths.append(lengths[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
        }
        let total = max(lengths.last ?? 1, 0.001)
        let drift = BrushNoise(seed: seed), thickness = BrushNoise(seed: seed &+ 101)
        var left: [CGPoint] = [], right: [CGPoint] = []
        left.reserveCapacity(points.count); right.reserveCapacity(points.count)
        for i in 0..<points.count {
            let previous = points[max(0, i - 1)], next = points[min(points.count - 1, i + 1)]
            var dx = next.x - previous.x, dy = next.y - previous.y
            let d = max(hypot(dx, dy), 0.0001)
            dx /= d; dy /= d
            let normal = CGPoint(x: -dy, y: dx)
            let s = lengths[i]
            let offset = drift.at(s / 23) * wobble
            var w = width * (0.975 + thickness.at(s / 31) * 0.225)
            let end = min(s, total - s)
            if end < taper { w *= max(0.3, sqrt(end / taper)) }
            let half = w / 2
            left.append(CGPoint(x: points[i].x + normal.x * (offset + half), y: points[i].y + normal.y * (offset + half)))
            right.append(CGPoint(x: points[i].x + normal.x * (offset - half), y: points[i].y + normal.y * (offset - half)))
        }
        path.addLines(left + right.reversed())
        path.closeSubpath()
        return path
    }

    /// A stable seed for a shape of a given size, so lines differ from each other
    /// but never change between redraws.
    static func seed(_ rect: CGRect, _ salt: UInt64 = 0) -> UInt64 {
        UInt64(max(1, Int(rect.width * 7 + rect.height * 131))) &+ salt
    }
}

/// A horizontal brush rule across the middle of its frame (give it a height of ~6).
struct BrushLine: Shape {
    var width: CGFloat = 1.7
    var seed: UInt64 = 0
    func path(in rect: CGRect) -> Path {
        Brush.ribbon(Brush.line(CGPoint(x: rect.minX + 0.5, y: rect.midY), CGPoint(x: rect.maxX - 0.5, y: rect.midY)),
                     width: width, seed: seed == 0 ? Brush.seed(rect) : seed)
    }
}

/// A vertical brush rule down the middle of its frame.
struct BrushVLine: Shape {
    var width: CGFloat = 1.5
    var seed: UInt64 = 0
    func path(in rect: CGRect) -> Path {
        Brush.ribbon(Brush.line(CGPoint(x: rect.midX, y: rect.minY + 0.5), CGPoint(x: rect.midX, y: rect.maxY - 0.5)),
                     width: width, seed: seed == 0 ? Brush.seed(rect, 9) : seed)
    }
}

/// An outline box of four strokes that overshoot the corners a little.
struct BrushBox: Shape {
    var width: CGFloat = 1.6
    var seed: UInt64 = 0
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: width / 2 + 0.5, dy: width / 2 + 0.5)
        let s = seed == 0 ? Brush.seed(rect, 3) : seed
        let o: CGFloat = 1.4
        var path = Path()
        path.addPath(Brush.ribbon(Brush.line(CGPoint(x: r.minX - o, y: r.minY), CGPoint(x: r.maxX + o * 0.5, y: r.minY + 0.3)), width: width, seed: s, taper: 4))
        path.addPath(Brush.ribbon(Brush.line(CGPoint(x: r.maxX, y: r.minY - o * 0.5), CGPoint(x: r.maxX - 0.3, y: r.maxY + o)), width: width, seed: s &+ 1, taper: 4))
        path.addPath(Brush.ribbon(Brush.line(CGPoint(x: r.maxX + o * 0.5, y: r.maxY), CGPoint(x: r.minX - o * 0.5, y: r.maxY - 0.3)), width: width, seed: s &+ 2, taper: 4))
        path.addPath(Brush.ribbon(Brush.line(CGPoint(x: r.minX, y: r.maxY + o * 0.5), CGPoint(x: r.minX + 0.3, y: r.minY - o)), width: width, seed: s &+ 3, taper: 4))
        return path
    }
}

/// A hand-drawn circle inscribed in its frame.
struct BrushCircle: Shape {
    var width: CGFloat = 1.6
    var seed: UInt64 = 0
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2 - width
        return Brush.ribbon(Brush.circle(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                                         seed: seed == 0 ? Brush.seed(rect, 5) : seed),
                            width: width, seed: seed == 0 ? Brush.seed(rect, 6) : seed, taper: 9)
    }
}

/// A solid block with slightly rough, torn-looking edges (the primary button).
struct TornRect: Shape {
    var roughness: CGFloat = 1.3
    var seed: UInt64 = 0
    func path(in rect: CGRect) -> Path {
        let noise = BrushNoise(seed: seed == 0 ? Brush.seed(rect, 11) : seed)
        let fine = BrushNoise(seed: (seed == 0 ? Brush.seed(rect, 11) : seed) &+ 3)
        let r = rect.insetBy(dx: roughness, dy: roughness)
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY)]
        var points: [CGPoint] = []
        var s: CGFloat = 0
        for i in 1..<corners.count {
            let a = corners[i - 1], b = corners[i]
            let length = hypot(b.x - a.x, b.y - a.y)
            let normal = CGPoint(x: (b.y - a.y) / length, y: -(b.x - a.x) / length)
            for p in Brush.line(a, b, step: 1.6).dropLast() {
                let jag = noise.at(s / 9) * roughness * 0.8 + fine.at(s / 2.3) * roughness * 0.45
                points.append(CGPoint(x: p.x + normal.x * jag, y: p.y + normal.y * jag))
                s += 1.6
            }
        }
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }
}

// MARK: - Paper grain

/// One small grayscale noise tile, blended with overlay so the paper keeps its
/// average colour: fine, low-contrast and perfectly even.
enum YohakuGrain {
    private static var cache: [Bool: UIImage] = [:]
    private static var pngCache: [Bool: String] = [:]
    static func image(dark: Bool) -> UIImage {
        if let cached = cache[dark] { return cached }
        let side = 96
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        var random = SeededRandom(seed: 2026)
        let alpha: CGFloat = dark ? 0.16 : 0.20
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            for y in 0..<side {
                for x in 0..<side {
                    let v = 0.5 + (random.unit() - 0.5) * 0.9
                    UIColor(white: v, alpha: alpha).setFill()
                    context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        cache[dark] = image
        return image
    }
    /// The same tile as a PNG data URI for the web pages.
    static func dataURI(dark: Bool) -> String {
        if let cached = pngCache[dark] { return cached }
        let uri = "data:image/png;base64," + (image(dark: dark).pngData()?.base64EncodedString() ?? "")
        pngCache[dark] = uri
        return uri
    }
}

/// Flat paper with the grain on top. Taps pass through.
struct YohakuPaper: View {
    let style: ReaderStyle
    var color: Color? = nil
    var body: some View {
        ZStack {
            color ?? style.background
            Image(uiImage: YohakuGrain.image(dark: style.isDark))
                .resizable(resizingMode: .tile)
                .interpolation(.none)
                .scaleEffect(0.5, anchor: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .blendMode(.overlay)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Small pieces

/// Small letter-spaced capitals: RESULTS, SEARCH, JAPANESE READER.
struct YohakuLabel: View {
    let text: String
    let style: ReaderStyle
    var strong = false
    var size: CGFloat = 10
    var body: some View {
        Text(text)
            .font(YohakuFont.label(size))
            .tracking(size * 0.18)
            .foregroundStyle(strong ? style.navy : style.secondary)
    }
}

/// A hand-drawn brush rule in the line colour.
struct YohakuRule: View {
    let style: ReaderStyle
    var weight: CGFloat = 1.7
    var body: some View {
        BrushLine(width: weight).fill(style.navy).frame(height: 6).accessibilityHidden(true)
    }
}

// MARK: - Line drawings

/// The single-weight hand-drawn line art (book, pen, teacup, leaf sprig).
enum YohakuDrawing: String {
    case book, pen, teacup, sprig

    var viewBox: CGSize {
        switch self {
        case .book: return CGSize(width: 120, height: 80)
        case .pen: return CGSize(width: 145, height: 100)
        case .teacup: return CGSize(width: 100, height: 90)
        case .sprig: return CGSize(width: 160, height: 200)
        }
    }
    var paths: [String] {
        switch self {
        case .book:
            return ["M8 22C26 13.5 46 15.8 60 26.4C74 15.6 94 13.8 112 22.4L111.6 66C94 58.4 74 60.2 60 70.4C46 60 26 58.6 8.4 66.2Z",
                    "M60 26.4C60.4 41 59.6 56 60 70.4", "M18 33C30 28.6 42 30 50.6 34.6", "M18.4 43C30 38.8 41.6 40.4 50 44.6",
                    "M70 34.4C80 30.2 92 29.4 102 32.6", "M70.4 44.2C78 40.8 86 40.4 94 42"]
        case .pen:
            return ["M10 80C30 78.4 40 60 54 62C70 64.4 66 86.4 52 84.2C38 82 44.4 54 70 50.2C96 46.4 100.4 70 117 60.6",
                    "M117.6 58.6L133.4 18.4C135.8 12.2 142.2 14.6 140 20.6L124.4 60.4L116 66.4Z", "M128.4 31.4L136.2 34.2"]
        case .teacup:
            return ["M18 38.4C17.4 62 32 74.6 50.4 74.2C68 73.8 82.6 61.6 82 38.2C61 39.4 39 39 18 38.4Z",
                    "M82 44.2C96.4 41.6 98.4 61 80.2 60.4", "M8 80.2C30 86.4 70 86.2 92 79.6",
                    "M42 30C35.6 22 48.4 16.2 42.2 6.4", "M56.4 30.4C50 22.4 62.6 16.4 56 8"]
        case .sprig:
            return ["M80 196C77.6 150 86.4 100 76 20", "M79.2 150C60 140.4 44.4 142 34 128C52.4 123.6 70.4 132 79.2 150Z",
                    "M81 120C100 110 116.4 112 128 98.2C108 94 92 104.4 81 120Z", "M78.4 90C60.4 80.4 50 70 46.2 56C62.4 60 74.4 72 78.4 90Z",
                    "M79 60.4C94.4 50 102 40 104.4 26C90 32 82 44 79 60.4Z"]
        }
    }
}

/// Parses the absolute M / C / L / Z subset of SVG path data used by the drawings.
enum SVGPath {
    static func path(_ data: String) -> Path {
        var path = Path()
        var numbers: [CGFloat] = []
        var command: Character = "M"
        func flush() {
            switch command {
            case "M":
                var i = 0
                while i + 1 < numbers.count {
                    let p = CGPoint(x: numbers[i], y: numbers[i + 1])
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    i += 2
                }
            case "L":
                var i = 0
                while i + 1 < numbers.count { path.addLine(to: CGPoint(x: numbers[i], y: numbers[i + 1])); i += 2 }
            case "C":
                var i = 0
                while i + 5 < numbers.count {
                    path.addCurve(to: CGPoint(x: numbers[i + 4], y: numbers[i + 5]),
                                  control1: CGPoint(x: numbers[i], y: numbers[i + 1]),
                                  control2: CGPoint(x: numbers[i + 2], y: numbers[i + 3]))
                    i += 6
                }
            case "Z": path.closeSubpath()
            default: break
            }
            numbers.removeAll()
        }
        var token = ""
        func endToken() { if let value = Double(token) { numbers.append(CGFloat(value)) }; token = "" }
        for character in data {
            if "MLCZ".contains(character) {
                endToken(); flush(); command = character
                if character == "Z" { flush() }
            } else if character == " " || character == "," {
                endToken()
            } else if character == "-" && !token.isEmpty {
                endToken(); token = "-"
            } else {
                token.append(character)
            }
        }
        endToken(); flush()
        return path
    }

    /// SwiftUI path → SVG path data (for CSS masks).
    static func data(_ path: Path) -> String {
        var out = ""
        func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }
        path.forEach { element in
            switch element {
            case .move(let p): out += "M\(f(p.x)) \(f(p.y))"
            case .line(let p): out += "L\(f(p.x)) \(f(p.y))"
            case .quadCurve(let p, let c): out += "Q\(f(c.x)) \(f(c.y)) \(f(p.x)) \(f(p.y))"
            case .curve(let p, let c1, let c2): out += "C\(f(c1.x)) \(f(c1.y)) \(f(c2.x)) \(f(c2.y)) \(f(p.x)) \(f(p.y))"
            case .closeSubpath: out += "Z"
            }
        }
        return out
    }
}

struct YohakuLineArt: Shape {
    let drawing: YohakuDrawing
    func path(in rect: CGRect) -> Path {
        let box = drawing.viewBox
        let scale = min(rect.width / box.width, rect.height / box.height)
        let dx = rect.minX + (rect.width - box.width * scale) / 2
        let dy = rect.minY + (rect.height - box.height * scale) / 2
        var combined = Path()
        for data in drawing.paths {
            combined.addPath(SVGPath.path(data), transform: CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: dx, ty: dy))
        }
        return combined
    }
}

/// A line drawing on a flat sage disc inside a hand-drawn circle.
struct YohakuEmblem: View {
    let style: ReaderStyle
    var drawing: YohakuDrawing = .book
    var size: CGFloat = 118
    var disc = true
    var body: some View {
        ZStack {
            if disc {
                Circle().fill(style.sage).frame(width: size * 0.8, height: size * 0.8).offset(x: size * 0.04, y: size * 0.03)
            }
            BrushCircle(width: 1.7).fill(style.navy)
            YohakuLineArt(drawing: drawing)
                .stroke(style.isDark && disc ? Palette.color(0x1A1A18) : style.ink,
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .frame(width: size * (drawing == .sprig ? 0.42 : 0.5), height: size * 0.46)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Screen header

/// The Yohaku screen header: "JAPANESE READER  01 / 辞書" with a brush rule under
/// it, a big title on the left, and an emblem (line drawing in a hand-drawn circle)
/// on the right.
struct YohakuHeader<Trailing: View>: View {
    let style: ReaderStyle
    let index: String
    let title: String
    let latin: String
    var detail: String? = nil
    /// A large thin numeral under the title (書庫: the number of saved passages).
    var numeral: String? = nil
    var drawing: YohakuDrawing = .book
    var height: CGFloat = 118
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                YohakuLabel(text: "JAPANESE READER", style: style, strong: true, size: 10.5)
                Text("\(index) / \(title)")
                    .font(YohakuFont.label(10.5)).tracking(1.6)
                    .foregroundStyle(style.secondary)
                Spacer(minLength: 4)
                trailing()
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 16)
            YohakuRule(style: style).padding(.horizontal, 16)
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(YohakuFont.title(48))
                        .tracking(-1)
                        .foregroundStyle(style.navy)
                        .accessibilityAddTraits(.isHeader)
                    if let numeral {
                        Text(numeral).font(YohakuFont.numeral(40)).foregroundStyle(style.navy).padding(.top, -4)
                    }
                    Text(detail.map { "\(latin) · \($0)" } ?? latin)
                        .font(.custom(YohakuFont.latin, size: 12))
                        .foregroundStyle(style.secondary)
                }
                Spacer(minLength: 8)
                YohakuEmblem(style: style, drawing: drawing, size: min(height - 8, 118))
            }
            .padding(.horizontal, 16)
            .frame(height: height)
        }
    }
}

// MARK: - Tab bar and icons

enum YohakuIcons {
    enum Kind: Int { case read = 0, search, library, grammar }
    private static var cache: [String: UIImage] = [:]

    private static func strokes(_ kind: Kind) -> [[CGPoint]] {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        switch kind {
        case .read:   // 辞書: an open book
            return [[p(3, 6), p(12, 7.5), p(21, 6)], [p(3, 6), p(3, 18.5)], [p(21, 6), p(21, 18.5)],
                    [p(3, 18.5), p(12, 19.5), p(21, 18.5)], [p(12, 7.5), p(12, 19.5)]]
        case .search:
            return [Brush.circle(center: p(10.5, 10.5), radius: 6, seed: 4), [p(15, 15), p(20.5, 20.5)]]
        case .library:  // 書庫: books on a shelf
            return [[p(5.5, 4.5), p(5.5, 19.5)], [p(10.5, 4.5), p(10.5, 19.5)], [p(14.5, 5.5), p(18.5, 19.5)], [p(3, 19.8), p(21, 19.5)]]
        case .grammar:  // 文法: a circle and a line
            return [Brush.circle(center: p(12, 12), radius: 7.5, seed: 8), [p(8.5, 12.2), p(15.5, 11.8)]]
        }
    }

    /// Brush-drawn icons; the selected one carries a small brush tick above it.
    static func image(_ kind: Kind, selected: Bool) -> UIImage {
        let key = "\(kind.rawValue)-\(selected)"
        if let cached = cache[key] { return cached }
        let size = CGSize(width: 26, height: 34)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            UIColor.black.setFill()
            if selected {
                cg.addPath(Brush.ribbon(Brush.line(CGPoint(x: 8.5, y: 2.5), CGPoint(x: 17.5, y: 2.2), step: 1), width: 2.4, seed: 31, taper: 2.5).cgPath)
                cg.fillPath()
            }
            cg.translateBy(x: 1, y: 9)
            for (index, stroke) in strokes(kind).enumerated() {
                let points = stroke.count > 3 ? stroke : Brush.polyline(stroke, step: 0.8)
                cg.addPath(Brush.ribbon(points, width: 1.9, seed: UInt64(kind.rawValue * 10 + index + 1), wobble: 0.35, taper: 2).cgPath)
                cg.fillPath()
            }
        }.withRenderingMode(.alwaysTemplate)
        cache[key] = image
        return image
    }

    /// A wide brush rule for the top of the tab bar and the bottom of the title bar.
    static func barLine() -> UIImage {
        if let cached = cache["bar"] { return cached }
        let size = CGSize(width: 480, height: 3)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.cgContext.addPath(Brush.ribbon(Brush.line(CGPoint(x: 0, y: 1.5), CGPoint(x: 480, y: 1.5)), width: 1.6, seed: 404, wobble: 0.5, taper: 0.1).cgPath)
            context.cgContext.fillPath()
        }.withRenderingMode(.alwaysTemplate)
        cache["bar"] = image
        return image
    }
}

/// UIKit bar styling SwiftUI has no modifiers for: the brush rule on top of the tab
/// bar, Zen Kaku labels, line-colour titles.
enum YohakuChrome {
    @MainActor static func apply(_ style: ReaderStyle) {
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(style.background)
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(style.background)
        if style.isYohaku {
            let navy = UIColor(style.navy), muted = UIColor(style.secondary)
            tab.shadowColor = navy
            tab.shadowImage = YohakuIcons.barLine()
            for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
                item.normal.iconColor = muted
                item.normal.titleTextAttributes = [.font: YohakuFont.uiFont(YohakuFont.gothic, 10.5), .foregroundColor: muted, .kern: 0.8]
                item.selected.iconColor = navy
                item.selected.titleTextAttributes = [.font: YohakuFont.uiFont(YohakuFont.gothicBold, 10.5), .foregroundColor: navy, .kern: 0.8]
            }
            nav.shadowColor = navy
            nav.shadowImage = YohakuIcons.barLine()
            nav.titleTextAttributes = [.font: YohakuFont.uiFont(YohakuFont.gothicBold, 16), .foregroundColor: navy]
            nav.largeTitleTextAttributes = [.font: YohakuFont.uiFont(YohakuFont.gothicBold, 30), .foregroundColor: navy]
        } else if style.usesSystemSurfaces {
            tab.configureWithDefaultBackground()
            nav.configureWithDefaultBackground()
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { restyle(window, tab: tab, nav: nav) }
        }
    }
    @MainActor private static func restyle(_ view: UIView, tab: UITabBarAppearance, nav: UINavigationBarAppearance) {
        if let bar = view as? UITabBar {
            bar.standardAppearance = tab
            bar.scrollEdgeAppearance = tab
        } else if let bar = view as? UINavigationBar {
            bar.standardAppearance = nav
            bar.scrollEdgeAppearance = nav
            bar.compactAppearance = nav
        }
        for child in view.subviews { restyle(child, tab: tab, nav: nav) }
    }
}

// MARK: - Web pages

enum YohakuWeb {
    /// `@font-face` rules for a web page served through `scheme`://font/<file>.ttf.
    static func fontFaces(scheme: String) -> String {
        func face(_ family: String, _ file: String, _ weight: String) -> String {
            "@font-face{font-family:\"\(family)\";src:url(\"\(scheme)://font/\(file).ttf\") format(\"truetype\");font-weight:\(weight);font-display:swap}"
        }
        return face("YGothic", YohakuFont.gothic, "300 500") + face("YGothic", YohakuFont.gothicBold, "600 900")
            + face("YMincho", YohakuFont.mincho, "300 600") + face("YMincho", YohakuFont.minchoBold, "700 900")
            + face("YLatin", YohakuFont.latinLight, "100 400") + face("YLatin", YohakuFont.latin, "500 650")
            + face("YLatin", YohakuFont.latinBold, "651 900")
    }

    /// A bundled font file, if `name` is one of the theme's fonts (or Klee One).
    static func fontData(named name: String) -> Data? {
        let base = (name as NSString).deletingPathExtension
        guard base.hasPrefix("KleeOne") || YohakuFont.files.contains(base),
              let file = Bundle.main.url(forResource: base, withExtension: "ttf") else { return nil }
        return try? Data(contentsOf: file, options: .mappedIfSafe)
    }

    private static func svgURI(_ svg: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: " .-_/:=,()")
        return "url(\"data:image/svg+xml;charset=utf-8," + (svg.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "\")"
    }
    /// Brush strokes as CSS mask images: a rule (stretched to any width) and a ring.
    static let ruleMask: String = {
        let path = Brush.ribbon(Brush.line(CGPoint(x: 0.5, y: 4), CGPoint(x: 399.5, y: 4)), width: 1.7, seed: 1207)
        return svgURI("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 400 8' preserveAspectRatio='none'><path d='\(SVGPath.data(path))'/></svg>")
    }()
    static let ringMask: String = {
        let path = Brush.ribbon(Brush.circle(center: CGPoint(x: 50, y: 50), radius: 46, seed: 33), width: 2.6, seed: 34, taper: 9)
        return svgURI("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><path d='\(SVGPath.data(path))'/></svg>")
    }()
    static let boxMask: String = {
        let path = BrushBox(width: 1.8, seed: 71).path(in: CGRect(x: 0, y: 0, width: 160, height: 40))
        return svgURI("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 160 40' preserveAspectRatio='none'><path d='\(SVGPath.data(path))'/></svg>")
    }()
    static let penMask: String = {
        let paths = YohakuDrawing.pen.paths.map { "<path d='\($0)'/>" }.joined()
        return svgURI("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 145 100' fill='none' stroke='black' stroke-width='1.7' stroke-linecap='round' stroke-linejoin='round'>\(paths)</svg>")
    }()

    /// The palette as CSS variables.
    static func palette(_ style: ReaderStyle) -> String {
        let hex = Palette.hexString
        let paper = style.backgroundRGB ?? 0xECE3CC
        return ":root{--y-paper:\(hex(paper));--y-ink:\(hex(Palette.rgb(style.ink)));--y-line:\(hex(style.accentRGB));"
            + "--y-muted:\(hex(style.mutedRGB));--y-accent:\(hex(style.theme.highlightRGB ?? style.accentRGB));--y-sage:#B4C0AA;"
            + "--y-grain:url(\"\(YohakuGrain.dataURI(dark: style.isDark))\");--y-rule:\(ruleMask);--y-ring:\(ringMask);--y-box:\(boxMask);--y-pen:\(penMask)}"
    }

    /// Dictionary pages: paper with grain, Mincho headwords and examples, Zen Kaku
    /// definitions, Hanken sense numbers, muted labels and hand-drawn brush dividers.
    /// Written with a high specificity so it also wins over the per-dictionary overlays.
    static func dictionaryCSS(_ style: ReaderStyle) -> String {
        palette(style) + dictionaryRules
    }
    private static let dictionaryRules = #"""
:root{
 --e-bg:var(--y-paper);--e-fg:var(--y-ink);--e-muted:var(--y-muted);--e-link:var(--y-line);--e-strong:var(--y-line);
 --e-border:color-mix(in srgb,var(--y-line) 30%,transparent);--e-ex:var(--y-ink);--e-head:var(--y-ink);--e-num:var(--y-line);
 --e-sel:color-mix(in srgb,var(--y-accent) 26%,transparent);
 --e-serif:"YMincho","Hiragino Mincho ProN",serif;--e-sans:"YGothic","Hiragino Sans",sans-serif;--e-font:var(--e-sans);
 --y-latin:"YLatin","Helvetica Neue",sans-serif;--y-mincho:"YMincho","Hiragino Mincho ProN",serif;
}
html:root,html:root body{background:var(--y-paper) var(--y-grain) repeat!important;background-size:48px 48px!important;background-blend-mode:overlay!important}
html:root body{font-family:var(--e-sans)!important;line-height:1.75!important}
/* Hand-drawn dividers: brush strokes drawn as masks in the line colour. */
.y-rule,html:root:not(#y) body hr{position:relative;border:0!important;height:6px!important;margin:.8em 0!important;background:var(--y-line)!important;
 -webkit-mask:var(--y-rule) center/100% 100% no-repeat;mask:var(--y-rule) center/100% 100% no-repeat}
html:root:not(#y) body .dictionary-source{position:relative;font:700 10.5px/1.5 var(--y-latin)!important;letter-spacing:.18em!important;color:var(--y-muted)!important;
 border-bottom:0!important;padding-bottom:10px!important;margin-bottom:18px!important}
html:root:not(#y) body .dictionary-source::before{width:6px!important;height:6px!important;border-radius:50%!important;background:var(--y-accent)!important;transform:none!important}
html:root:not(#y) body .dictionary-source::after{content:"";position:absolute;left:0;right:0;bottom:-2px;height:6px;background:var(--y-line);
 -webkit-mask:var(--y-rule) center/100% 100% no-repeat;mask:var(--y-rule) center/100% 100% no-repeat}
/* Headwords: very large Mincho. */
html:root:not(#y):not(#w) body :is(.HeadG .headword,.hw_midashi,.item_midashi .midashi,.midashi_kana,.titlekana,.dc-headword,.headword_kana,.mjrhsjcd-entry .word,.kanji01,headword,.head>.かな,.headword>.reading){
 font-family:var(--y-mincho)!important;font-weight:800!important;font-size:calc(var(--e-size) * 1.6)!important;line-height:1.25!important;letter-spacing:0!important;color:var(--y-ink)!important}
/* Children of a headword keep its size instead of multiplying it. */
html:root:not(#y):not(#w) body :is(.HeadG .headword,.hw_midashi,.item_midashi .midashi,.midashi_kana,.titlekana,.dc-headword,.headword_kana,.mjrhsjcd-entry .word,.kanji01,headword,.head>.かな,.headword>.reading) *{font-size:1em!important}
html:root:not(#y):not(#w) body :is(.headword.表記,.m_hyoki,.hyouki_g,.headword_kanji,black_branckets,.headword:not(.表記)~.headword){
 font-family:var(--y-mincho)!important;font-weight:500!important;font-size:calc(var(--e-size) * 1.25)!important;color:var(--y-line)!important}
html:root:not(#y):not(#w) body .hyouki_g *{font-size:1em!important;font-family:var(--y-mincho)!important;color:var(--y-line)!important}
html:root:not(#y):not(#w) body :is(.midashi_pri3,.midashi_pri2,.midashi_pri1,.koumoku>.midashi,.HeadG,.item_midashi,div.head:has(>h),.dc-entry>.midashi,.mjrhsjcd-entry>.head,.tkbt-entry>.head,.dic_item>.head){
 position:relative;border-bottom:0!important;padding-bottom:.55em!important;margin-bottom:.8em!important}
html:root:not(#y):not(#w) body :is(.midashi_pri3,.midashi_pri2,.midashi_pri1,.koumoku>.midashi,.HeadG,.item_midashi,div.head:has(>h),.dc-entry>.midashi,.mjrhsjcd-entry>.head,.tkbt-entry>.head,.dic_item>.head)::after{
 content:"";position:absolute;left:0;right:0;bottom:0;height:6px;background:var(--y-line);-webkit-mask:var(--y-rule) center/100% 100% no-repeat;mask:var(--y-rule) center/100% 100% no-repeat}
html:root:not(#y) body .headword_eng{font-family:var(--y-latin)!important;font-style:normal!important;font-weight:600!important;color:var(--y-muted)!important}
/* Sense numbers: large thin Hanken numerals. */
html:root:not(#y):not(#w) body :is(.num,.wc,.dc-sense,.sense_no,.gogi>.num,.MeaningG .Num,.snum,.hukugi_num){
 font-family:var(--y-latin)!important;font-weight:300!important;font-size:calc(var(--e-size) * 1.3)!important;line-height:1!important;color:var(--y-line)!important;margin-right:.35em!important;vertical-align:-.1em}
html:root:not(#y):not(#w) body :is(.num,.wc,.dc-sense,.sense_no,.gogi>.num,.MeaningG .Num,.snum,.hukugi_num) *{font-size:1em!important}
/* Labels: muted, small; tags get a hand-drawn box. */
html:root:not(#y):not(#w) body :is(.slabel,.label,.naihou,.note_div,.shironuki,.daikubun,.gogikubun,.tkbt-label,.type,.kg_eiyaku,.shiyouiki,.senmon_g,.white-square,.hinshi,.bunya,.yoho,.gram){
 font-family:var(--e-sans)!important;color:var(--y-muted)!important;border-radius:0!important;background:transparent!important}
html:root:not(#y):not(#w) body :is(.tkbt-label,.white-square,.hinshi,.shiyouiki,.senmon_g,.mjrhsjcd-entry .type){position:relative;border:0!important;padding:0 .45em!important}
html:root:not(#y):not(#w) body :is(.tkbt-label,.white-square,.hinshi,.shiyouiki,.senmon_g,.mjrhsjcd-entry .type)::after{content:"";position:absolute;inset:0;background:var(--y-muted);
 -webkit-mask:var(--y-box) center/100% 100% no-repeat;mask:var(--y-box) center/100% 100% no-repeat}
html:root:not(#y):not(#w) body :is(.tyuuki_rogo,.kaiwa_rogo,.kakomi_4_title_rogo,.tyuuki_kanren_rogo){background:var(--y-sage)!important;color:#1A1A18!important;border-radius:0!important}
/* Definitions and examples. */
html:root:not(#y):not(#w) body :is(.eng,.mean_yakugo,.yakugo,.dfcn,.meaning,.def1){color:var(--y-ink)!important}
html:root:not(#y):not(#w) body :is(.用例,.scope_exam_jp,.reibun,span.mean_yorei,.exjp,.ex_boby,.example_jp,jae,li.example-ja){
 font-family:var(--y-mincho)!important;font-weight:500!important;color:var(--y-ink)!important}
html:root:not(#y):not(#w) body :is(.用例訳,.scope_exam_en,.yakubun_g,.reiyaku_box,.excn,.exen,.ex_trans,.example_en,ja_cn,li.example-en){color:var(--y-muted)!important}
html:root:not(#y):not(#w) body :is(.yoorei,.MeaningG>.example,div.mean_yorei,.dic_item div.example,.exam,.examples>li.example-ja){
 border-left:0!important;padding-left:0!important;margin-left:calc(var(--e-size) * 1.2)!important}
html:root:not(#y) body :is(.用例,.reibun,.exjp,jae) :is(b,strong,.bi){color:var(--y-accent)!important;font-weight:800!important;text-decoration:none!important}
html:root:not(#y):not(#w) body :is(.hukugou_g,.kouzougi,.SubItem,.ComplexG){position:relative;border-top:0!important;padding-top:.9em!important}
html:root:not(#y):not(#w) body :is(.hukugou_g,.kouzougi,.SubItem,.ComplexG)::before{content:"";position:absolute;left:0;right:0;top:0;height:6px;background:var(--y-line);
 -webkit-mask:var(--y-rule) center/100% 100% no-repeat;mask:var(--y-rule) center/100% 100% no-repeat}
html:root:not(#y):not(#w) body :is(.hukugou_seiku,.kouzouhyouki,.subheadword,.ComplexH){font-family:var(--y-mincho)!important;font-weight:800!important;color:var(--y-line)!important}
html:root:not(#y):not(#w) body :is(.hukugou_seiku,.kouzouhyouki,.subheadword,.ComplexH)::before{border-radius:50%!important;background:var(--y-sage)!important;transform:none!important;width:.5em!important;height:.5em!important}
html:root:not(#y):not(#w) body :is(fieldset.kakomi_4_box,.kaiwa,.box,.note,.chuui){border-radius:0!important;border-style:solid!important;border-color:color-mix(in srgb,var(--y-line) 30%,transparent)!important;background:transparent!important}
html:root body img{border-radius:0!important}
html:root body mark.jp-hit{border-radius:0!important;background:color-mix(in srgb,var(--y-sage) 70%,transparent)!important;box-shadow:none!important}
html:root body details.import-source{border-radius:0!important;border-color:var(--y-line)!important}
html:root body :is(con_table>accent){border-radius:0!important}
"""#

    /// Grammar lessons: a pen drawing and the level inside a hand-drawn circle, a
    /// large Mincho pattern, and each section (接續 / 例句 / 類義 …) as a two-column
    /// row with a numbered label on the left and brush dividers between rows.
    static func grammarCSS(_ style: ReaderStyle) -> String {
        palette(style) + grammarRules
    }
    private static let grammarRules = #"""
:root{
 --g-title:"YGothic","Hiragino Sans","PingFang TC",sans-serif;--g-zh:"YGothic","PingFang TC","Hiragino Sans",sans-serif;
 --g-jp:"YMincho","Hiragino Mincho ProN","Songti TC",serif;--y-latin:"YLatin","Helvetica Neue",sans-serif;
 --g-bg:var(--y-paper);--g-ink:var(--y-ink);--g-shade:transparent;--g-wobble:0;--g-wobble2:0;
 --g-muted:var(--y-muted);--g-faint:color-mix(in srgb,var(--y-muted) 80%,var(--y-paper));
 --muted:var(--y-muted);--faint:color-mix(in srgb,var(--y-muted) 80%,var(--y-paper));
}
/* Notes and translations stay readable at every text size: no tiny fixed sizes
   from the lesson files, and the secondary text classes only slightly smaller. */
section [style*="font-size"]:not(rt):not(ruby):not(.badge){font-size:inherit!important}
.zh{font-size:.95em;line-height:1.75}
.sn,.setsu .sn{font-size:.92em;color:var(--y-muted)}
.hsub{font-size:1em}
.box,.box p,.cmp .pt,.swap,li{font-size:1em}
html,body{background:var(--y-paper) var(--y-grain) repeat;background-size:48px 48px;background-blend-mode:overlay}
rt{color:var(--y-muted)}
::selection{background:color-mix(in srgb,var(--y-accent) 26%,transparent)}
a{color:var(--y-line)}
header.h{position:relative;margin:0 0 6px;padding:132px 0 16px}
header.h::before{content:"";position:absolute;left:0;top:10px;width:58%;height:104px;background:var(--y-line);
 -webkit-mask:var(--y-pen) left center/contain no-repeat;mask:var(--y-pen) left center/contain no-repeat}
header.h::after{content:"";position:absolute;left:0;right:0;bottom:0;top:auto;height:6px;background:var(--y-line);
 -webkit-mask:var(--y-rule) center/100% 100% no-repeat;mask:var(--y-rule) center/100% 100% no-repeat}
.badge{position:absolute;right:0;top:18px;width:66px;height:66px;padding:0;border-radius:0;display:flex;align-items:center;justify-content:center;
 background:transparent;color:var(--y-line);font:700 20px/1 var(--y-latin);letter-spacing:0;transform:none;box-shadow:none}
.badge::before{content:"";position:absolute;inset:0;background:var(--y-line);-webkit-mask:var(--y-ring) center/100% 100% no-repeat;mask:var(--y-ring) center/100% 100% no-repeat}
h1{font:800 2.2em/1.18 var(--g-jp);margin:0 0 .3em;letter-spacing:0;color:var(--y-ink)}
h1 rt{font-family:var(--g-zh)}
.hsub{color:var(--y-ink);font-size:.95em;font-weight:700;line-height:1.6}
.revision-note{background:var(--y-sage)!important;color:#1A1A18!important;border-radius:0!important;font-family:var(--g-zh)!important}
body{counter-reset:ysec}
section{position:relative;counter-increment:ysec;display:block;margin:0;padding:16px 0 14px}
section::after{content:"";position:absolute;left:0;right:0;bottom:-3px;height:6px;background:var(--y-line);
 -webkit-mask:var(--y-rule) center/100% 100% no-repeat;mask:var(--y-rule) center/100% 100% no-repeat}
/* Phone: the numbered label sits on one line above full-width content. */
section>h2,h2{display:block;margin:0 0 10px;padding:0;background:none;font:700 .85em/1.5 var(--g-zh);letter-spacing:.06em;color:var(--y-line)}
section>h2::before{content:counter(ysec,decimal-leading-zero);display:inline-block;margin-right:.7em;font:700 .78em/1.5 var(--y-latin);letter-spacing:.06em;color:var(--y-muted)}
h2 small{display:inline;margin:0 0 0 .7em;background:none;font:400 .82em/1.4 var(--g-zh);color:var(--y-muted);letter-spacing:0}
section>*:not(h2){min-width:0}
h2+*{margin-top:0}
/* Wide screens (iPad, landscape): the two-column table, label on the left. */
@media (min-width:620px){
 section{display:grid;grid-template-columns:8.5em minmax(0,1fr);column-gap:14px}
 section>h2,h2{grid-column:1;grid-row:1 / span 40;margin:0}
 section>h2::before{display:block;margin:0}
 h2 small{display:block;margin:3px 0 0}
 section>*:not(h2){grid-column:2}
}
.box,.cmp,.q,.ex,.setsu{background:transparent;border:0;border-radius:0;box-shadow:none;padding:0}
.box{margin-bottom:.6em}
.box:last-child{margin-bottom:0}
section:first-of-type .box::before{display:none}
.ety{background:transparent;border:0;border-radius:0;padding:8px 0 0;margin-top:10px;font-size:.95em;color:var(--y-ink)}
.setsu{font-family:var(--g-zh);font-size:.95em;line-height:1.9}
.setsu b{position:relative;display:inline-block;margin:2px 0;padding:1px 11px;font:800 1.05em/1.6 var(--g-jp);color:var(--y-line)}
.setsu b::after{content:"";position:absolute;inset:0;background:var(--y-line);-webkit-mask:var(--y-box) center/100% 100% no-repeat;mask:var(--y-box) center/100% 100% no-repeat}
.ex{margin:0 0 12px;padding:0}
.ex:last-child{margin-bottom:0}
.ex::after{display:none}
.reg{background:var(--y-sage);color:#1A1A18;border-radius:0;transform:none;font:700 .64em/1.9 var(--g-zh);padding:0 8px}
.jp{font-family:var(--g-jp);font-weight:500;font-size:1.06em;line-height:2.1}
.zh{color:var(--y-muted)}
.note-l{color:var(--y-accent)}
mark{background:none;color:var(--y-accent);font-weight:800;border-radius:0}
.cmp{margin-bottom:12px}
.cmp .vs{position:relative;border:0;border-radius:0;color:var(--y-line);background:transparent;font-family:var(--y-latin)}
.cmp .vs::after{content:"";position:absolute;inset:0;background:var(--y-line);-webkit-mask:var(--y-box) center/100% 100% no-repeat;mask:var(--y-box) center/100% 100% no-repeat}
.cmp h3{font:800 1.05em/1.5 var(--g-jp);color:var(--y-line)}
.cmp .pt b,.swap b{color:var(--y-line)}
.swap{background:transparent;border:0;border-radius:0;padding:4px 0 0}
.chip{position:relative;border:0;border-radius:0;box-shadow:none;background:transparent;font-family:var(--g-jp)}
.chip::after{content:"";position:absolute;inset:0;background:var(--y-line);-webkit-mask:var(--y-box) center/100% 100% no-repeat;mask:var(--y-box) center/100% 100% no-repeat}
li::marker{color:var(--y-accent)}
.q{margin-bottom:12px}
details{position:relative;background:transparent;border:0;border-radius:0}
details::after{content:"";position:absolute;inset:0;pointer-events:none;background:var(--y-line);-webkit-mask:var(--y-box) center/100% 100% no-repeat;mask:var(--y-box) center/100% 100% no-repeat}
details[open]{background:transparent}
summary{font-family:var(--g-zh);color:var(--y-line)}
summary::before{content:"→ "}
td,th{border-color:color-mix(in srgb,var(--y-line) 25%,transparent)}
footer{position:relative;border-top:0;padding-top:16px;font:700 10px/1.6 var(--y-latin);letter-spacing:.16em;color:var(--y-muted)}
footer::before{content:"";position:absolute;left:0;right:0;top:0;height:6px;background:var(--y-line);-webkit-mask:var(--y-rule) center/100% 100% no-repeat;mask:var(--y-rule) center/100% 100% no-repeat}
"""#
}

// MARK: - SwiftUI helpers

/// The search field: a surface pill normally; in Yohaku a 2.5 brush underline.
struct SearchFieldChrome: ViewModifier {
    let style: ReaderStyle
    func body(content: Content) -> some View {
        if style.isYohaku {
            content.overlay(alignment: .bottom) {
                BrushLine(width: 2.5).fill(style.navy).frame(height: 7).offset(y: 3).allowsHitTesting(false)
            }
        } else {
            content
                .background(style.surface, in: SketchShape(radius: 16))
                .overlay(SketchShape(radius: 16).stroke(style.lineStrong, lineWidth: 1.5))
                .background(SketchShape(radius: 16).fill(style.shade).offset(x: 3, y: 4))
        }
    }
}

/// Lists in Yohaku: no rounded groups; row separators are hidden and each row draws
/// a brush rule instead (see `yohakuRow`).
struct YohakuList: ViewModifier {
    let style: ReaderStyle
    func body(content: Content) -> some View {
        if style.isYohaku {
            content.listStyle(.plain).listRowSeparatorTint(style.navy.opacity(0.55))
        } else {
            content
        }
    }
}

struct YohakuRowRule: ViewModifier {
    let style: ReaderStyle
    func body(content: Content) -> some View {
        if style.isYohaku {
            content.overlay(alignment: .bottom) {
                BrushLine(width: 1.4).fill(style.navy.opacity(0.85)).frame(height: 5).offset(y: 2).allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}
