import SwiftUI

// 自画像 Self-portraits — the same head-and-shoulders figure, drawn each time in a
// different craft (after Kengo Works' "self-portraits" and "still"). Each theme's
// header emblem is a small square tile: a ground worked in one pattern, and the
// figure worked in another.
//
//   sashiko    indigo cloth, running stitches, a figure in gold dots (after "still")
//   ebru       marbled stones in navy and gold round a figure of wavy contour lines
//   cyanotype  white sprigs on blue, blue sprigs on the figure
//   transit    a route map, and a figure in coloured vertical stripes
//   phool      truck-art green, a yellow figure, red flowers
//   doublure   gold-tooled leather: a lattice, gold dust, a dark figure
//   oneline    mustard ground and a single wandering line
//
// Plus 夕 evening: a watercolour dusk sky with a pylon and its wires (underlight).

extension FableArt {
    typealias Point = (CGFloat, CGFloat) -> CGPoint

    /// A tile clipped to rounded corners: ground, then the figure on top of it.
    private static func tile(_ ctx: inout GraphicsContext, _ P: Point, u: CGFloat, ground: Color, figure fill: Color,
                             border: Color, groundArt: (inout GraphicsContext) -> Void, figureArt: (inout GraphicsContext) -> Void) {
        let a = P(0.05, 0.05), b = P(0.95, 0.95)
        let frame = Path(roundedRect: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y), cornerRadius: u * 0.035)
        let body = figure(P, u: u)
        ctx.drawLayer { layer in
            layer.clip(to: frame)
            layer.fill(frame, with: .color(ground))
            groundArt(&layer)
            layer.drawLayer { inner in
                inner.clip(to: body)
                inner.fill(body, with: .color(fill))
                figureArt(&inner)
            }
        }
        ctx.stroke(frame, with: .color(border), lineWidth: 0.7)
    }

    static func portrait(_ ctx: inout GraphicsContext, _ P: Point, u: CGFloat, line: CGFloat, style: ReaderStyle, seed: UInt64) {
        switch style.theme.motif {
        case .sashiko: sashiko(&ctx, P, u: u, style: style, seed: seed)
        case .ebru: ebru(&ctx, P, u: u, style: style, seed: seed)
        case .cyanotype: cyanotype(&ctx, P, u: u, style: style, seed: seed)
        case .transit: transit(&ctx, P, u: u, style: style, seed: seed)
        case .phool: phool(&ctx, P, u: u, style: style, seed: seed)
        case .doublure: doublure(&ctx, P, u: u, style: style, seed: seed)
        case .oneline: oneline(&ctx, P, u: u, style: style, seed: seed)
        case .evening: evening(&ctx, P, u: u, line: line, style: style, seed: seed)
        default: break
        }
    }

    // MARK: Small pieces

    /// Dashes along a straight line: a running stitch.
    static func stitches(from a: CGPoint, to b: CGPoint, dash: CGFloat, gap: CGFloat, into path: inout Path) {
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0 else { return }
        let dx = (b.x - a.x) / length, dy = (b.y - a.y) / length
        var s: CGFloat = gap / 2
        while s < length {
            let e = min(length, s + dash)
            path.move(to: CGPoint(x: a.x + dx * s, y: a.y + dy * s))
            path.addLine(to: CGPoint(x: a.x + dx * e, y: a.y + dy * e))
            s += dash + gap
        }
    }

    /// A stem with small leaves on both sides.
    static func sprig(from a: CGPoint, angle: CGFloat, length: CGFloat, leaves: Int, stem: inout Path, leaf: inout Path) {
        let end = CGPoint(x: a.x + cos(angle) * length, y: a.y + sin(angle) * length)
        let bend = CGPoint(x: (a.x + end.x) / 2 - sin(angle) * length * 0.18, y: (a.y + end.y) / 2 + cos(angle) * length * 0.18)
        let points = FableStroke.quad(a, bend, end, steps: 16)
        stem.addLines(points)
        for k in 1...max(1, leaves) {
            let index = min(points.count - 1, k * (points.count - 1) / (leaves + 1))
            let p = points[index]
            let side: CGFloat = k % 2 == 0 ? 1 : -1
            let turn = angle + side * 0.9
            let size = length * 0.16
            let c = CGPoint(x: p.x + cos(turn) * size * 0.7, y: p.y + sin(turn) * size * 0.7)
            let shape = Path(ellipseIn: CGRect(x: -size * 0.7, y: -size * 0.3, width: size * 1.4, height: size * 0.6))
            leaf.addPath(shape, transform: CGAffineTransform(translationX: c.x, y: c.y).rotated(by: turn))
        }
    }

    // MARK: The crafts

    /// 刺し子: indigo cloth, a grid of running stitches, a dotted wandering path,
    /// and the figure filled with rows of gold dots.
    private static func sashiko(_ ctx: inout GraphicsContext, _ P: Point, u: CGFloat, style: ReaderStyle, seed: UInt64) {
        let cloth = Palette.color(Palette.raised(style.backgroundRGB ?? 0x1F2947, 0.07))
        tile(&ctx, P, u: u, ground: cloth, figure: style.spark, border: style.ink.opacity(0.5), groundArt: { layer in
            var stitch = Path()
            var k: CGFloat = 0.11
            while k < 0.95 {
                stitches(from: P(0.05, k), to: P(0.95, k), dash: u * 0.035, gap: u * 0.03, into: &stitch)
                stitches(from: P(k, 0.05), to: P(k, 0.95), dash: u * 0.035, gap: u * 0.03, into: &stitch)
                k += 0.12
            }
            layer.stroke(stitch, with: .color(style.ink.opacity(0.42)), style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
            var path = Path()
            for p in FableStroke.quad(P(0.1, 0.05), P(0.5, 0.5), P(0.12, 0.95), steps: 26) {
                path.addEllipse(in: CGRect(x: p.x - 0.5, y: p.y - 0.5, width: 1, height: 1))
            }
            layer.fill(path, with: .color(style.ink.opacity(0.75)))
        }, figureArt: { layer in
            var dots = Path()
            var row = 0
            var y: CGFloat = 0.12
            while y < 0.98 {
                var x: CGFloat = row % 2 == 0 ? 0.08 : 0.1
                while x < 0.95 {
                    let p = P(x, y)
                    dots.addEllipse(in: CGRect(x: p.x - u * 0.007, y: p.y - u * 0.007, width: u * 0.014, height: u * 0.014))
                    x += 0.04
                }
                y += 0.036; row += 1
            }
            layer.fill(dots, with: .color(style.background.opacity(0.55)))
        })
    }

    /// 墨流し: marbled stones in navy and gold; the figure is cream with wavy lines.
    private static func ebru(_ ctx: inout GraphicsContext, _ P: Point, u: CGFloat, style: ReaderStyle, seed: UInt64) {
        let navy = style.thread, gold = style.spark
        tile(&ctx, P, u: u, ground: style.background, figure: style.background, border: style.ink.opacity(0.45), groundArt: { layer in
            var random = SeededRandom(seed: seed &+ 21)
            var placed: [(CGPoint, CGFloat)] = []
            var tries = 0
            while placed.count < 46 && tries < 600 {
                tries += 1
                let c = P(0.05 + random.unit() * 0.9, 0.05 + random.unit() * 0.9)
                let r = u * (0.035 + random.unit() * 0.055)
                var clash = false
                for other in placed {
                    let distance: CGFloat = hypot(other.0.x - c.x, other.0.y - c.y)
                    if distance < other.1 + r + u * 0.012 { clash = true; break }
                }
                if clash { continue }
                placed.append((c, r))
                let squash = 0.8 + random.unit() * 0.35
                let stone = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r * squash, width: r * 2, height: r * 2 * squash))
                layer.fill(stone, with: .color(placed.count % 3 == 0 ? gold : navy))
            }
        }, figureArt: { layer in
            var waves = Path()
            var y: CGFloat = 0.2
            var row: CGFloat = 0
            while y < 0.98 {
                for i in 0...40 {
                    let t = CGFloat(i) / 40
                    let p = P(0.05 + t * 0.9, y + sin(t * .pi * 5 + row) * 0.012)
                    if i == 0 { waves.move(to: p) } else { waves.addLine(to: p) }
                }
                y += 0.04; row += 0.9
            }
            layer.stroke(waves, with: .color(navy.opacity(0.75)), lineWidth: 0.55)
        })
        ctx.stroke(figure(P, u: u), with: .color(navy.opacity(0.8)), lineWidth: 0.7)
    }

    /// 青写真: a cyanotype. White sprigs on the blue ground, blue sprigs on the figure.
    private static func cyanotype(_ ctx: inout GraphicsContext, _ P: Point, u: CGFloat, style: ReaderStyle, seed: UInt64) {
        let blue = style.thread
        func sprigs(_ layer: inout GraphicsContext, colour: Color, salt: UInt64, count: Int) {
            var random = SeededRandom(seed: seed &+ salt)
            var stem = Path(), leaf = Path()
            for _ in 0..<count {
                let a = P(0.05 + random.unit() * 0.9, 0.15 + random.unit() * 0.85)
                sprig(from: a, angle: -CGFloat.pi / 2 + (random.unit() - 0.5) * 1.6, length: u * (0.2 + random.unit() * 0.16),
                      leaves: 4, stem: &stem, leaf: &leaf)
            }
            layer.stroke(stem, with: .color(colour), style: StrokeStyle(lineWidth: 0.6, lineCap: .round))
            layer.fill(leaf, with: .color(colour))
        }
        tile(&ctx, P, u: u, ground: blue, figure: style.background, border: blue.opacity(0.6),
             groundArt: { layer in sprigs(&layer, colour: style.background.opacity(0.9), salt: 3, count: 9) },
             figureArt: { layer in sprigs(&layer, colour: blue.opacity(0.75), salt: 9, count: 7) })
    }

    static let routeColours: [Color] = [Palette.color(0xD8492F), Palette.color(0x2F6FB3), Palette.color(0x3E9A63),
                                        Palette.color(0xE39A2D), Palette.color(0x7B4FA0), Palette.color(0x23323A)]

    /// 路線図: a route map on the ground; the figure in coloured vertical stripes.
    private static func transit(_ ctx: inout GraphicsContext, _ P: Point, u: CGFloat, style: ReaderStyle, seed: UInt64) {
        tile(&ctx, P, u: u, ground: Palette.color(Palette.mix(style.backgroundRGB ?? 0xE9F0EA, toward: 0xFFFFFF, 0.35)), figure: style.background,
             border: style.ink.opacity(0.4), groundArt: { layer in
            let routes: [[CGPoint]] = [
                [P(0.05, 0.2), P(0.3, 0.2), P(0.42, 0.32), P(0.95, 0.32)],
                [P(0.18, 0.05), P(0.18, 0.5), P(0.3, 0.62), P(0.3, 0.95)],
                [P(0.05, 0.74), P(0.5, 0.74), P(0.62, 0.86), P(0.95, 0.86)],
                [P(0.8, 0.05), P(0.8, 0.45), P(0.68, 0.57), P(0.68, 0.95)],
                [P(0.05, 0.48), P(0.95, 0.48)]
            ]
            for (i, route) in routes.enumerated() {
                layer.stroke(Path { $0.addLines(route) }, with: .color(routeColours[i].opacity(0.85)),
                             style: StrokeStyle(lineWidth: max(1, u * 0.014), lineCap: .round, lineJoin: .round))
                for p in route.dropFirst().dropLast() {
                    let stop = Path(ellipseIn: CGRect(x: p.x - u * 0.014, y: p.y - u * 0.014, width: u * 0.028, height: u * 0.028))
                    layer.fill(stop, with: .color(.white))
                    layer.stroke(stop, with: .color(style.ink.opacity(0.8)), lineWidth: 0.5)
                }
            }
        }, figureArt: { layer in
            var x: CGFloat = 0.05
            var i = 0
            while x < 0.95 {
                let a = P(x, 0.05), b = P(x + 0.026, 0.98)
                layer.fill(Path(CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)), with: .color(routeColours[i % routeColours.count]))
                x += 0.034; i += 1
            }
        })
    }

    /// 花: truck-art flowers. Deep green, a yellow figure brushed with cream, red roses.
    private static func phool(_ ctx: inout GraphicsContext, _ P: Point, u: CGFloat, style: ReaderStyle, seed: UInt64) {
        let red = style.thread, cream = style.ink
        func rose(_ layer: inout GraphicsContext, _ c: CGPoint, _ r: CGFloat) {
            var petals = Path()
            for i in 0..<5 {
                let a = CGFloat(i) * .pi * 2 / 5
                petals.addEllipse(in: CGRect(x: c.x + cos(a) * r * 0.55 - r * 0.45, y: c.y + sin(a) * r * 0.55 - r * 0.45, width: r * 0.9, height: r * 0.9))
            }
            layer.fill(petals, with: .color(red))
            layer.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.25, y: c.y - r * 0.25, width: r * 0.5, height: r * 0.5)), with: .color(cream))
        }
        tile(&ctx, P, u: u, ground: Palette.color(Palette.raised(style.backgroundRGB ?? 0x21402C, 0.05)), figure: style.spark,
             border: cream.opacity(0.5), groundArt: { layer in
            var random = SeededRandom(seed: seed &+ 2)
            var scallops = Path()
            var x: CGFloat = 0.05
            while x < 0.95 {
                scallops.addArc(center: P(x + 0.05, 0.05), radius: u * 0.05, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
                x += 0.1
            }
            layer.fill(scallops, with: .color(cream.opacity(0.85)))
            var dots = Path()
            for _ in 0..<26 {
                let p = P(0.06 + random.unit() * 0.88, 0.16 + random.unit() * 0.8)
                dots.addEllipse(in: CGRect(x: p.x - u * 0.01, y: p.y - u * 0.01, width: u * 0.02, height: u * 0.02))
            }
            layer.fill(dots, with: .color(cream.opacity(0.5)))
            rose(&layer, P(0.15, 0.3), u * 0.05)
            rose(&layer, P(0.86, 0.24), u * 0.045)
        }, figureArt: { layer in
            var strokes = Path()
            var random = SeededRandom(seed: seed &+ 6)
            for _ in 0..<26 {
                let p = P(0.1 + random.unit() * 0.8, 0.2 + random.unit() * 0.78)
                strokes.move(to: p)
                strokes.addLine(to: CGPoint(x: p.x + u * (0.08 + random.unit() * 0.08), y: p.y - u * 0.04))
            }
            layer.stroke(strokes, with: .color(cream.opacity(0.75)), style: StrokeStyle(lineWidth: u * 0.018, lineCap: .round))
            rose(&layer, P(0.4, 0.74), u * 0.055)
            rose(&layer, P(0.66, 0.84), u * 0.05)
            rose(&layer, P(0.52, 0.34), u * 0.04)
        })
    }

    /// 見返し: gold-tooled leather. A diagonal lattice and gold dust; a dark figure.
    private static func doublure(_ ctx: inout GraphicsContext, _ P: Point, u: CGFloat, style: ReaderStyle, seed: UInt64) {
        let gold = style.thread
        func lattice(_ layer: inout GraphicsContext, opacity: CGFloat) {
            var lines = Path()
            var k: CGFloat = -1
            while k < 2 {
                lines.move(to: P(k, 0)); lines.addLine(to: P(k + 0.55, 1))
                lines.move(to: P(k + 0.55, 0)); lines.addLine(to: P(k, 1))
                k += 0.2
            }
            layer.stroke(lines, with: .color(gold.opacity(opacity)), lineWidth: 0.6)
        }
        tile(&ctx, P, u: u, ground: Palette.color(0x7A5A2A), figure: Palette.color(0x2A170F), border: gold.opacity(0.8), groundArt: { layer in
            var random = SeededRandom(seed: seed &+ 4)
            var dust = Path()
            for _ in 0..<260 {
                let p = P(0.05 + random.unit() * 0.9, 0.05 + random.unit() * 0.9)
                dust.addEllipse(in: CGRect(x: p.x - 0.5, y: p.y - 0.5, width: 1, height: 1))
            }
            layer.fill(dust, with: .color(gold.opacity(0.8)))
            var dark = Path()
            var k: CGFloat = -1
            while k < 2 {
                dark.move(to: P(k, 0)); dark.addLine(to: P(k + 0.55, 1))
                dark.move(to: P(k + 0.55, 0)); dark.addLine(to: P(k, 1))
                k += 0.2
            }
            layer.stroke(dark, with: .color(Palette.color(0x2A170F).opacity(0.8)), lineWidth: 0.8)
        }, figureArt: { layer in lattice(&layer, opacity: 0.35) })
        ctx.stroke(figure(P, u: u), with: .color(gold.opacity(0.9)), lineWidth: 0.7)
    }

    /// 一筆: a mustard ground walked over by one wandering line; a dark figure with
    /// fine gold lines running out from its centre.
    private static func oneline(_ ctx: inout GraphicsContext, _ P: Point, u: CGFloat, style: ReaderStyle, seed: UInt64) {
        tile(&ctx, P, u: u, ground: style.thread, figure: Palette.color(0x2A2110), border: style.ink.opacity(0.5), groundArt: { layer in
            var random = SeededRandom(seed: seed &+ 8)
            let cells = 14
            var x = 1, y = 1, direction = 0
            var walk: [CGPoint] = []
            func at(_ x: Int, _ y: Int) -> CGPoint {
                let fx: CGFloat = (CGFloat(x) + 0.5) / CGFloat(cells)
                let fy: CGFloat = (CGFloat(y) + 0.5) / CGFloat(cells)
                return P(0.05 + 0.9 * fx, 0.05 + 0.9 * fy)
            }
            walk.append(at(x, y))
            for _ in 0..<150 {
                if random.unit() > 0.55 { direction = (direction + (random.unit() > 0.5 ? 1 : 3)) % 4 }
                var nx = x, ny = y
                if direction == 0 { nx += 1 } else if direction == 1 { ny += 1 } else if direction == 2 { nx -= 1 } else { ny -= 1 }
                if nx < 0 || ny < 0 || nx >= cells || ny >= cells { direction = (direction + 1) % 4; continue }
                x = nx; y = ny
                walk.append(at(x, y))
            }
            layer.stroke(Path { $0.addLines(walk) }, with: .color(Palette.color(0x241E12).opacity(0.8)),
                         style: StrokeStyle(lineWidth: 0.7, lineCap: .round, lineJoin: .round))
        }, figureArt: { layer in
            var rays = Path()
            let c = P(0.5, 0.36)
            for i in 0..<40 {
                let a = CGFloat(i) * .pi * 2 / 40
                rays.move(to: CGPoint(x: c.x + cos(a) * u * 0.03, y: c.y + sin(a) * u * 0.03))
                rays.addLine(to: CGPoint(x: c.x + cos(a) * u * 0.9, y: c.y + sin(a) * u * 0.9))
            }
            layer.stroke(rays, with: .color(style.thread.opacity(0.7)), lineWidth: 0.45)
        })
    }

    /// 夕: a watercolour dusk. Violet to peach, lit clouds, a pylon and its wires.
    private static func evening(_ ctx: inout GraphicsContext, _ P: Point, u: CGFloat, line: CGFloat, style: ReaderStyle, seed: UInt64) {
        let a = P(0.05, 0.05), b = P(0.95, 0.95)
        let rect = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        let frame = Path(roundedRect: rect, cornerRadius: u * 0.035)
        let violet = Palette.color(0x6C5AA6), peach = Palette.color(0xF2A47C), rose = Palette.color(0xE98FA0), dark = Palette.color(0x2C2440)
        ctx.drawLayer { layer in
            layer.clip(to: frame)
            layer.fill(frame, with: .linearGradient(Gradient(colors: [violet, rose, peach]), startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
            layer.drawLayer { soft in
                soft.addFilter(.blur(radius: u * 0.035))
                for (x, y, w, h, colour) in [(0.1, 0.2, 0.5, 0.2, peach), (0.45, 0.34, 0.5, 0.18, Palette.color(0xF7C9AE)),
                                             (0.18, 0.3, 0.3, 0.12, rose), (0.55, 0.14, 0.3, 0.1, Palette.color(0xF3B7B0))] as [(CGFloat, CGFloat, CGFloat, CGFloat, Color)] {
                    let o = P(x, y)
                    soft.fill(Path(ellipseIn: CGRect(x: o.x, y: o.y, width: u * w, height: u * h)), with: .color(colour.opacity(0.85)))
                }
            }
            // Ground haze and the pylon.
            layer.fill(Path(CGRect(x: rect.minX, y: P(0, 0.8).y, width: rect.width, height: rect.maxY - P(0, 0.8).y)), with: .color(dark.opacity(0.55)))
            var pylon = Path()
            pylon.move(to: P(0.66, 0.36)); pylon.addLine(to: P(0.6, 0.86))
            pylon.move(to: P(0.66, 0.36)); pylon.addLine(to: P(0.72, 0.86))
            for (y, w) in [(0.44, 0.1), (0.52, 0.13), (0.62, 0.05), (0.72, 0.07)] as [(CGFloat, CGFloat)] {
                pylon.move(to: P(0.66 - w, y)); pylon.addLine(to: P(0.66 + w, y))
            }
            pylon.move(to: P(0.63, 0.62)); pylon.addLine(to: P(0.7, 0.72))
            pylon.move(to: P(0.69, 0.62)); pylon.addLine(to: P(0.62, 0.72))
            layer.stroke(pylon, with: .color(dark.opacity(0.9)), style: StrokeStyle(lineWidth: line * 0.8, lineCap: .round))
            for (from, control, to) in [(P(0.56, 0.44), P(0.3, 0.56), P(0.05, 0.5)), (P(0.53, 0.52), P(0.3, 0.64), P(0.05, 0.58)),
                                        (P(0.76, 0.44), P(0.86, 0.5), P(0.95, 0.47))] {
                layer.stroke(Path { $0.addLines(FableStroke.quad(from, control, to)) }, with: .color(dark.opacity(0.8)), lineWidth: line * 0.5)
            }
        }
        ctx.stroke(frame, with: .color(style.ink.opacity(0.35)), lineWidth: 0.7)
    }

    // MARK: Page decoration

    /// Faint traces of each craft at the top of the page, clear of the reading area.
    static func portraitBackdrop(_ ctx: inout GraphicsContext, _ size: CGSize, style: ReaderStyle) {
        let w = size.width, h = size.height
        switch style.theme.motif {
        case .sashiko:
            var stitch = Path()
            var y: CGFloat = 30
            var row = 0
            while y < h * 0.3 {
                var x: CGFloat = w * 0.45 + (row % 2 == 0 ? 0 : 12)
                while x < w {
                    stitch.move(to: CGPoint(x: x - 3, y: y)); stitch.addLine(to: CGPoint(x: x + 3, y: y))
                    stitch.move(to: CGPoint(x: x, y: y - 3)); stitch.addLine(to: CGPoint(x: x, y: y + 3))
                    x += 24
                }
                y += 24; row += 1
            }
            ctx.stroke(stitch, with: .color(style.ink.opacity(0.09)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
            specks(&ctx, size, count: 10, seed: 91, colour: style.secondary.opacity(0.3))
        case .ebru:
            var random = SeededRandom(seed: 44)
            for i in 0..<12 {
                let c = CGPoint(x: w * (0.55 + random.unit() * 0.5), y: h * random.unit() * 0.16)
                let r = 8 + random.unit() * 16
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r * 0.85, width: r * 2, height: r * 1.7)),
                         with: .color((i % 3 == 0 ? style.spark : style.thread).opacity(0.09)))
            }
        case .cyanotype:
            var stem = Path(), leaf = Path()
            sprig(from: CGPoint(x: w - 18, y: h * 0.2), angle: -CGFloat.pi * 0.62, length: 120, leaves: 6, stem: &stem, leaf: &leaf)
            sprig(from: CGPoint(x: 14, y: h * 0.86), angle: -CGFloat.pi * 0.36, length: 100, leaves: 5, stem: &stem, leaf: &leaf)
            ctx.stroke(stem, with: .color(style.thread.opacity(0.16)), lineWidth: 0.8)
            ctx.fill(leaf, with: .color(style.thread.opacity(0.12)))
        case .transit:
            let routes: [[CGPoint]] = [
                [CGPoint(x: w * 0.5, y: -4), CGPoint(x: w * 0.5, y: 26), CGPoint(x: w * 0.62, y: 44), CGPoint(x: w + 4, y: 44)],
                [CGPoint(x: w * 0.72, y: -4), CGPoint(x: w * 0.72, y: 60), CGPoint(x: w * 0.84, y: 78), CGPoint(x: w + 4, y: 78)]
            ]
            for (i, route) in routes.enumerated() {
                ctx.stroke(Path { $0.addLines(route) }, with: .color(routeColours[i].opacity(0.22)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        case .phool:
            var random = SeededRandom(seed: 52)
            var dots = Path()
            for _ in 0..<40 {
                let p = CGPoint(x: random.unit() * w, y: random.unit() * h)
                dots.addEllipse(in: CGRect(x: p.x - 1.2, y: p.y - 1.2, width: 2.4, height: 2.4))
            }
            ctx.fill(dots, with: .color(style.ink.opacity(0.1)))
        case .doublure:
            var lines = Path()
            var k: CGFloat = -h
            while k < w + h {
                lines.move(to: CGPoint(x: k, y: 0)); lines.addLine(to: CGPoint(x: k + h * 0.55, y: h))
                lines.move(to: CGPoint(x: k + h * 0.55, y: 0)); lines.addLine(to: CGPoint(x: k, y: h))
                k += 64
            }
            ctx.stroke(lines, with: .color(style.thread.opacity(0.055)), lineWidth: 0.6)
        case .oneline:
            var random = SeededRandom(seed: 63)
            var x = w * 0.6, y: CGFloat = 20
            var direction = 0
            var walk: [CGPoint] = [CGPoint(x: x, y: y)]
            for _ in 0..<40 {
                if random.unit() > 0.5 { direction = (direction + (random.unit() > 0.5 ? 1 : 3)) % 4 }
                var nx = x, ny = y
                if direction == 0 { nx += 16 } else if direction == 1 { ny += 16 } else if direction == 2 { nx -= 16 } else { ny -= 16 }
                if nx < w * 0.45 || nx > w - 8 || ny < 8 || ny > h * 0.2 { direction = (direction + 1) % 4; continue }
                x = nx; y = ny
                walk.append(CGPoint(x: x, y: y))
            }
            ctx.stroke(Path { $0.addLines(walk) }, with: .color(style.ink.opacity(0.1)),
                       style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round))
        case .evening:
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 50))
                layer.fill(Path(ellipseIn: CGRect(x: -w * 0.2, y: -h * 0.1, width: w * 0.9, height: h * 0.24)), with: .color(Palette.color(0x8D76C2).opacity(0.2)))
                layer.fill(Path(ellipseIn: CGRect(x: w * 0.4, y: -h * 0.04, width: w * 0.8, height: h * 0.22)), with: .color(Palette.color(0xF2A47C).opacity(0.22)))
                layer.fill(Path(ellipseIn: CGRect(x: w * 0.1, y: h * 0.06, width: w * 0.6, height: h * 0.12)), with: .color(Palette.color(0xE98FA0).opacity(0.14)))
            }
        default: break
        }
    }
}
