import SwiftUI
import UIKit

// 糸 Fable — the Claude style, and a small family of variations on it.
//
// Every Fable theme shares one way of drawing, built on 余白 Yohaku's flat layouts:
// pen-textbook titles (Klee One), small handwritten lowercase notes (Gaegu), fine
// pencil rules, a soft wash for chosen things instead of black blocks, and one
// small warm spark. What changes from theme to theme is the *motif*: the drawing
// in each header, the decoration on the page, and the colours.
//
//   film       the film "fable · drawn from the inside": a wound ring, a figure, a
//              thread through the header, ripples (five papers, light to night)
//   graph      a graph-paper notebook with the cool S and coloured-pencil doodles
//   sundown    a linocut sun with ochre rays over a horizon
//   midnight   a small moon keeping a lit window company (borrowed light)
//   mist       watercolour rain, a utility pole, washing on the wire (underlight)
//   ballpoint  a blue-biro crosshatched self-portrait with red-pen marks
//   echo       a dot calls out; rings and small coloured worlds answer
//   roots      white roots branching on slate, crossed by one red line
//
// Page decorations stay at the edges and are kept faint, so nothing runs through
// the passage being read.

enum FableMotif: String, Hashable {
    case film, graph, sundown, midnight, mist, ballpoint, echo, roots
    // 自画像 Self-portraits (FablePortraits.swift), and the dusk sky.
    case sashiko, ebru, cyanotype, transit, phool, doublure, oneline, evening

    /// Themes whose emblem is a square tile rather than a loose drawing.
    var isPortrait: Bool {
        switch self {
        case .sashiko, .ebru, .cyanotype, .transit, .phool, .doublure, .oneline, .evening: return true
        default: return false
        }
    }
}

// MARK: - Strokes

enum FableStroke {
    /// A gently wobbling arc (radians, 0 = 3 o'clock, clockwise on screen).
    static func arc(center: CGPoint, radius: CGFloat, from start: CGFloat, to end: CGFloat, seed: UInt64, wobble: CGFloat = 0.02) -> [CGPoint] {
        let noise = BrushNoise(seed: seed)
        let count = max(16, Int(abs(end - start) * radius / 1.5))
        return (0...count).map { i in
            let t = CGFloat(i) / CGFloat(count)
            let a = start + (end - start) * t
            let r = radius * (1 + noise.at(t * 9) * wobble)
            return CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
        }
    }

    /// A pencil line through the given corners: slightly uneven, lightly tapered.
    static func pencil(_ corners: [CGPoint], width: CGFloat, seed: UInt64) -> Path {
        Brush.ribbon(Brush.polyline(corners, step: 1), width: width, seed: seed, wobble: 0.3, taper: 2.5)
    }

    /// Points along a quadratic curve.
    static func quad(_ a: CGPoint, _ control: CGPoint, _ b: CGPoint, steps: Int = 24) -> [CGPoint] {
        var points: [CGPoint] = []
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let u = 1 - t
            let wa: CGFloat = u * u, wc: CGFloat = 2 * u * t, wb: CGFloat = t * t
            let x: CGFloat = wa * a.x + wc * control.x + wb * b.x
            let y: CGFloat = wa * a.y + wc * control.y + wb * b.y
            points.append(CGPoint(x: x, y: y))
        }
        return points
    }

    static func star(center c: CGPoint, radius r: CGFloat, points: Int = 5) -> [CGPoint] {
        var out: [CGPoint] = []
        for i in 0...(points * 2) {
            let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / CGFloat(points)
            let rr = i % 2 == 0 ? r : r * 0.45
            out.append(CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr))
        }
        return out
    }
}

// MARK: - The film's pieces

/// The film's thick hand-wound ring: a dark cord with fine cross-ticks, a soft
/// shadow just below it, and an opening near the top ("still unfinished").
struct FableCordRing: View {
    let style: ReaderStyle
    var weight: CGFloat = 4
    var seed: UInt64 = 2026
    var body: some View {
        Canvas { context, size in
            let r = min(size.width, size.height) / 2 - weight - 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let start = -CGFloat.pi / 2 + 0.42, end = start + CGFloat.pi * 2 - 0.86
            let points = FableStroke.arc(center: c, radius: r, from: start, to: end, seed: seed)
            let cord = Brush.ribbon(points, width: weight, seed: seed &+ 5, wobble: 0.45, taper: weight * 3.2)
            context.fill(cord.offsetBy(dx: 1.1, dy: 1.6), with: .color(style.ink.opacity(style.isDark ? 0.22 : 0.15)))
            context.fill(cord, with: .color(style.ink.opacity(0.9)))
            var ticks = Path()
            var random = SeededRandom(seed: seed &+ 9)
            var index = 0
            while index < points.count - 2 {
                let p = points[index], q = points[index + 1]
                let dx = q.x - p.x, dy = q.y - p.y, d = max(hypot(dx, dy), 0.001)
                let nx = -dy / d, ny = dx / d, h = weight * 0.42
                let lean = (random.unit() - 0.5) * 0.6
                ticks.move(to: CGPoint(x: p.x + nx * h + dx / d * lean, y: p.y + ny * h + dy / d * lean))
                ticks.addLine(to: CGPoint(x: p.x - nx * h - dx / d * lean, y: p.y - ny * h - dy / d * lean))
                index += 2
            }
            context.stroke(ticks, with: .color(style.background.opacity(0.42)), lineWidth: 0.55)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The small spark: eight fine rays.
struct FableSpark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4 + 0.2
            let long = i % 2 == 0 ? r : r * 0.62
            path.move(to: CGPoint(x: c.x + cos(a) * r * 0.22, y: c.y + sin(a) * r * 0.22))
            path.addLine(to: CGPoint(x: c.x + cos(a) * long, y: c.y + sin(a) * long))
        }
        return path
    }
}

/// Faint concentric ripples ("two of us, one water").
struct FableRipples: Shape {
    var count = 5
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        for i in 0..<count {
            let r = outer * (0.42 + 0.58 * CGFloat(i + 1) / CGFloat(count))
            path.addLines(FableStroke.arc(center: c, radius: r, from: 0, to: .pi * 2, seed: UInt64(41 + i), wobble: 0.008))
        }
        return path
    }
}

/// The thread, only inside the header: a slow S that fades out above and below.
struct FableHeaderThread: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for i in 0...60 {
            let t = CGFloat(i) / 60
            let p = CGPoint(x: rect.midX + sin(t * .pi * 1.3 + 0.5) * rect.width * 0.32, y: rect.minY + rect.height * t)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}

/// Small single-line drawings for the film emblems, one per tab.
enum FableDrawing: Int {
    case figure, helix, constellation, spiral

    init(_ yohaku: YohakuDrawing) {
        switch yohaku {
        case .sprig: self = .figure
        case .pen: self = .helix
        case .teacup: self = .constellation
        case .book: self = .spiral
        }
    }

    /// Lines in a unit square (0...1).
    var path: Path {
        var path = Path()
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        switch self {
        case .figure:
            path.addEllipse(in: CGRect(x: 0.37, y: 0.12, width: 0.26, height: 0.28))
            path.move(to: p(0.44, 0.39))
            path.addCurve(to: p(0.12, 0.98), control1: p(0.44, 0.52), control2: p(0.16, 0.56))
            path.move(to: p(0.56, 0.39))
            path.addCurve(to: p(0.88, 0.98), control1: p(0.56, 0.52), control2: p(0.84, 0.56))
        case .helix:
            for phase in [CGFloat(0), .pi] {
                for i in 0...48 {
                    let t = CGFloat(i) / 48
                    let q = p(0.5 + sin(t * .pi * 4 + phase) * 0.22, 0.04 + t * 0.92)
                    if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
                }
            }
        case .constellation:
            let stars = [p(0.08, 0.62), p(0.3, 0.38), p(0.52, 0.5), p(0.74, 0.22), p(0.92, 0.4), p(0.62, 0.84)]
            path.move(to: stars[0])
            for star in stars.dropFirst().prefix(4) { path.addLine(to: star) }
            path.move(to: stars[2]); path.addLine(to: stars[5])
            for star in stars { path.addEllipse(in: CGRect(x: star.x - 0.025, y: star.y - 0.025, width: 0.05, height: 0.05)) }
        case .spiral:
            for i in 0...120 {
                let t = CGFloat(i) / 120
                let a = t * .pi * 6.2
                let q = p(0.5 + cos(a) * t * 0.46, 0.5 + sin(a) * t * 0.46)
                if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
        }
        return path
    }
}

struct FableLineArt: Shape {
    let drawing: FableDrawing
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        return drawing.path.applying(CGAffineTransform(a: side, b: 0, c: 0, d: side,
                                                       tx: rect.midX - side / 2, ty: rect.midY - side / 2))
    }
}

// MARK: - Emblems

/// The header emblem of the active Fable theme. `decorated` adds what only fits in a
/// header (ripples, the film's thread); small uses (swatches, logos) leave it off.
struct FableEmblem: View {
    let style: ReaderStyle
    var drawing: YohakuDrawing = .sprig
    var size: CGFloat = 118
    var decorated = true
    var body: some View {
        let art = FableDrawing(drawing)
        Group {
            if style.theme.motif == .film {
                film(art)
            } else {
                Canvas { context, canvas in
                    FableArt.emblem(&context, canvas, style: style, art: art)
                }
                .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func film(_ art: FableDrawing) -> some View {
        ZStack {
            if decorated {
                FableRipples(count: 4)
                    .stroke(style.secondary.opacity(style.isDark ? 0.24 : 0.16), lineWidth: 0.55)
                    .frame(width: size * 1.2, height: size * 1.2)
                FableHeaderThread()
                    .stroke(style.thread.opacity(style.isDark ? 0.8 : 0.7), style: StrokeStyle(lineWidth: 0.85, lineCap: .round))
                    .frame(width: size * 0.45, height: size * 1.45)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.3),
                                                 .init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .offset(x: size * 0.04)
            }
            FableCordRing(style: style, weight: max(2.2, size * 0.034))
                .frame(width: size * 0.86, height: size * 0.86)
            FableLineArt(drawing: art)
                .stroke(style.ink.opacity(0.78), style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.42, height: size * 0.42)
                .offset(y: art == .figure ? size * 0.12 : 0)
            FableSpark()
                .stroke(style.spark, style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                .frame(width: size * 0.13, height: size * 0.13)
                .offset(x: art == .figure ? 0 : size * 0.2, y: art == .figure ? -size * 0.27 : -size * 0.2)
        }
    }
}

/// Coloured pencils for the notebook doodles.
enum FablePencil {
    static let blue = Palette.color(0x4F79B8)
    static let green = Palette.color(0x5E8F4E)
    static let ochre = Palette.color(0xD9A441)
    static let plum = Palette.color(0x7B4FA0)
    static let cobalt = Palette.color(0x2F5BB7)
}

/// Every non-film emblem and page decoration, drawn into a Canvas.
enum FableArt {
    // MARK: Emblems

    static func emblem(_ ctx: inout GraphicsContext, _ canvas: CGSize, style: ReaderStyle, art: FableDrawing) {
        let u = min(canvas.width, canvas.height)
        let origin = CGPoint(x: (canvas.width - u) / 2, y: (canvas.height - u) / 2)
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * u, y: origin.y + y * u) }
        let seed = UInt64(art.rawValue * 97 + 13)
        let line = max(0.9, u * 0.011)
        switch style.theme.motif {
        case .film: break
        case .graph: graph(&ctx, P, u: u, line: line, style: style, art: art, seed: seed)
        case .sundown: sundown(&ctx, P, u: u, line: line, style: style, seed: seed)
        case .midnight: midnight(&ctx, P, u: u, line: line, style: style, seed: seed)
        case .mist: mist(&ctx, P, u: u, line: line, style: style, seed: seed)
        case .ballpoint: ballpoint(&ctx, P, u: u, line: line, style: style, seed: seed)
        case .echo: echo(&ctx, P, u: u, line: line, style: style, art: art, seed: seed)
        case .roots: roots(&ctx, P, u: u, line: line, style: style, seed: seed)
        default: portrait(&ctx, P, u: u, line: line, style: style, seed: seed)
        }
    }

    /// 方眼: a square of graph paper, the cool S in graphite with a highlighter
    /// swipe behind it, and a few coloured-pencil doodles (different on each tab).
    private static func graph(_ ctx: inout GraphicsContext, _ P: (CGFloat, CGFloat) -> CGPoint, u: CGFloat, line: CGFloat,
                              style: ReaderStyle, art: FableDrawing, seed: UInt64) {
        var grid = Path()
        for i in 0...10 {
            let t = 0.05 + CGFloat(i) * 0.09
            grid.move(to: P(t, 0.05)); grid.addLine(to: P(t, 0.95))
            grid.move(to: P(0.05, t)); grid.addLine(to: P(0.95, t))
        }
        ctx.stroke(grid, with: .color(style.thread.opacity(0.4)), lineWidth: 0.4)
        ctx.fill(FableStroke.pencil([P(0.05, 0.05), P(0.95, 0.05), P(0.95, 0.95), P(0.05, 0.95), P(0.05, 0.05)], width: line * 0.8, seed: seed),
                 with: .color(style.ink.opacity(0.35)))
        // Highlighter swipe behind the middle of the S.
        var swipe = Path()
        swipe.addLines([P(0.27, 0.42), P(0.74, 0.39), P(0.75, 0.58), P(0.26, 0.61)])
        swipe.closeSubpath()
        ctx.fill(swipe, with: .color(style.sage.opacity(0.9)))
        let xl: CGFloat = 0.33, xm: CGFloat = 0.5, xr: CGFloat = 0.67
        let strokes: [[CGPoint]] = [
            [P(xl, 0.25), P(0.5, 0.12), P(xr, 0.25)],
            [P(xl, 0.25), P(xl, 0.41)], [P(xm, 0.25), P(xm, 0.41)], [P(xr, 0.25), P(xr, 0.41)],
            [P(xl, 0.59), P(xl, 0.75)], [P(xm, 0.59), P(xm, 0.75)], [P(xr, 0.59), P(xr, 0.75)],
            [P(xl, 0.75), P(0.5, 0.88), P(xr, 0.75)],
            [P(xl, 0.41), P(xm, 0.59)], [P(xm, 0.41), P(xr, 0.59)],
            [P(xr, 0.41), P((xm + xr) / 2, 0.5)], [P(xl, 0.59), P((xl + xm) / 2, 0.5)]
        ]
        for (i, s) in strokes.enumerated() {
            ctx.fill(FableStroke.pencil(s, width: line * 1.1, seed: seed &+ UInt64(i)), with: .color(style.ink.opacity(0.88)))
        }
        // Doodles: which ones and where depends on the tab.
        let spots: [(CGFloat, CGFloat)] = [(0.84, 0.17), (0.15, 0.24), (0.17, 0.8), (0.83, 0.8)]
        let shift = art.rawValue
        for k in 0..<3 {
            let (x, y) = spots[(k + shift) % 4]
            doodle((k + shift) % 4, &ctx, P(x, y), r: u * 0.075, line: line, style: style, seed: seed &+ UInt64(k * 7))
        }
    }

    /// One coloured-pencil doodle: a star, a cloud, a flower or a paper plane.
    static func doodle(_ kind: Int, _ ctx: inout GraphicsContext, _ c: CGPoint, r: CGFloat, line: CGFloat, style: ReaderStyle, seed: UInt64) {
        switch kind {
        case 0:
            ctx.fill(FableStroke.pencil(FableStroke.star(center: c, radius: r), width: line * 0.8, seed: seed), with: .color(style.spark))
        case 1:
            var cloud = Path()
            cloud.addArc(center: CGPoint(x: c.x - r * 0.55, y: c.y + r * 0.1), radius: r * 0.45, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
            cloud.addArc(center: CGPoint(x: c.x, y: c.y - r * 0.2), radius: r * 0.55, startAngle: .degrees(190), endAngle: .degrees(350), clockwise: false)
            cloud.addArc(center: CGPoint(x: c.x + r * 0.6, y: c.y + r * 0.1), radius: r * 0.42, startAngle: .degrees(270), endAngle: .degrees(90), clockwise: false)
            cloud.addLine(to: CGPoint(x: c.x - r * 0.55, y: c.y + r * 0.55))
            ctx.stroke(cloud, with: .color(FablePencil.blue), style: StrokeStyle(lineWidth: line * 0.8, lineCap: .round, lineJoin: .round))
        case 2:
            var flower = Path()
            for i in 0..<5 {
                let a = CGFloat(i) * .pi * 2 / 5
                flower.addEllipse(in: CGRect(x: c.x + cos(a) * r * 0.42 - r * 0.28, y: c.y + sin(a) * r * 0.42 - r * 0.28, width: r * 0.56, height: r * 0.56))
            }
            ctx.stroke(flower, with: .color(FablePencil.green), lineWidth: line * 0.7)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.14, y: c.y - r * 0.14, width: r * 0.28, height: r * 0.28)), with: .color(FablePencil.ochre))
        default:
            let plane = [CGPoint(x: c.x - r, y: c.y + r * 0.2), CGPoint(x: c.x + r, y: c.y - r * 0.5),
                         CGPoint(x: c.x - r * 0.1, y: c.y + r * 0.7), CGPoint(x: c.x - r * 0.25, y: c.y + r * 0.15),
                         CGPoint(x: c.x - r, y: c.y + r * 0.2)]
            ctx.fill(FableStroke.pencil(plane, width: line * 0.75, seed: seed), with: .color(style.ink.opacity(0.7)))
        }
    }

    /// 残照: a linocut sun half-set on the horizon, rays of fine lines and dots.
    private static func sundown(_ ctx: inout GraphicsContext, _ P: (CGFloat, CGFloat) -> CGPoint, u: CGFloat, line: CGFloat,
                                style: ReaderStyle, seed: UInt64) {
        let horizon: CGFloat = 0.7
        let c = P(0.5, horizon)
        let r = u * 0.24
        for i in 0..<13 {
            let a = CGFloat.pi + 0.12 + (CGFloat.pi - 0.24) * CGFloat(i) / 12
            if i % 2 == 0 {
                var rays = Path()
                for d in [-0.035, 0.0, 0.035] as [CGFloat] {
                    rays.move(to: CGPoint(x: c.x + cos(a + d) * r * 1.15, y: c.y + sin(a + d) * r * 1.15))
                    rays.addLine(to: CGPoint(x: c.x + cos(a + d) * u * 0.47, y: c.y + sin(a + d) * u * 0.47))
                }
                ctx.stroke(rays, with: .color(style.thread), style: StrokeStyle(lineWidth: line * 0.7, lineCap: .round))
            } else {
                var dots = Path()
                var d = r * 1.25
                while d < u * 0.46 {
                    dots.addEllipse(in: CGRect(x: c.x + cos(a) * d - line * 0.6, y: c.y + sin(a) * d - line * 0.6, width: line * 1.2, height: line * 1.2))
                    d += u * 0.035
                }
                ctx.fill(dots, with: .color(style.ink.opacity(0.55)))
            }
        }
        // The sun: striped like a linocut, clipped above the horizon.
        var sun = Path()
        sun.addArc(center: c, radius: r, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        sun.closeSubpath()
        ctx.drawLayer { layer in
            layer.clip(to: sun)
            layer.fill(sun, with: .color(style.spark.opacity(0.22)))
            var stripes = Path()
            var y = c.y - r
            while y < c.y {
                stripes.move(to: CGPoint(x: c.x - r, y: y)); stripes.addLine(to: CGPoint(x: c.x + r, y: y))
                y += u * 0.026
            }
            layer.stroke(stripes, with: .color(style.spark), lineWidth: line * 0.75)
        }
        ctx.fill(Brush.ribbon(FableStroke.arc(center: c, radius: r, from: .pi, to: .pi * 2, seed: seed), width: line * 1.2, seed: seed &+ 3, wobble: 0.3, taper: 3),
                 with: .color(style.spark))
        ctx.fill(FableStroke.pencil([P(0.06, horizon), P(0.94, horizon)], width: line * 1.1, seed: seed &+ 5), with: .color(style.ink.opacity(0.85)))
        for (i, y) in ([0.78, 0.85, 0.91] as [CGFloat]).enumerated() {
            let inset = 0.16 + CGFloat(i) * 0.08
            var wave: [CGPoint] = []
            for k in 0...20 {
                let t = CGFloat(k) / 20
                wave.append(P(inset + (1 - 2 * inset) * t, y + sin(t * .pi * 6) * 0.008))
            }
            ctx.stroke(Path { $0.addLines(wave) }, with: .color(style.secondary.opacity(0.7)), lineWidth: line * 0.6)
        }
    }

    /// 月: a small moon, a dotted path of borrowed light, and a lit window.
    private static func midnight(_ ctx: inout GraphicsContext, _ P: (CGFloat, CGFloat) -> CGPoint, u: CGFloat, line: CGFloat,
                                 style: ReaderStyle, seed: UInt64) {
        var random = SeededRandom(seed: seed &+ 40)
        var stars = Path()
        for _ in 0..<9 {
            let c = P(0.06 + random.unit() * 0.88, 0.04 + random.unit() * 0.4)
            let r = u * (0.008 + random.unit() * 0.012)
            stars.move(to: CGPoint(x: c.x - r, y: c.y)); stars.addLine(to: CGPoint(x: c.x + r, y: c.y))
            stars.move(to: CGPoint(x: c.x, y: c.y - r)); stars.addLine(to: CGPoint(x: c.x, y: c.y + r))
        }
        ctx.stroke(stars, with: .color(style.secondary.opacity(0.7)), lineWidth: 0.5)
        let moon = P(0.7, 0.27)
        ctx.fill(Path(ellipseIn: CGRect(x: moon.x - u * 0.26, y: moon.y - u * 0.26, width: u * 0.52, height: u * 0.52)),
                 with: .radialGradient(Gradient(colors: [style.thread.opacity(0.28), style.thread.opacity(0)]),
                                       center: moon, startRadius: 0, endRadius: u * 0.26))
        ctx.fill(Path(ellipseIn: CGRect(x: moon.x - u * 0.1, y: moon.y - u * 0.1, width: u * 0.2, height: u * 0.2)), with: .color(style.thread))
        // Borrowed light: a dotted curve from the moon down to the window.
        var dots = Path()
        for p in FableStroke.quad(P(0.6, 0.36), P(0.56, 0.62), P(0.38, 0.68), steps: 14).dropFirst().dropLast() {
            dots.addEllipse(in: CGRect(x: p.x - line * 0.55, y: p.y - line * 0.55, width: line * 1.1, height: line * 1.1))
        }
        ctx.fill(dots, with: .color(style.thread.opacity(0.75)))
        // The house and its lit window.
        let window = CGRect(x: P(0.22, 0.7).x, y: P(0.22, 0.7).y, width: u * 0.12, height: u * 0.11)
        ctx.fill(Path(ellipseIn: window.insetBy(dx: -u * 0.12, dy: -u * 0.12)),
                 with: .radialGradient(Gradient(colors: [style.spark.opacity(0.35), style.spark.opacity(0)]),
                                       center: CGPoint(x: window.midX, y: window.midY), startRadius: 0, endRadius: u * 0.18))
        ctx.fill(Path(window), with: .color(style.spark))
        var mullion = Path()
        mullion.move(to: CGPoint(x: window.midX, y: window.minY)); mullion.addLine(to: CGPoint(x: window.midX, y: window.maxY))
        mullion.move(to: CGPoint(x: window.minX, y: window.midY)); mullion.addLine(to: CGPoint(x: window.maxX, y: window.midY))
        ctx.stroke(mullion, with: .color(style.background), lineWidth: line * 0.7)
        let house = [P(0.1, 0.62), P(0.28, 0.48), P(0.46, 0.62), P(0.46, 0.92), P(0.1, 0.92), P(0.1, 0.62), P(0.46, 0.62)]
        ctx.fill(FableStroke.pencil(house, width: line, seed: seed), with: .color(style.ink.opacity(0.85)))
        ctx.fill(FableStroke.pencil([P(0.04, 0.92), P(0.96, 0.92)], width: line * 0.8, seed: seed &+ 2), with: .color(style.ink.opacity(0.5)))
    }

    /// 雨: a watercolour wash, rain, a utility pole and washing on the wire.
    private static func mist(_ ctx: inout GraphicsContext, _ P: (CGFloat, CGFloat) -> CGPoint, u: CGFloat, line: CGFloat,
                             style: ReaderStyle, seed: UInt64) {
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: u * 0.05))
            layer.fill(Path(ellipseIn: CGRect(x: P(0.06, 0.06).x, y: P(0.06, 0.06).y, width: u * 0.74, height: u * 0.5)), with: .color(style.thread.opacity(0.32)))
            layer.fill(Path(ellipseIn: CGRect(x: P(0.34, 0.24).x, y: P(0.34, 0.24).y, width: u * 0.56, height: u * 0.5)), with: .color(style.thread.opacity(0.2)))
        }
        var random = SeededRandom(seed: seed &+ 3)
        var rain = Path()
        for _ in 0..<18 {
            let p = P(0.05 + random.unit() * 0.9, 0.05 + random.unit() * 0.8)
            rain.move(to: p); rain.addLine(to: CGPoint(x: p.x - u * 0.025, y: p.y + u * 0.1))
        }
        ctx.stroke(rain, with: .color(style.secondary.opacity(0.4)), lineWidth: 0.5)
        let wire1 = FableStroke.quad(P(0.56, 0.27), P(0.3, 0.44), P(0.0, 0.35))
        let wire2 = FableStroke.quad(P(0.58, 0.34), P(0.3, 0.54), P(0.0, 0.46))
        let wire3 = FableStroke.quad(P(0.76, 0.27), P(0.88, 0.34), P(1.0, 0.31))
        for wire in [wire1, wire2, wire3] {
            ctx.stroke(Path { $0.addLines(wire) }, with: .color(style.ink.opacity(0.7)), lineWidth: line * 0.55)
        }
        let colours: [Color] = [style.spark, FablePencil.ochre, style.thread]
        for (k, t) in [8, 12, 16].enumerated() {
            let p = wire1[t]
            let cloth = CGRect(x: p.x - u * 0.03, y: p.y, width: u * 0.06, height: u * 0.09 + CGFloat(k) * u * 0.01)
            ctx.fill(Path(cloth), with: .color(colours[k].opacity(0.85)))
        }
        ctx.fill(FableStroke.pencil([P(0.66, 0.14), P(0.665, 0.97)], width: line * 1.6, seed: seed), with: .color(style.ink.opacity(0.9)))
        ctx.fill(FableStroke.pencil([P(0.55, 0.27), P(0.77, 0.265)], width: line, seed: seed &+ 1), with: .color(style.ink.opacity(0.9)))
        ctx.fill(FableStroke.pencil([P(0.57, 0.34), P(0.75, 0.335)], width: line, seed: seed &+ 2), with: .color(style.ink.opacity(0.9)))
    }

    /// The figure's outline (head and shoulders) in unit coordinates.
    static func figure(_ P: (CGFloat, CGFloat) -> CGPoint, u: CGFloat) -> Path {
        var path = Path()
        let head = P(0.5, 0.33)
        path.addEllipse(in: CGRect(x: head.x - u * 0.135, y: head.y - u * 0.15, width: u * 0.27, height: u * 0.3))
        path.move(to: P(0.12, 0.95))
        path.addCurve(to: P(0.5, 0.55), control1: P(0.12, 0.68), control2: P(0.3, 0.55))
        path.addCurve(to: P(0.88, 0.95), control1: P(0.7, 0.55), control2: P(0.88, 0.68))
        path.closeSubpath()
        return path
    }

    /// ボールペン: a self-portrait in blue biro crosshatching, with red-pen curls.
    private static func ballpoint(_ ctx: inout GraphicsContext, _ P: (CGFloat, CGFloat) -> CGPoint, u: CGFloat, line: CGFloat,
                                  style: ReaderStyle, seed: UInt64) {
        let body = figure(P, u: u)
        ctx.drawLayer { layer in
            layer.clip(to: body)
            var random = SeededRandom(seed: seed)
            var hatch = Path()
            var k: CGFloat = -1
            while k < 2 {
                let j = (random.unit() - 0.5) * 0.01
                hatch.move(to: P(k + j, 0)); hatch.addLine(to: P(k + 1 + j, 1))
                k += 0.022
            }
            layer.stroke(hatch, with: .color(style.ink.opacity(0.7)), lineWidth: 0.5)
            var cross = Path()
            k = -1
            while k < 2 {
                cross.move(to: P(k, 1)); cross.addLine(to: P(k + 1, 0))
                k += 0.036
            }
            layer.stroke(cross, with: .color(style.ink.opacity(0.4)), lineWidth: 0.45)
        }
        ctx.stroke(body, with: .color(style.ink.opacity(0.85)), lineWidth: 0.8)
        ctx.stroke(body.offsetBy(dx: 0.7, dy: -0.5), with: .color(style.ink.opacity(0.3)), lineWidth: 0.5)
        var curls = Path()
        for (cx, cy) in [(0.12, 0.2), (0.86, 0.3), (0.82, 0.12), (0.18, 0.5)] as [(CGFloat, CGFloat)] {
            for i in 0...30 {
                let t = CGFloat(i) / 30
                let p = P(cx - 0.05 + t * 0.1 + cos(t * 18) * 0.015, cy + sin(t * 18) * 0.015)
                if i == 0 { curls.move(to: p) } else { curls.addLine(to: p) }
            }
        }
        ctx.stroke(curls, with: .color(style.spark.opacity(0.85)), lineWidth: 0.6)
    }

    /// 応: a halftone field, a small dot calling out, rings answering with worlds.
    private static func echo(_ ctx: inout GraphicsContext, _ P: (CGFloat, CGFloat) -> CGPoint, u: CGFloat, line: CGFloat,
                             style: ReaderStyle, art: FableDrawing, seed: UInt64) {
        let c = P(0.5, 0.5)
        var dots = Path()
        let step = u * 0.045
        var y = c.y - u * 0.48
        while y <= c.y + u * 0.48 {
            var x = c.x - u * 0.48
            while x <= c.x + u * 0.48 {
                let d = hypot(x - c.x, y - c.y) / (u * 0.48)
                if d < 1 {
                    let r = u * 0.011 * (1 - d) + 0.3
                    dots.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                }
                x += step
            }
            y += step
        }
        ctx.fill(dots, with: .color(style.thread.opacity(0.55)))
        for (i, r) in ([0.17, 0.29, 0.41] as [CGFloat]).enumerated() {
            ctx.stroke(Path { $0.addLines(FableStroke.arc(center: c, radius: u * r, from: 0, to: .pi * 2, seed: seed &+ UInt64(i), wobble: 0.01)) },
                       with: .color(style.ink.opacity(0.5)), lineWidth: 0.6)
        }
        let worlds: [Color] = [FablePencil.cobalt, FablePencil.green, style.spark, FablePencil.ochre, FablePencil.plum]
        let turn = CGFloat(art.rawValue) * 0.9
        let places: [(CGFloat, CGFloat)] = [(0.17, 0.6), (0.29, 2.4), (0.29, 4.4), (0.41, 1.2), (0.41, 3.7)]
        for (k, place) in places.enumerated() {
            let a = place.1 + turn
            let p = CGPoint(x: c.x + cos(a) * u * place.0, y: c.y + sin(a) * u * place.0)
            let rr = u * (k == 3 ? 0.04 : 0.03)
            let disc = Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr, width: rr * 2, height: rr * 2))
            ctx.fill(disc, with: .color(worlds[k]))
            ctx.stroke(disc, with: .color(style.ink.opacity(0.7)), lineWidth: 0.5)
        }
        let r = u * 0.045
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(style.spark))
        for rr in [0.075, 0.1] as [CGFloat] {
            ctx.stroke(Path { $0.addArc(center: c, radius: u * rr, startAngle: .radians(-0.7), endAngle: .radians(0.7), clockwise: false) },
                       with: .color(style.ink.opacity(0.65)), style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
        }
    }

    /// 根: roots branching down from one point, crossed by one red line.
    private static func roots(_ ctx: inout GraphicsContext, _ P: (CGFloat, CGFloat) -> CGPoint, u: CGFloat, line: CGFloat,
                              style: ReaderStyle, seed: UInt64) {
        var random = SeededRandom(seed: seed &+ 5)
        var paths = [Path](repeating: Path(), count: 8)
        func branch(_ p: CGPoint, _ angle: CGFloat, _ length: CGFloat, _ depth: Int) {
            let end = CGPoint(x: p.x + cos(angle) * length, y: p.y + sin(angle) * length)
            let bend = CGPoint(x: (p.x + end.x) / 2 + (random.unit() - 0.5) * length * 0.3, y: (p.y + end.y) / 2)
            paths[depth].move(to: p)
            paths[depth].addQuadCurve(to: end, control: bend)
            guard depth > 0 else { return }
            let spread = 0.3 + random.unit() * 0.35
            branch(end, angle - spread, length * (0.68 + random.unit() * 0.12), depth - 1)
            branch(end, angle + spread, length * (0.68 + random.unit() * 0.12), depth - 1)
            if random.unit() > 0.75 { branch(end, angle + (random.unit() - 0.5) * 0.3, length * 0.6, depth - 1) }
        }
        branch(P(0.5, 0.05), .pi / 2, u * 0.2, 7)
        for depth in 0..<8 {
            ctx.stroke(paths[depth], with: .color(style.ink.opacity(0.35 + CGFloat(depth) * 0.07)),
                       style: StrokeStyle(lineWidth: 0.35 + CGFloat(depth) * 0.16, lineCap: .round))
        }
        ctx.stroke(Path { $0.addLines(FableStroke.quad(P(0.6, 0.0), P(0.42, 0.55), P(0.58, 1.0))) },
                   with: .color(style.spark.opacity(0.9)), lineWidth: 0.8)
    }

    // MARK: Page decoration

    static func backdrop(_ ctx: inout GraphicsContext, _ size: CGSize, style: ReaderStyle) {
        let w = size.width, h = size.height
        switch style.theme.motif {
        case .film:
            specks(&ctx, size, count: style.isDark ? 14 : 5, seed: style.isDark ? 31 : 7,
                   colour: style.secondary.opacity(style.isDark ? 0.34 : 0.16))
        case .graph:
            var minor = Path(), major = Path()
            var i = 0
            var x: CGFloat = 0
            while x <= w {
                if i % 5 == 0 { major.move(to: CGPoint(x: x, y: 0)); major.addLine(to: CGPoint(x: x, y: h)) }
                else { minor.move(to: CGPoint(x: x, y: 0)); minor.addLine(to: CGPoint(x: x, y: h)) }
                x += 18; i += 1
            }
            i = 0
            var y: CGFloat = 0
            while y <= h {
                if i % 5 == 0 { major.move(to: CGPoint(x: 0, y: y)); major.addLine(to: CGPoint(x: w, y: y)) }
                else { minor.move(to: CGPoint(x: 0, y: y)); minor.addLine(to: CGPoint(x: w, y: y)) }
                y += 18; i += 1
            }
            ctx.stroke(minor, with: .color(style.thread.opacity(0.17)), lineWidth: 0.5)
            ctx.stroke(major, with: .color(style.thread.opacity(0.3)), lineWidth: 0.6)
            ctx.opacity = 0.55
            doodle(0, &ctx, CGPoint(x: w - 28, y: h * 0.36), r: 7, line: 1, style: style, seed: 3)
            doodle(1, &ctx, CGPoint(x: 26, y: h * 0.62), r: 9, line: 1, style: style, seed: 4)
            doodle(3, &ctx, CGPoint(x: w - 30, y: h * 0.8), r: 9, line: 1, style: style, seed: 5)
        case .sundown:
            let origin = CGPoint(x: w + 24, y: -30)
            var rays = Path()
            for i in 0..<11 {
                let a = CGFloat.pi * 0.52 + CGFloat(i) * 0.075
                for d in [-0.008, 0.0, 0.008] as [CGFloat] {
                    rays.move(to: CGPoint(x: origin.x + cos(a + d) * 60, y: origin.y + sin(a + d) * 60))
                    rays.addLine(to: CGPoint(x: origin.x + cos(a + d) * h * 0.42, y: origin.y + sin(a + d) * h * 0.42))
                }
            }
            ctx.stroke(rays, with: .color(style.thread.opacity(0.12)), lineWidth: 0.6)
        case .midnight:
            specks(&ctx, size, count: 26, seed: 61, colour: style.secondary.opacity(0.42))
            let moon = CGPoint(x: w * 0.88, y: h * 0.05)
            ctx.fill(Path(ellipseIn: CGRect(x: moon.x - 180, y: moon.y - 180, width: 360, height: 360)),
                     with: .radialGradient(Gradient(colors: [style.thread.opacity(0.09), style.thread.opacity(0)]),
                                           center: moon, startRadius: 0, endRadius: 180))
        case .mist:
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 46))
                layer.fill(Path(ellipseIn: CGRect(x: -w * 0.25, y: -h * 0.12, width: w * 1.1, height: h * 0.3)), with: .color(style.thread.opacity(0.16)))
                layer.fill(Path(ellipseIn: CGRect(x: w * 0.45, y: h * 0.02, width: w * 0.8, height: h * 0.22)), with: .color(style.thread.opacity(0.1)))
            }
            var random = SeededRandom(seed: 77)
            var rain = Path()
            for _ in 0..<44 {
                let p = CGPoint(x: random.unit() * w, y: random.unit() * h * 0.42)
                rain.move(to: p); rain.addLine(to: CGPoint(x: p.x - 4, y: p.y + 18))
            }
            ctx.stroke(rain, with: .color(style.secondary.opacity(0.12)), lineWidth: 0.5)
        case .ballpoint:
            var curls = Path()
            var random = SeededRandom(seed: 19)
            for _ in 0..<7 {
                let c = CGPoint(x: random.unit() * w, y: random.unit() * h)
                for i in 0...24 {
                    let t = CGFloat(i) / 24
                    let p = CGPoint(x: c.x - 9 + t * 18 + cos(t * 16) * 3, y: c.y + sin(t * 16) * 3)
                    if i == 0 { curls.move(to: p) } else { curls.addLine(to: p) }
                }
            }
            ctx.stroke(curls, with: .color(style.spark.opacity(0.16)), lineWidth: 0.6)
        case .echo:
            var dots = Path()
            let radius = min(w, h) * 0.75
            var y: CGFloat = 6
            while y < radius {
                var x: CGFloat = 6
                while x < radius {
                    let d = hypot(x, y) / radius
                    if d < 1 {
                        let r = 2.1 * (1 - d) + 0.2
                        dots.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    }
                    x += 14
                }
                y += 14
            }
            ctx.fill(dots, with: .color(style.thread.opacity(0.18)))
        case .sashiko, .ebru, .cyanotype, .transit, .phool, .doublure, .oneline, .evening:
            portraitBackdrop(&ctx, size, style: style)
        case .roots:
            var random = SeededRandom(seed: 88)
            var lines = Path()
            func branch(_ p: CGPoint, _ angle: CGFloat, _ length: CGFloat, _ depth: Int) {
                let end = CGPoint(x: p.x + cos(angle) * length, y: p.y + sin(angle) * length)
                lines.move(to: p); lines.addLine(to: end)
                guard depth > 0 else { return }
                let spread = 0.3 + random.unit() * 0.35
                branch(end, angle - spread, length * 0.72, depth - 1)
                branch(end, angle + spread, length * 0.72, depth - 1)
            }
            branch(CGPoint(x: w * 0.18, y: -4), .pi / 2, 70, 6)
            branch(CGPoint(x: w * 0.86, y: -4), .pi / 2, 60, 6)
            ctx.stroke(lines, with: .color(style.ink.opacity(0.07)), lineWidth: 0.6)
        }
    }

    static func specks(_ ctx: inout GraphicsContext, _ size: CGSize, count: Int, seed: UInt64, colour: Color) {
        var random = SeededRandom(seed: seed)
        var path = Path()
        for _ in 0..<count {
            let c = CGPoint(x: random.unit() * size.width, y: random.unit() * size.height)
            let r = 1.6 + random.unit() * 2.2
            path.move(to: CGPoint(x: c.x - r, y: c.y)); path.addLine(to: CGPoint(x: c.x + r, y: c.y))
            path.move(to: CGPoint(x: c.x, y: c.y - r)); path.addLine(to: CGPoint(x: c.x, y: c.y + r))
        }
        ctx.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: 0.5, lineCap: .round))
    }
}

/// The page decoration behind every Fable screen.
struct FableBackdrop: View {
    let style: ReaderStyle
    var body: some View {
        Canvas { context, size in FableArt.backdrop(&context, size, style: style) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The small handwritten margin note in each Fable header, in place of a plain label.
enum FableNotes {
    static func note(for latin: String) -> String {
        switch latin.lowercased() {
        case "reading": return "one sentence at a time"
        case "library": return "kept, for later"
        case "grammar": return "the shapes under words"
        default: return latin.lowercased()
        }
    }
}

// MARK: - Swatch

/// The theme-picker miniature: the paper, 儚い, and the theme's own emblem.
struct FableSwatch: View {
    let theme: ReaderTheme
    var compact = false
    var body: some View {
        let width: CGFloat = compact ? 54 : 92, height: CGFloat = compact ? 40 : 66
        let preview = ReaderStyle.preview(theme)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(preview.background)
            Text("儚い").font(.custom(HandFont.bold, size: compact ? 11 : 16)).foregroundStyle(preview.ink)
                .padding(compact ? 4 : 7)
            FableEmblem(style: preview, drawing: .sprig, size: compact ? 28 : 46, decorated: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(compact ? 2 : 4)
        }
        .frame(width: width, height: height)
        .clipped()
    }
}

// MARK: - Web pages

enum FableWeb {
    private static func svgURI(_ svg: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: " .-_/:=,()")
        return "url(\"data:image/svg+xml;charset=utf-8," + (svg.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "\")"
    }
    /// Fine hairline rules (about half the Yohaku brush weight).
    static let ruleMask: String = {
        let path = Brush.ribbon(Brush.line(CGPoint(x: 0.5, y: 4), CGPoint(x: 399.5, y: 4)), width: 0.95, seed: 1207, wobble: 0.5)
        return svgURI("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 400 8' preserveAspectRatio='none'><path d='\(SVGPath.data(path))'/></svg>")
    }()
    static let vRuleMask: String = {
        let path = Brush.ribbon(Brush.line(CGPoint(x: 4, y: 0.5), CGPoint(x: 4, y: 399.5)), width: 0.95, seed: 1709, wobble: 0.5)
        return svgURI("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 8 400' preserveAspectRatio='none'><path d='\(SVGPath.data(path))'/></svg>")
    }()
    /// The wound ring with its opening at the top.
    static let ringMask: String = {
        let start = -CGFloat.pi / 2 + 0.42, end = start + CGFloat.pi * 2 - 0.86
        let points = FableStroke.arc(center: CGPoint(x: 50, y: 50), radius: 44, from: start, to: end, seed: 2026)
        let path = Brush.ribbon(points, width: 2.2, seed: 2031, wobble: 0.35, taper: 14)
        return svgURI("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><path d='\(SVGPath.data(path))'/></svg>")
    }()
    /// Ripples with a small figure: the grammar-lesson header drawing.
    static let headerMask: String = {
        var out = ""
        let ripples = FableRipples(count: 5).path(in: CGRect(x: 0, y: 0, width: 160, height: 160))
        out += "<path d='\(SVGPath.data(ripples))' stroke-width='0.6' opacity='0.45'/>"
        let figure = FableLineArt(drawing: .figure).path(in: CGRect(x: 52, y: 58, width: 56, height: 56))
        out += "<path d='\(SVGPath.data(figure))' stroke-width='1.1'/>"
        return svgURI("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 160 160' fill='none' stroke='black' stroke-linecap='round'>\(out)</svg>")
    }()
    static let sparkMask: String = {
        let path = FableSpark().path(in: CGRect(x: 1, y: 1, width: 18, height: 18))
        return svgURI("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 20 20' fill='none' stroke='black' stroke-width='1.1' stroke-linecap='round'><path d='\(SVGPath.data(path))'/></svg>")
    }()

    /// Extra variables (appended after the Yohaku palette, so they win).
    static func palette(_ style: ReaderStyle) -> String {
        let hex = Palette.hexString
        return ":root{--y-sage:\(hex(style.theme.tapeRGB ?? 0xDDE2CE));--y-thread:\(hex(style.theme.markerRGB ?? 0xB89A6A));"
            + "--y-rule:\(ruleMask);--y-vrule:\(vRuleMask);--y-ring:\(ringMask);--y-fhead:\(headerMask);--y-spark:\(sparkMask);"
            + "--y-frame:var(--y-rule) top/100% 5px no-repeat,var(--y-rule) bottom/100% 5px no-repeat,var(--y-vrule) left/5px 100% no-repeat,var(--y-vrule) right/5px 100% no-repeat;"
            + "--y-hand:\"YHand\",\"YGothic\",\"Hiragino Sans\",sans-serif;--y-caption:\"YCaption\",\"YHand\",sans-serif}"
            + (style.theme.motif == .graph ? graphPaper : "")
            + (style.theme.motif == .sashiko ? ":root{--y-rule:\(stitchMask)}" : "")
    }
    /// 刺し子: dividers sewn as running stitches.
    static let stitchMask: String = {
        var path = Path()
        var x: CGFloat = 2
        while x < 396 {
            path.addPath(Brush.ribbon(Brush.line(CGPoint(x: x, y: 4), CGPoint(x: x + 7, y: 4), step: 1), width: 1.2, seed: UInt64(x) &+ 3, wobble: 0.3, taper: 1.5))
            x += 11.5
        }
        return svgURI("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 400 8' preserveAspectRatio='none'><path d='\(SVGPath.data(path))'/></svg>")
    }()
    /// 方眼: the pages sit on the same graph paper as the app.
    private static let graphPaper = "html:root,html:root body{background-image:linear-gradient(color-mix(in srgb,var(--y-thread) 26%,transparent) .6px,transparent .6px),linear-gradient(90deg,color-mix(in srgb,var(--y-thread) 26%,transparent) .6px,transparent .6px)!important;background-size:18px 18px!important;background-blend-mode:normal!important}"

    static let dictionaryRules = #"""
html:root body{font-family:var(--y-hand)!important}
:root{--e-sans:var(--y-hand);--e-font:var(--y-hand)}
html:root:not(#y) body .dictionary-source{font:400 15px/1.4 var(--y-caption)!important;letter-spacing:.02em!important;text-transform:lowercase!important}
html:root:not(#y) body .dictionary-source::before{background:var(--y-thread)!important}
html:root:not(#y):not(#w) body :is(.num,.wc,.dc-sense,.sense_no,.gogi>.num,.MeaningG .Num,.snum,.hukugi_num){font-family:var(--y-caption)!important;font-weight:300!important}
html:root:not(#y):not(#w) body :is(.slabel,.label,.naihou,.note_div,.shironuki,.daikubun,.gogikubun,.tkbt-label,.type,.kg_eiyaku,.shiyouiki,.senmon_g,.white-square,.hinshi,.bunya,.yoho,.gram){font-family:var(--y-hand)!important}
html:root body mark.jp-hit{background:color-mix(in srgb,var(--y-accent) 18%,transparent)!important}
"""#

    static let grammarRules = #"""
:root{--g-title:var(--y-hand);--g-zh:var(--y-hand)}
header.h{padding-top:150px}
header.h::before{left:-10px;top:0;width:150px;height:150px;background:var(--y-muted);
 -webkit-mask:var(--y-fhead) left center/contain no-repeat;mask:var(--y-fhead) left center/contain no-repeat}
body .badge{width:72px;height:72px;font:400 22px/1 var(--y-caption);color:var(--y-ink)}
body .badge::before{background:var(--y-ink)}
body .badge::after{content:"";position:absolute;left:50%;top:-12px;width:14px;height:14px;margin-left:-7px;background:var(--y-accent);
 -webkit-mask:var(--y-spark) center/contain no-repeat;mask:var(--y-spark) center/contain no-repeat}
h1{font-family:var(--y-hand);font-weight:600}
section>h2,h2{font-family:var(--y-hand);font-weight:600}
section>h2::before{font:400 1.15em/1.2 var(--y-caption);letter-spacing:0}
footer{font:400 14px/1.6 var(--y-caption);letter-spacing:.02em;text-transform:lowercase}
.reg{background:var(--y-sage)}
li::marker{color:var(--y-muted)}
summary::before{content:"~ "}
"""#
}
