import SwiftUI
import UIKit
import CoreText

// 余白 Yohaku — the editorial theme: New Bauhaus / Swiss modernism. Cream paper,
// navy hairlines, square corners, no shadows, and off-centre geometric headers with
// one small single-weight line drawing. The hand-drawn helpers in HandDrawn.swift
// and ReaderComponents.swift switch to this look while it is the active theme.

enum YohakuDesign {
    /// Set whenever the reader style is resolved; read by shapes and fonts that
    /// have no style of their own (SketchShape, HandFont).
    nonisolated(unsafe) static var active = false
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

/// A 1px navy rule.
struct YohakuRule: View {
    let style: ReaderStyle
    var weight: CGFloat = 1
    var body: some View {
        Rectangle().fill(style.navy).frame(height: weight).accessibilityHidden(true)
    }
}

// MARK: - Line drawings

/// The single-weight hand-drawn line art of the style guide (book, pen, teacup, sprig).
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
            } else if character == "-" && !token.isEmpty && token.last != "e" {
                endToken(); token = "-"
            } else {
                token.append(character)
            }
        }
        endToken(); flush()
        return path
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

// MARK: - Screen header

/// The off-centre geometric composition at the top of a screen: faint grid lines,
/// one large flat circle or square (sometimes bleeding off the edge), a smaller
/// block, a thin vertical rule and one small line drawing.
struct YohakuComposition: View {
    enum Layout { case circleRight, squareRight, blockLeft }
    let style: ReaderStyle
    var layout: Layout = .circleRight
    var drawing: YohakuDrawing = .book

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            ZStack(alignment: .topLeading) {
                // Faint four-column grid.
                ForEach(0..<5, id: \.self) { i in
                    Rectangle().fill(style.navy.opacity(0.10))
                        .frame(width: 1, height: h)
                        .offset(x: 16 + CGFloat(i) * (w - 32) / 4)
                }
                switch layout {
                case .circleRight:
                    let d = h * 1.45
                    Circle().fill(style.navy).frame(width: d, height: d).offset(x: w * 0.56, y: -h * 0.12)
                    Rectangle().fill(style.sage).frame(width: h * 0.5, height: h * 0.5).offset(x: w * 0.47, y: h * 0.52)
                    Rectangle().fill(style.navy).frame(width: 1, height: h).offset(x: w * 0.42)
                    YohakuLineArt(drawing: drawing)
                        .stroke(style.background, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .frame(width: d * 0.42, height: d * 0.32)
                        .offset(x: w * 0.56 + d * 0.18, y: -h * 0.12 + d * 0.30)
                case .squareRight:
                    let side = h * 1.05
                    Rectangle().fill(style.navy).frame(width: side, height: side).offset(x: w - side * 0.78, y: -h * 0.18)
                    Circle().fill(style.sage).frame(width: h * 0.62, height: h * 0.62).offset(x: w * 0.50, y: h * 0.40)
                    YohakuLineArt(drawing: drawing)
                        .stroke(style.navy, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .frame(width: h * 0.40, height: h * 0.36)
                        .offset(x: w * 0.50 + h * 0.11, y: h * 0.40 + h * 0.12)
                case .blockLeft:
                    Rectangle().fill(style.sage).frame(width: w * 0.30, height: h).offset(x: w * 0.46)
                    YohakuLineArt(drawing: drawing)
                        .stroke(style.navy, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .frame(width: w * 0.22, height: h * 0.55)
                        .offset(x: w * 0.50, y: h * 0.22)
                    Circle().fill(style.navy).frame(width: h * 0.56, height: h * 0.56).offset(x: w - h * 0.56 - 16, y: h * 0.10)
                    Rectangle().fill(style.navy).frame(width: w * 0.24 - 16, height: 1).offset(x: w * 0.76, y: h - 1)
                }
                Circle().strokeBorder(style.navy, lineWidth: 1).frame(width: 12, height: 12).offset(x: w - 30, y: h - 20)
            }
            .frame(width: w, height: h, alignment: .topLeading)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The Yohaku screen header: a running head with a navy rule (and the screen's
/// buttons), then the composition band with a large title.
struct YohakuHeader<Trailing: View>: View {
    let style: ReaderStyle
    let index: String
    let title: String
    let latin: String
    var detail: String? = nil
    var layout: YohakuComposition.Layout = .circleRight
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
            ZStack(alignment: .bottomLeading) {
                YohakuComposition(style: style, layout: layout, drawing: drawing)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(YohakuFont.title(46))
                        .tracking(-1)
                        .foregroundStyle(style.navy)
                        .accessibilityAddTraits(.isHeader)
                    Text(detail.map { "\(latin) · \($0)" } ?? latin)
                        .font(.custom(YohakuFont.latin, size: 12.5))
                        .foregroundStyle(style.secondary)
                }
                .padding(.leading, 16)
                .padding(.bottom, 12)
            }
            .frame(height: height)
        }
    }
}

// MARK: - Tab bar

enum YohakuIcons {
    enum Kind: Int { case read = 0, search, library, grammar }
    private static var cache: [String: UIImage] = [:]

    /// Geometric 1.5-stroke line icons; the selected one carries a 6px navy square above.
    static func image(_ kind: Kind, selected: Bool) -> UIImage {
        let key = "\(kind.rawValue)-\(selected)"
        if let cached = cache[key] { return cached }
        let size = CGSize(width: 26, height: 34)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            UIColor.black.setStroke()
            UIColor.black.setFill()
            cg.setLineWidth(1.5)
            cg.setLineCap(.square)
            cg.setLineJoin(.miter)
            if selected { cg.fill(CGRect(x: 10, y: 0, width: 6, height: 6)) }
            cg.translateBy(x: 1, y: 10)
            switch kind {
            case .read:
                cg.stroke(CGRect(x: 4.5, y: 3.5, width: 15, height: 17))
                cg.move(to: CGPoint(x: 8, y: 9)); cg.addLine(to: CGPoint(x: 16, y: 9))
                cg.move(to: CGPoint(x: 8, y: 13)); cg.addLine(to: CGPoint(x: 16, y: 13))
                cg.move(to: CGPoint(x: 8, y: 17)); cg.addLine(to: CGPoint(x: 12.5, y: 17))
                cg.strokePath()
            case .search:
                cg.strokeEllipse(in: CGRect(x: 4.5, y: 4.5, width: 12, height: 12))
                cg.move(to: CGPoint(x: 15, y: 15)); cg.addLine(to: CGPoint(x: 20, y: 20))
                cg.strokePath()
            case .library:
                cg.move(to: CGPoint(x: 5.5, y: 4.5)); cg.addLine(to: CGPoint(x: 5.5, y: 19.5))
                cg.move(to: CGPoint(x: 10.5, y: 4.5)); cg.addLine(to: CGPoint(x: 10.5, y: 19.5))
                cg.move(to: CGPoint(x: 14.5, y: 5.5)); cg.addLine(to: CGPoint(x: 18.5, y: 19.5))
                cg.move(to: CGPoint(x: 3.5, y: 19.5)); cg.addLine(to: CGPoint(x: 20.5, y: 19.5))
                cg.strokePath()
            case .grammar:
                cg.strokeEllipse(in: CGRect(x: 4.5, y: 4.5, width: 15, height: 15))
                cg.move(to: CGPoint(x: 8.5, y: 12)); cg.addLine(to: CGPoint(x: 15.5, y: 12))
                cg.strokePath()
            }
        }.withRenderingMode(.alwaysTemplate)
        cache[key] = image
        return image
    }
}

/// UIKit bar styling SwiftUI has no modifiers for: the 1px navy top line of the tab
/// bar, Zen Kaku labels and the navy navigation-bar title.
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
            tab.shadowImage = nil
            for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
                item.normal.iconColor = muted
                item.normal.titleTextAttributes = [.font: YohakuFont.uiFont(YohakuFont.gothic, 10.5), .foregroundColor: muted, .kern: 0.8]
                item.selected.iconColor = navy
                item.selected.titleTextAttributes = [.font: YohakuFont.uiFont(YohakuFont.gothicBold, 10.5), .foregroundColor: navy, .kern: 0.8]
            }
            nav.shadowColor = navy
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

    /// Dictionary pages: cream paper, Mincho headwords and examples, Zen Kaku
    /// definitions, Hanken sense numbers, muted labels and navy hairlines. Written
    /// with a high specificity so it also wins over the per-dictionary Washi overlays.
    static let dictionaryCSS = #"""
:root{
 --e-bg:#F2EEE3;--e-fg:#1A1A18;--e-muted:#58687A;--e-link:#1C2B3F;--e-strong:#1C2B3F;--e-border:rgba(28,43,63,.28);
 --e-ex:#1A1A18;--e-head:#1A1A18;--e-num:#1C2B3F;--e-sel:rgba(28,43,63,.18);
 --e-serif:"YMincho","Hiragino Mincho ProN",serif;--e-sans:"YGothic","Hiragino Sans",sans-serif;--e-font:var(--e-sans);
 --y-navy:#1C2B3F;--y-sage:#A9B7A0;--y-muted:#58687A;--y-latin:"YLatin","Helvetica Neue",sans-serif;
 color-scheme:light;
}
html:root body{font-family:var(--e-sans)!important;line-height:1.75!important}
html:root:not(#y) body .dictionary-source{font:700 10.5px/1.5 var(--y-latin)!important;letter-spacing:.18em!important;color:var(--y-muted)!important;
 border-bottom:1px solid var(--y-navy)!important;padding-bottom:8px!important;margin-bottom:18px!important}
html:root:not(#y) body .dictionary-source::before{width:6px!important;height:6px!important;border-radius:0!important;background:var(--y-navy)!important;transform:none!important}
/* Headwords: very large Mincho. */
html:root:not(#y):not(#w) body :is(.HeadG .headword,.hw_midashi,.item_midashi .midashi,.midashi_kana,.titlekana,.dc-headword,.headword_kana,.mjrhsjcd-entry .word,.kanji01,headword,h3,.head>.かな,.headword>.reading,.midashi){
 font-family:"YMincho","Hiragino Mincho ProN",serif!important;font-weight:800!important;font-size:2.35em!important;line-height:1.15!important;letter-spacing:0!important;color:var(--e-fg)!important}
html:root:not(#y):not(#w) body :is(.headword.表記,.m_hyoki,.hyouki_g,.headword_kanji,black_branckets,.hyouki_g *,.headword:not(.表記)~.headword){
 font-family:"YMincho","Hiragino Mincho ProN",serif!important;font-weight:500!important;font-size:1.25em!important;color:var(--y-navy)!important}
html:root:not(#y):not(#w) body :is(.midashi_pri3,.midashi_pri2,.midashi_pri1,.koumoku>.midashi,.HeadG,.item_midashi,div.head:has(>h),.dc-entry>.midashi,.mjrhsjcd-entry>.head,.tkbt-entry>.head,.dic_item>.head){
 border-bottom:1px solid var(--y-navy)!important;padding-bottom:.45em!important;margin-bottom:.8em!important}
html:root:not(#y) body .headword_eng{font-family:var(--y-latin)!important;font-style:normal!important;font-weight:600!important;color:var(--y-muted)!important}
/* Sense numbers: large thin Hanken numerals. */
html:root:not(#y):not(#w) body :is(.num,.wc,.dc-sense,.sense_no,.gogi>.num,.MeaningG .Num,.snum,.hukugi_num){
 font-family:var(--y-latin)!important;font-weight:300!important;font-size:1.55em!important;line-height:1!important;color:var(--y-navy)!important;margin-right:.35em!important;vertical-align:-.12em}
/* Labels: muted, small, square tags. */
html:root:not(#y):not(#w) body :is(.slabel,.label,.naihou,.note_div,.shironuki,.daikubun,.gogikubun,.tkbt-label,.type,.kg_eiyaku,.shiyouiki,.senmon_g,.white-square,.hinshi,.bunya,.yoho,.gram){
 font-family:var(--e-sans)!important;color:var(--y-muted)!important;border-radius:0!important;background:transparent!important}
html:root:not(#y):not(#w) body :is(.tkbt-label,.white-square,.hinshi,.shiyouiki,.senmon_g,.mjrhsjcd-entry .type){border:1px solid var(--y-muted)!important;padding:0 .4em!important}
html:root:not(#y):not(#w) body :is(.tyuuki_rogo,.kaiwa_rogo,.kakomi_4_title_rogo,.tyuuki_kanren_rogo){background:var(--y-sage)!important;color:var(--y-navy)!important;border-radius:0!important}
/* Translations / definitions. */
html:root:not(#y):not(#w) body :is(.eng,.mean_yakugo,.yakugo,.dfcn,.meaning,.def1){color:var(--e-fg)!important}
/* Examples: Mincho, ink; translation muted, smaller. */
html:root:not(#y):not(#w) body :is(.用例,.scope_exam_jp,.reibun,span.mean_yorei,.exjp,.ex_boby,.example_jp,jae,li.example-ja){
 font-family:"YMincho","Hiragino Mincho ProN",serif!important;font-weight:500!important;color:var(--e-fg)!important}
html:root:not(#y):not(#w) body :is(.用例訳,.scope_exam_en,.yakubun_g,.reiyaku_box,.excn,.exen,.ex_trans,.example_en,ja_cn,li.example-en){color:var(--y-muted)!important}
html:root:not(#y):not(#w) body :is(.yoorei,.MeaningG>.example,div.mean_yorei,.dic_item div.example,.exam,.examples>li.example-ja){
 border-left:0!important;padding-left:0!important;margin-left:calc(var(--e-size) * 1.2)!important}
html:root:not(#y) body :is(.用例,.reibun,.exjp,jae) :is(b,strong,.bi){color:var(--y-navy)!important;font-weight:800!important;text-decoration:underline!important;text-decoration-thickness:1px!important;text-underline-offset:5px!important}
/* Hairlines between blocks. */
html:root:not(#y) body hr{border-top:1px solid var(--y-navy)!important}
html:root:not(#y):not(#w) body :is(.hukugou_g,.kouzougi,.SubItem,.ComplexG){border-top:1px solid var(--y-navy)!important;padding-top:.7em!important}
html:root:not(#y):not(#w) body :is(.hukugou_seiku,.kouzouhyouki,.subheadword,.ComplexH){font-family:"YMincho","Hiragino Mincho ProN",serif!important;font-weight:800!important;color:var(--y-navy)!important}
html:root:not(#y):not(#w) body :is(.hukugou_seiku,.kouzouhyouki,.subheadword,.ComplexH)::before{border-radius:0!important;background:var(--y-navy)!important;transform:none!important;width:.4em!important;height:.4em!important}
html:root:not(#y):not(#w) body :is(fieldset.kakomi_4_box,.kaiwa,.box,.note,.chuui){border-radius:0!important;border-style:solid!important;border-color:rgba(28,43,63,.28)!important;background:transparent!important}
html:root body img{border-radius:0!important}
html:root body mark.jp-hit{border-radius:0!important;background:rgba(169,183,160,.45)!important;box-shadow:none!important}
html:root body details.import-source{border-radius:0!important;border-color:var(--y-navy)!important}
html:root body :is(con_table>accent){border-radius:0!important}
"""#

    /// Grammar lessons: a sage header block with a pen drawing and a navy level
    /// circle, a large Mincho pattern, and each section (意思 / 接續 / 例句 / 類義 …)
    /// as a two-column row with its label on the left, separated by navy hairlines.
    static let grammarCSS = #"""
:root{
 --g-title:"YGothic","Hiragino Sans","PingFang TC",sans-serif;--g-zh:"YGothic","PingFang TC","Hiragino Sans",sans-serif;
 --g-jp:"YMincho","Hiragino Mincho ProN","Songti TC",serif;--y-latin:"YLatin","Helvetica Neue",sans-serif;
 --y-navy:#1C2B3F;--y-sage:#A9B7A0;--y-muted:#58687A;--y-hair:rgba(28,43,63,.22);
 --g-shade:transparent;--g-wobble:0;--g-wobble2:0;
}
body{padding-top:0}
rt{color:var(--y-muted)}
::selection{background:rgba(28,43,63,.18)}
a{color:var(--y-navy)}
header.h{position:relative;margin:0 0 6px;padding:178px 0 14px}
header.h::before{content:"";position:absolute;left:calc(-1 * var(--g-pad));top:0;width:72%;height:152px;background-color:var(--y-sage);
 background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 145 100' fill='none' stroke='%231C2B3F' stroke-width='1.7' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M10 80C30 78.4 40 60 54 62C70 64.4 66 86.4 52 84.2C38 82 44.4 54 70 50.2C96 46.4 100.4 70 117 60.6'/%3E%3Cpath d='M117.6 58.6L133.4 18.4C135.8 12.2 142.2 14.6 140 20.6L124.4 60.4L116 66.4Z'/%3E%3Cpath d='M128.4 31.4L136.2 34.2'/%3E%3C/svg%3E");
 background-repeat:no-repeat;background-position:46% 62%;background-size:58% auto}
header.h::after{content:"";position:absolute;left:calc(72% - var(--g-pad));right:calc(-1 * var(--g-pad));top:151px;bottom:auto;height:1px;background:var(--y-navy);-webkit-mask:none;mask:none}
.badge{position:absolute;right:0;top:14px;width:64px;height:64px;padding:0;border-radius:50%;display:flex;align-items:center;justify-content:center;
 background:var(--y-navy);color:#F2EEE3;font:700 20px/1 var(--y-latin);letter-spacing:0;transform:none;box-shadow:none}
h1{font:800 2.25em/1.18 var(--g-jp);margin:0 0 .3em;letter-spacing:0;color:var(--g-ink)}
h1 rt{font-family:var(--g-zh)}
.hsub{color:var(--g-ink);font-size:.95em;font-weight:700;line-height:1.6}
.revision-note{background:var(--y-sage)!important;color:var(--y-navy)!important;border-radius:0!important;font-family:var(--g-zh)!important}
body{counter-reset:ysec}
section{counter-increment:ysec;display:grid;grid-template-columns:72px minmax(0,1fr);column-gap:6px;margin:0;padding:14px 0;border-top:1px solid var(--y-navy)}
section:last-of-type{border-bottom:1px solid var(--y-navy)}
section>h2,h2{grid-column:1;grid-row:1 / span 40;display:block;margin:0;padding:0;background:none;font:700 .8em/1.45 var(--g-zh);letter-spacing:.06em;color:var(--y-navy)}
section>h2::before{content:counter(ysec,decimal-leading-zero);display:block;font:700 11px/1.6 var(--y-latin);letter-spacing:.06em;color:var(--y-muted)}
h2 small{display:block;margin:3px 0 0;background:none;font:400 .78em/1.4 var(--g-zh);color:var(--y-muted);letter-spacing:0}
section>*:not(h2){grid-column:2;min-width:0}
h2+*{margin-top:0}
.box,.cmp,.q,.ex,.setsu{background:transparent;border:0;border-radius:0;box-shadow:none;padding:0}
.box{margin-bottom:.6em}
.box:last-child{margin-bottom:0}
section:first-of-type .box::before{display:none}
.ety{background:transparent;border:0;border-top:1px solid var(--y-hair);border-radius:0;padding:8px 0 0;margin-top:10px}
.setsu{font-family:var(--g-zh);font-size:.95em;line-height:1.9}
.setsu b{display:inline-block;margin:2px 0;padding:1px 10px;border:1px solid var(--y-navy);font:800 1.05em/1.6 var(--g-jp);color:var(--y-navy)}
.ex{margin:0 0 10px;padding:0 0 10px;border-bottom:1px solid var(--y-hair)}
.ex:last-child{margin-bottom:0;padding-bottom:0;border-bottom:0}
.ex::after{display:none}
.reg{background:var(--y-sage);color:var(--y-navy);border-radius:0;transform:none;font:700 .64em/1.9 var(--g-zh);padding:0 8px}
.jp{font-family:var(--g-jp);font-weight:500;font-size:1.06em;line-height:2.1}
.zh{color:var(--y-muted)}
.note-l{color:var(--y-navy)}
mark{background:none;color:var(--y-navy);font-weight:800;border-radius:0;text-decoration:underline;text-decoration-thickness:1px;text-underline-offset:5px}
.cmp{margin-bottom:12px}
.cmp .vs{border:1px solid var(--y-navy);border-radius:0;color:var(--y-navy);background:transparent;font-family:var(--y-latin)}
.cmp h3{font:800 1.05em/1.5 var(--g-jp);color:var(--y-navy)}
.cmp .pt b,.swap b{color:var(--y-navy)}
.swap{background:#FAF8F2;border:0;border-radius:0;padding:8px 10px}
.chip{border:1px solid var(--y-navy);border-radius:0;box-shadow:none;background:transparent;font-family:var(--g-jp)}
li::marker{color:var(--y-navy)}
.q{margin-bottom:12px}
details{background:transparent;border:1px solid var(--y-navy);border-radius:0}
details[open]{background:#FAF8F2}
summary{font-family:var(--g-zh);color:var(--y-navy)}
summary::before{content:"→ "}
td,th{border-color:var(--y-hair)}
footer{border-top:1px solid var(--y-navy);font:700 10px/1.6 var(--y-latin);letter-spacing:.16em;color:var(--y-muted)}
"""#
}

// MARK: - SwiftUI helpers

/// The search field: a surface pill normally; in Yohaku just a 1.5px navy underline.
struct SearchFieldChrome: ViewModifier {
    let style: ReaderStyle
    func body(content: Content) -> some View {
        if style.isYohaku {
            content.overlay(alignment: .bottom) { Rectangle().fill(style.navy).frame(height: 1.5).allowsHitTesting(false) }
        } else {
            content
                .background(style.surface, in: SketchShape(radius: 16))
                .overlay(SketchShape(radius: 16).stroke(style.lineStrong, lineWidth: 1.5))
                .background(SketchShape(radius: 16).fill(style.shade).offset(x: 3, y: 4))
        }
    }
}

/// Lists in Yohaku: no rounded groups, navy hairlines between rows.
struct YohakuList: ViewModifier {
    let style: ReaderStyle
    func body(content: Content) -> some View {
        if style.isYohaku {
            content.listStyle(.plain).listRowSeparatorTint(style.navy)
        } else {
            content
        }
    }
}
