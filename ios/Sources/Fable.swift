import SwiftUI
import UIKit

// 糸 Fable — the Claude style ("drawn from the inside"). Built on top of 余白 Yohaku:
// the same flat editorial layouts, but drawn finer and warmer:
//   • cream / sage / blush / warm-grey / night papers with a fine grain,
//   • ink hairlines instead of brush rules (about half the weight),
//   • handwritten lowercase captions (Gaegu) and pen-textbook titles (Klee One),
//   • a fine pen circle that never quite closes, a small rust spark in its
//     opening, and faint ripples behind it,
//   • small handwritten notes in the margins, and a few faint specks on the paper.
// It borrows the film's spirit (quiet, warm, unfinished), not its pictures.
// Everything here is only drawn while a Fable paper is chosen (ReaderTheme.fable).

// MARK: - Shapes

/// A gently wobbling arc (radians, 0 = 3 o'clock, clockwise on screen).
enum FableStroke {
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

}

/// A fine pen circle, drawn twice the way a hand goes over a pencil line: one
/// confident stroke and one fainter second pass. It never quite closes: a small
/// opening near the top is left unfinished.
struct FableRing: View {
    let style: ReaderStyle
    var weight: CGFloat = 1.5
    var seed: UInt64 = 2026
    var body: some View {
        Canvas { context, size in
            let r = min(size.width, size.height) / 2 - weight - 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let start = -CGFloat.pi / 2 + 0.30, end = start + CGFloat.pi * 2 - 0.55
            let main = FableStroke.arc(center: c, radius: r, from: start, to: end, seed: seed, wobble: 0.012)
            context.fill(Brush.ribbon(main, width: weight, seed: seed &+ 5, wobble: 0.35, taper: 14),
                         with: .color(style.ink.opacity(0.82)))
            let again = FableStroke.arc(center: CGPoint(x: c.x + 0.8, y: c.y - 0.6), radius: r * 0.985,
                                        from: start + 0.9, to: end - 1.6, seed: seed &+ 11, wobble: 0.016)
            context.fill(Brush.ribbon(again, width: weight * 0.6, seed: seed &+ 13, wobble: 0.4, taper: 18),
                         with: .color(style.ink.opacity(0.28)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The small rust spark: eight fine rays and a dot.
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
            let points = FableStroke.arc(center: c, radius: r, from: 0, to: .pi * 2, seed: UInt64(41 + i), wobble: 0.008)
            path.addLines(points)
        }
        return path
    }
}

/// Small single-line drawings for the emblems.
enum FableDrawing {
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
            // Head and shoulders, the silhouette inside the ring.
            path.addEllipse(in: CGRect(x: 0.37, y: 0.12, width: 0.26, height: 0.28))
            path.move(to: p(0.44, 0.39))
            path.addCurve(to: p(0.12, 0.98), control1: p(0.44, 0.52), control2: p(0.16, 0.56))
            path.move(to: p(0.56, 0.39))
            path.addCurve(to: p(0.88, 0.98), control1: p(0.56, 0.52), control2: p(0.84, 0.56))
        case .helix:
            // "a conversation": two strands winding round each other.
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

/// The emblem: ripples, the wound ring, a fine drawing inside and the rust spark.
struct FableEmblem: View {
    let style: ReaderStyle
    var drawing: YohakuDrawing = .sprig
    var size: CGFloat = 118
    var ripples = true
    var body: some View {
        let art = FableDrawing(drawing)
        ZStack {
            if ripples {
                FableRipples(count: 3)
                    .stroke(style.secondary.opacity(style.isDark ? 0.20 : 0.13), lineWidth: 0.5)
                    .frame(width: size * 1.12, height: size * 1.12)
            }
            FableRing(style: style, weight: max(1.2, size * 0.014))
                .frame(width: size * 0.86, height: size * 0.86)
            FableLineArt(drawing: art)
                .stroke(style.ink.opacity(0.7), style: StrokeStyle(lineWidth: 0.85, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.44, height: size * 0.44)
                .offset(y: art == .figure ? size * 0.12 : 0)
            FableSpark()
                .stroke(style.spark, style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                .frame(width: size * 0.13, height: size * 0.13)
                .offset(x: size * 0.07, y: -size * 0.43)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Background

/// A few faint four-point stars scattered over the page (more of them at night).
struct FableStars: Shape {
    var count = 9
    var seed: UInt64 = 7
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var random = SeededRandom(seed: seed)
        for _ in 0..<count {
            let c = CGPoint(x: rect.minX + random.unit() * rect.width, y: rect.minY + random.unit() * rect.height)
            let r = 1.6 + random.unit() * 2.2
            path.move(to: CGPoint(x: c.x - r, y: c.y)); path.addLine(to: CGPoint(x: c.x + r, y: c.y))
            path.move(to: CGPoint(x: c.x, y: c.y - r)); path.addLine(to: CGPoint(x: c.x, y: c.y + r))
        }
        return path
    }
}


/// The page decoration behind every Fable screen: only a few faint specks, like
/// marks on old paper. (No lines run through the reading area.)
struct FableBackdrop: View {
    let style: ReaderStyle
    var body: some View {
        FableStars(count: style.isDark ? 12 : 5, seed: style.isDark ? 31 : 7)
            .stroke(style.secondary.opacity(style.isDark ? 0.32 : 0.16), style: StrokeStyle(lineWidth: 0.5, lineCap: .round))
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

/// The theme-picker miniature of a Fable paper.
struct FableSwatch: View {
    let theme: ReaderTheme
    var compact = false
    var body: some View {
        let width: CGFloat = compact ? 54 : 92, height: CGFloat = compact ? 40 : 66
        let paper = Palette.color(theme.backgroundRGB ?? 0xF5F0E4)
        let ink = Palette.color(theme.inkRGB ?? 0x2B2925)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(paper)
            Text("儚い").font(.custom(HandFont.bold, size: compact ? 12 : 17)).foregroundStyle(ink)
                .padding(compact ? 5 : 8)
            Circle()
                .trim(from: 0.1, to: 0.94)
                .stroke(ink.opacity(0.8), style: StrokeStyle(lineWidth: compact ? 1 : 1.3, lineCap: .round))
                .rotationEffect(.degrees(-80))
                .frame(width: compact ? 15 : 24, height: compact ? 15 : 24)
                .overlay(FableSpark().stroke(Palette.color(theme.highlightRGB ?? 0xB04A3C), lineWidth: 0.7)
                    .frame(width: compact ? 5 : 7, height: compact ? 5 : 7))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(compact ? 5 : 8)
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
    }

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
