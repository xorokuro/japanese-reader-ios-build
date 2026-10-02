import SwiftUI

// Relative luminance in linear sRGB. Use the higher-contrast black/white ink.
enum Palette {
    static func channels(_ rgb: Int) -> [Double] {
        [Double((rgb >> 16) & 255) / 255, Double((rgb >> 8) & 255) / 255, Double(rgb & 255) / 255]
    }
    static func luminance(_ c: [Double]) -> Double {
        let linear = c.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }
    static func color(_ rgb: Int) -> Color {
        let c = channels(rgb)
        return Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: 1)
    }
    static func ink(_ rgb: Int) -> Color {
        let l = luminance(channels(rgb))
        return (l + 0.05) / 0.05 >= 1.05 / (l + 0.05) ? .black : .white
    }
    static func rgb(_ color: Color) -> Int {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Int((r * 255).rounded()) << 16) | (Int((g * 255).rounded()) << 8) | Int((b * 255).rounded())
    }
    static func accessibleAccent(_ rgb: Int, dark: Bool, backgroundRGB: Int? = nil) -> Color {
        var c = channels(rgb)
        // Check against white in light mode and a raised dark surface (#2C2C2E)
        // in dark mode, so accent text remains readable on system surfaces.
        let background = backgroundRGB.map { luminance(channels($0)) } ?? (dark ? luminance(channels(0x2C2C2E)) : 1)
        for _ in 0..<100 {
            let l = luminance(c)
            if (max(l, background) + 0.05) / (min(l, background) + 0.05) >= 4.8 { break }
            c = c.map { dark ? $0 + (1 - $0) * 0.08 : $0 * 0.92 }
        }
        return Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: 1)
    }

    // MARK: - Appearance helpers (iOS only)

    /// A surface is treated as dark below the midpoint used by the reading views.
    static func isDark(_ rgb: Int) -> Bool { luminance(channels(rgb)) < 0.179 }

    static func contrast(_ first: Int, _ second: Int) -> Double {
        let a = luminance(channels(first)), b = luminance(channels(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func hexString(_ rgb: Int) -> String { String(format: "#%06X", rgb & 0xFFFFFF) }

    /// Linear blend between two packed colors. `amount` 0 keeps `base`.
    static func mix(_ base: Int, toward target: Int, _ amount: Double) -> Int {
        let a = channels(base), b = channels(target), t = min(max(amount, 0), 1)
        let parts = (0..<3).map { Int((((a[$0] + (b[$0] - a[$0]) * t)) * 255).rounded()) }
        return (parts[0] << 16) | (parts[1] << 8) | parts[2]
    }

    /// One step away from a background, toward its own ink. Used to derive a card
    /// surface for a user-chosen background color.
    static func raised(_ rgb: Int, _ amount: Double = 0.06) -> Int {
        mix(rgb, toward: isDark(rgb) ? 0xFFFFFF : 0x000000, amount)
    }

    /// The surface an accent has to survive on: whichever of the two is closest in
    /// luminance, because that is the pairing with the least contrast.
    static func hardestSurface(_ first: Int, _ second: Int, accent: Int) -> Int {
        let target = luminance(channels(accent))
        let a = abs(luminance(channels(first)) - target)
        let b = abs(luminance(channels(second)) - target)
        return a <= b ? first : second
    }
}

// MARK: - Themes

/// A named iOS appearance. Desktop styling is unaffected: nothing here is shared
/// with the Windows reader, which keeps its own CSS palette engine.
struct ReaderTheme: Identifiable, Equatable, Hashable {
    /// How the interface is drawn: the hand-drawn Washi look, or the flat
    /// editorial 余白 Yohaku look (square corners, hairlines, geometric headers).
    /// `fable` is the Claude "drawn from the inside" look: Yohaku's flat layouts with
    /// fine ink hairlines, handwritten lowercase captions, a wandering thread and a
    /// thick hand-wound ring (see Fable.swift).
    enum Design: String { case washi, yohaku, fable }
    enum Family: String, CaseIterable, Identifiable {
        case system, light, dark, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return "Automatic"
            case .light: return "Light"
            case .dark: return "Dark"
            case .custom: return "Custom"
            }
        }
    }

    let id: String
    let name: String
    let detail: String
    let family: Family
    /// `nil` means "use the iOS system surfaces and follow Light/Dark".
    let backgroundRGB: Int?
    let surfaceRGB: Int?
    let accentRGB: Int
    /// Washi-tape and highlighter colours (the desktop's accent-2 / accent-3).
    var tapeRGB: Int? = nil
    var markerRGB: Int? = nil
    /// A warm reading ink; `nil` uses plain black or white.
    var inkRGB: Int? = nil
    var design: Design = .washi
    /// Yohaku: secondary text colour (Muted) and the highlight accent
    /// (keywords in examples, the pitch-accent line, source tags).
    var mutedRGB: Int? = nil
    var highlightRGB: Int? = nil
    /// Fable: which set of drawings, page decoration and fills the theme uses.
    var motif: FableMotif = .film

    static let systemID = "system"
    static let customID = "custom"

    static let system = ReaderTheme(
        id: systemID, name: "System", detail: "Follows iPhone Light / Dark",
        family: .system, backgroundRGB: nil, surfaceRGB: nil, accentRGB: 0x1F7A73)

    static let custom = ReaderTheme(
        id: customID, name: "Custom", detail: "Your own accent and background",
        family: .custom, backgroundRGB: nil, surfaceRGB: nil, accentRGB: 0x1F7A73)

    /// The eight palettes of the desktop reader, with the same paper, card, ink,
    /// accent, tape and highlighter colours.
    static let desk: [ReaderTheme] = [
        ReaderTheme(id: "hand-washi", name: "和紙 Washi", detail: "Desktop default · paper and persimmon",
                    family: .light, backgroundRGB: 0xF3EADB, surfaceRGB: 0xFFFAF1, accentRGB: 0xC9573A,
                    tapeRGB: 0x6E9A5B, markerRGB: 0xD6A03E, inkRGB: 0x3B2F28),
        ReaderTheme(id: "hand-sakura", name: "桜 Sakura", detail: "Desktop · blossom pink",
                    family: .light, backgroundRGB: 0xF8E8EC, surfaceRGB: 0xFFFAFB, accentRGB: 0xD2557A,
                    tapeRGB: 0x6F9DC9, markerRGB: 0xE39B45, inkRGB: 0x4A2F3A),
        ReaderTheme(id: "hand-umi", name: "海辺 Seaside", detail: "Desktop · sea glass",
                    family: .light, backgroundRGB: 0xE4EEF1, surfaceRGB: 0xFBFDFD, accentRGB: 0x237EA1,
                    tapeRGB: 0xE0704F, markerRGB: 0xD9A93D, inkRGB: 0x203B48),
        ReaderTheme(id: "hand-sumi", name: "墨 Sumi ink", detail: "Desktop · ink and seal red",
                    family: .light, backgroundRGB: 0xEFECE5, surfaceRGB: 0xFCFBF7, accentRGB: 0xB0392E,
                    tapeRGB: 0x4F5B57, markerRGB: 0x9A8B73, inkRGB: 0x262422),
        ReaderTheme(id: "hand-matcha", name: "抹茶 Matcha night", detail: "Desktop · deep tea green",
                    family: .dark, backgroundRGB: 0x1B2520, surfaceRGB: 0x243029, accentRGB: 0xA6D08A,
                    tapeRGB: 0xF0CD8A, markerRGB: 0xE89D8A, inkRGB: 0xEDF2E4),
        ReaderTheme(id: "hand-engawa", name: "夜の縁側 Lantern night", detail: "Desktop · lantern glow",
                    family: .dark, backgroundRGB: 0x211C29, surfaceRGB: 0x2C2535, accentRGB: 0xF1B15A,
                    tapeRGB: 0xE98AA6, markerRGB: 0x9CC6E6, inkRGB: 0xF4E9DC),
        ReaderTheme(id: "hand-momiji", name: "紅葉 Autumn leaves", detail: "Desktop · maple embers",
                    family: .dark, backgroundRGB: 0x29201B, surfaceRGB: 0x352822, accentRGB: 0xF08B4C,
                    tapeRGB: 0xE9C46A, markerRGB: 0xB7D07B, inkRGB: 0xF7E9D8),
        ReaderTheme(id: "hand-hoshi", name: "星空 Starry sky", detail: "Desktop · starlit indigo",
                    family: .dark, backgroundRGB: 0x141A2D, surfaceRGB: 0x1D253F, accentRGB: 0xFFD27A,
                    tapeRGB: 0x9FD0FF, markerRGB: 0xF5A0C2, inkRGB: 0xE9EDFF)
    ]

    /// 余白 Yohaku papers. `accentRGB` is the line / title colour (rules, buttons,
    /// active states); `highlightRGB` is the warm accent; sage fills small shapes.
    private static func paper(_ id: String, _ name: String, _ detail: String, family: Family = .light,
                              paper: Int, ink: Int, lines: Int, muted: Int, accent: Int) -> ReaderTheme {
        ReaderTheme(id: id, name: name, detail: detail, family: family, backgroundRGB: paper, surfaceRGB: paper,
                    accentRGB: lines, tapeRGB: 0xB4C0AA, markerRGB: 0xB4C0AA, inkRGB: ink,
                    design: .yohaku, mutedRGB: muted, highlightRGB: accent)
    }
    static let yohaku = paper("yohaku", "余白 生成 Kinari", "Editorial · unbleached paper",
                              paper: 0xECE3CC, ink: 0x1A1A18, lines: 0x1C2B3F, muted: 0x5A5F66, accent: 0x7A3B2B)

    static let editorial: [ReaderTheme] = [
        yohaku,
        paper("yohaku-washi", "余白 和紙 Washi white", "Editorial · white washi",
              paper: 0xF3F0E8, ink: 0x1A1A18, lines: 0x22303F, muted: 0x5F646A, accent: 0x4F6578),
        paper("yohaku-seiji", "余白 青磁 Celadon", "Editorial · celadon green",
              paper: 0xDDE3D7, ink: 0x1B1F1C, lines: 0x1F3A3A, muted: 0x526058, accent: 0x7A5A2E),
        paper("yohaku-kiri", "余白 霧 Fog blue", "Editorial · fog blue",
              paper: 0xDCE1E4, ink: 0x181C21, lines: 0x1C2B3F, muted: 0x53606C, accent: 0x8A4B3A),
        paper("yohaku-wara", "余白 藁半紙 Newsprint", "Editorial · 1980 newsprint",
              paper: 0xE2D6B6, ink: 0x26221C, lines: 0x2A2620, muted: 0x5E574A, accent: 0x2F5D73),
        paper("yohaku-sumi", "余白 墨夜 Sumi night", "Editorial · dark", family: .dark,
              paper: 0x25292D, ink: 0xE9E2D0, lines: 0xE9E2D0, muted: 0xA7A396, accent: 0xD2A955)
    ]

    /// 糸 Fable papers (the Claude style): `accentRGB` is the ink line colour,
    /// `highlightRGB` the small spark, `tapeRGB` the soft "chosen" wash and
    /// `markerRGB` the motif's own colour (thread, grid, rays, moon, wash…).
    private static func fablePaper(_ id: String, _ name: String, _ detail: String, family: Family = .light,
                                   motif: FableMotif = .film,
                                   paper: Int, ink: Int, lines: Int, muted: Int, spark: Int, sage: Int, thread: Int) -> ReaderTheme {
        ReaderTheme(id: id, name: name, detail: detail, family: family, backgroundRGB: paper, surfaceRGB: paper,
                    accentRGB: lines, tapeRGB: sage, markerRGB: thread, inkRGB: ink,
                    design: .fable, mutedRGB: muted, highlightRGB: spark, motif: motif)
    }
    static let fable: [ReaderTheme] = [
        // The film itself: drawn from the inside.
        fablePaper("fable", "糸 Fable · Paper", "The film · cream paper, wound ring, thread",
                   paper: 0xF5F0E4, ink: 0x2B2925, lines: 0x34322D, muted: 0x6E695F, spark: 0xB04A3C, sage: 0xDDE2CE, thread: 0xB89A6A),
        fablePaper("fable-sage", "糸 Fable · Meadow", "The film · pale sage",
                   paper: 0xDDE2CE, ink: 0x22251E, lines: 0x2C3328, muted: 0x5A6152, spark: 0xA0453A, sage: 0xC6CFB4, thread: 0x9C8456),
        fablePaper("fable-blush", "糸 Fable · Blossom", "The film · dusty pink",
                   paper: 0xEAD9CF, ink: 0x2C2421, lines: 0x3D3330, muted: 0x6E5E58, spark: 0x9E3F35, sage: 0xDDE2CE, thread: 0xA88A5E),
        fablePaper("fable-dusk", "糸 Fable · Unfinished", "The film · warm grey",
                   paper: 0xD6D2C7, ink: 0x22211D, lines: 0x2E2C28, muted: 0x58544C, spark: 0x973F33, sage: 0xC3C8B4, thread: 0x96804F),
        fablePaper("fable-night", "糸 Fable · One water", "The film · night, stars", family: .dark,
                   paper: 0x211F1B, ink: 0xEDE6D6, lines: 0xE6DFCE, muted: 0xA59E8E, spark: 0xE39A7E, sage: 0x3A3F34, thread: 0xC9A46A),
        // Variations of my own, after Kengo Works.
        fablePaper("fable-graph", "方眼 Cool S", "Graph-paper notebook, coloured-pencil doodles", motif: .graph,
                   paper: 0xF4F2E8, ink: 0x2C2D2A, lines: 0x35362F, muted: 0x63665D, spark: 0xC24E6E, sage: 0xF3E592, thread: 0x8EB5A9),
        fablePaper("fable-sundown", "残照 Sundown", "Linocut sun, ochre rays, burnt orange", motif: .sundown,
                   paper: 0xF3E7CC, ink: 0x3A2618, lines: 0x47301F, muted: 0x76604B, spark: 0xC0582A, sage: 0xEDD39A, thread: 0xD3A040),
        fablePaper("fable-midnight", "月 Borrowed light", "A small moon keeps a lit window company", family: .dark, motif: .midnight,
                   paper: 0x1B2033, ink: 0xEFE7D3, lines: 0xE7DEC9, muted: 0xA1A6B8, spark: 0xF2C46B, sage: 0x343B57, thread: 0xF1E2AE),
        fablePaper("fable-mist", "雨 Underlight", "Watercolour rain, a pole and its wires", motif: .mist,
                   paper: 0xE4E8E2, ink: 0x1E2933, lines: 0x293742, muted: 0x56636E, spark: 0xB9503C, sage: 0xCAD5E0, thread: 0x6F8CB0),
        fablePaper("fable-ballpoint", "ボールペン Ballpoint", "Blue biro on paper, red-pen marks", motif: .ballpoint,
                   paper: 0xF2EAD8, ink: 0x1D2C66, lines: 0x24367A, muted: 0x5A6386, spark: 0xB8352E, sage: 0xDCE1F2, thread: 0xB8352E),
        fablePaper("fable-echo", "応 Echo", "A dot calls out; rings and small worlds answer", motif: .echo,
                   paper: 0xF6F0DA, ink: 0x1F2130, lines: 0x272A3B, muted: 0x60616F, spark: 0xD04A2F, sage: 0xF1DD8E, thread: 0xE2C24C),
        fablePaper("fable-roots", "根 Roots", "White roots on slate, one red line", family: .dark, motif: .roots,
                   paper: 0x1E2328, ink: 0xECE8DE, lines: 0xE3DED2, muted: 0x9BA3A8, spark: 0xD9584A, sage: 0x323C45, thread: 0xD8D2C4),
        fablePaper("fable-evening", "夕 Evening", "Watercolour dusk, a pylon and its wires", motif: .evening,
                   paper: 0xF2E7E6, ink: 0x2B2340, lines: 0x382E52, muted: 0x6A5F7A, spark: 0xD46A3A, sage: 0xE6D4E8, thread: 0x8D76C2),
        // 自画像 Self-portraits: the same figure, a different craft each time.
        fablePaper("fable-still", "刺し子 Still", "Indigo cloth, running stitches, a figure in gold", family: .dark, motif: .sashiko,
                   paper: 0x1F2947, ink: 0xEEE7D3, lines: 0xE5DDC6, muted: 0xA0A7BE, spark: 0xE0B54E, sage: 0x35416B, thread: 0xD9D2BC),
        fablePaper("fable-ebru", "墨流し Ebru", "Marbled stones in navy and gold", motif: .ebru,
                   paper: 0xF3EDDD, ink: 0x1F2A5C, lines: 0x26336B, muted: 0x5C6486, spark: 0xC0902E, sage: 0xEBDCA8, thread: 0x24306B),
        fablePaper("fable-cyanotype", "青写真 Cyanotype", "White sprigs on blue", motif: .cyanotype,
                   paper: 0xF2EEE0, ink: 0x21367C, lines: 0x2B4594, muted: 0x5F6C96, spark: 0xBF553B, sage: 0xD6DFF3, thread: 0x3554A8),
        fablePaper("fable-transit", "路線図 Transit", "A route map and a figure in stripes", motif: .transit,
                   paper: 0xE9F0EA, ink: 0x1F2A2E, lines: 0x2A373C, muted: 0x5A676B, spark: 0xD8492F, sage: 0xF3DD98, thread: 0x2F6FB3),
        fablePaper("fable-oneline", "一筆 One line", "Mustard ground, one wandering line", motif: .oneline,
                   paper: 0xF4ECD6, ink: 0x241E12, lines: 0x2E2616, muted: 0x6B604A, spark: 0xB5701F, sage: 0xEFCF83, thread: 0xD9A036),
        fablePaper("fable-phool", "花 Phool patti", "Truck-art green, yellow figure, red flowers", family: .dark, motif: .phool,
                   paper: 0x21402C, ink: 0xF3EAD0, lines: 0xEFE3C2, muted: 0xAABDA7, spark: 0xF0B43A, sage: 0x36593F, thread: 0xD9483B),
        fablePaper("fable-doublure", "見返し Doublure", "Gold-tooled leather", family: .dark, motif: .doublure,
                   paper: 0x25170F, ink: 0xEFE2C4, lines: 0xDDBD6C, muted: 0xAB987C, spark: 0xE3C26A, sage: 0x3F2B1D, thread: 0xC9A24B)
    ]

    /// The five papers of the film, and the variations after Kengo Works.
    static var fableFilm: [ReaderTheme] { fable.filter { $0.motif == .film } }
    static var fableVariations: [ReaderTheme] { fable.filter { $0.motif != .film && (!$0.motif.isPortrait || $0.motif == .evening) } }
    static var fablePortraits: [ReaderTheme] { fable.filter { $0.motif.isPortrait && $0.motif != .evening } }

    static let all: [ReaderTheme] = {
        var themes: [ReaderTheme] = [system]
        themes.append(contentsOf: fable)
        themes.append(contentsOf: editorial)
        themes.append(contentsOf: desk)
        themes.append(custom)
        return themes
    }()

    static func named(_ id: String) -> ReaderTheme? { all.first { $0.id == id } }

    /// Upgrades keep working: an install that already chose a custom background
    /// resolves to the Custom theme until a preset is picked.
    static func resolve(_ id: String, hasCustomPaper: Bool) -> ReaderTheme {
        if let stored = named(id) { return stored }
        return hasCustomPaper ? custom : system
    }
}

/// Every color the iOS interface draws with, resolved once per render.
struct ReaderStyle: Equatable {
    let theme: ReaderTheme
    let isDark: Bool
    /// `nil` while the iOS system surfaces are in use.
    let backgroundRGB: Int?
    let surfaceRGB: Int?
    let accentRGB: Int
    let background: Color
    let surface: Color
    let raised: Color
    let ink: Color
    let accent: Color
    /// Readable text on top of a filled accent shape.
    let onAccent: Color
    /// Washi tape and highlighter-pen colours for the hand-drawn look.
    let tape: Color
    let marker: Color

    var usesSystemSurfaces: Bool { backgroundRGB == nil }
    /// The flat editorial 余白 look instead of the hand-drawn one.
    var isYohaku: Bool { theme.design == .yohaku || theme.design == .fable }
    /// The Claude "Fable" look (a refinement of Yohaku: everything Yohaku does, drawn finer).
    var isFable: Bool { theme.design == .fable }
    /// Fable: the wandering thread colour and the small rust spark.
    var thread: Color { marker }
    var spark: Color { highlight }
    /// Rules and outlines: full line colour in Yohaku, a quieter pencil grey in Fable.
    var rule: Color { isFable ? navy.opacity(isDark ? 0.40 : 0.36) : navy }
    /// Fable's "chosen" fill: a soft sage wash instead of a solid ink block.
    var chosen: Color { isFable ? sage.opacity(isDark ? 0.9 : 1) : navy }
    var onChosen: Color { isFable ? ink : background }
    /// Ruled notebook lines on the Read page.
    var paperRule: Color { isFable ? (theme.motif == .graph ? thread : secondary) : tape }
    /// Text on a selected chip: the theme ink on Fable's soft wash, onAccent elsewhere.
    var onPill: Color { isFable ? ink : onAccent }
    /// Yohaku navy: titles, rules, primary buttons, active states.
    var navy: Color { accent }
    var secondary: Color { isYohaku ? Palette.color(theme.mutedRGB ?? 0x58687A) : ink.opacity(0.62) }
    var faint: Color { isYohaku ? Palette.color(theme.mutedRGB ?? 0x58687A).opacity(0.75) : ink.opacity(0.42) }
    var hairline: Color { isYohaku ? accent.opacity(0.25) : ink.opacity(isDark ? 0.16 : 0.09) }
    var separator: Color { isYohaku ? accent : ink.opacity(isDark ? 0.12 : 0.07) }
    var accentSoft: Color { isYohaku ? accent.opacity(0.08) : accent.opacity(isDark ? 0.22 : 0.13) }
    var shadow: Color { isYohaku ? .clear : Color.black.opacity(isDark ? 0.40 : 0.08) }
    /// Card outline and the offset "pencil" line of hand-drawn cards.
    var lineStrong: Color { isYohaku ? accent : ink.opacity(isDark ? 0.24 : 0.26) }
    var pencil: Color { isYohaku ? .clear : ink.opacity(0.16) }
    /// The hard, offset shadow under sketched cards (desktop: 4px 6px 0 -1px).
    var shade: Color { isYohaku ? .clear : (isDark ? Color.black.opacity(0.34) : ink.opacity(0.14)) }
    /// Yohaku: sage for small flat fills, the warm highlight accent and muted text.
    var sage: Color { tape }
    var highlight: Color { Palette.color(theme.highlightRGB ?? accentRGB) }
    var mutedRGB: Int { theme.mutedRGB ?? 0x5A5F66 }
    /// Locks the interface to the theme's own mode; `nil` keeps following iOS.
    var colorScheme: ColorScheme? { usesSystemSurfaces ? nil : (isDark ? .dark : .light) }
    /// Identity for views that must be rebuilt when the palette changes.
    var identity: String { "\(theme.id)-\(backgroundRGB ?? -1)-\(accentRGB)-\(isDark)" }

    /// Views read the style many times per frame; resolving it (with its contrast
    /// search) once per combination keeps scrolling and typing smooth.
    private static var resolved: [String: ReaderStyle] = [:]
    static func resolve(themeID: String, customPaper: Bool, paperRGB: Int, customAccentRGB: Int, systemDark: Bool) -> ReaderStyle {
        let key = "\(themeID)|\(customPaper)|\(paperRGB)|\(customAccentRGB)|\(systemDark)"
        if let cached = resolved[key] {
            YohakuDesign.active = cached.isYohaku; YohakuDesign.fable = cached.isFable
            YohakuDesign.stitched = cached.isFable && cached.theme.motif == .sashiko
            YohakuDesign.style = cached.isYohaku ? cached : nil
            return cached
        }
        let style = compute(themeID: themeID, customPaper: customPaper, paperRGB: paperRGB,
                            customAccentRGB: customAccentRGB, systemDark: systemDark)
        if resolved.count > 64 { resolved.removeAll() }
        resolved[key] = style
        YohakuDesign.active = style.isYohaku
        YohakuDesign.fable = style.isFable
        YohakuDesign.stitched = style.isFable && style.theme.motif == .sashiko
        YohakuDesign.style = style.isYohaku ? style : nil
        return style
    }
    private static func compute(themeID: String, customPaper: Bool, paperRGB: Int, customAccentRGB: Int, systemDark: Bool) -> ReaderStyle {
        let theme = ReaderTheme.resolve(themeID, hasCustomPaper: customPaper)
        if theme.id == ReaderTheme.customID {
            guard customPaper else { return system(theme: theme, accentRGB: customAccentRGB, systemDark: systemDark) }
            return fixed(theme: theme, backgroundRGB: paperRGB, surfaceRGB: Palette.raised(paperRGB), accentRGB: customAccentRGB)
        }
        guard let background = theme.backgroundRGB else {
            return system(theme: theme, accentRGB: theme.accentRGB, systemDark: systemDark)
        }
        return fixed(theme: theme, backgroundRGB: background,
                     surfaceRGB: theme.surfaceRGB ?? Palette.raised(background), accentRGB: theme.accentRGB)
    }

    /// The resolved colours of any theme, without changing the active one (for swatches).
    static func preview(_ theme: ReaderTheme) -> ReaderStyle {
        let background = theme.backgroundRGB ?? 0xF5F0E4
        return fixed(theme: theme, backgroundRGB: background,
                     surfaceRGB: theme.surfaceRGB ?? Palette.raised(background), accentRGB: theme.accentRGB)
    }

    private static func system(theme: ReaderTheme, accentRGB: Int, systemDark: Bool) -> ReaderStyle {
        let accent = Palette.accessibleAccent(accentRGB, dark: systemDark)
        return ReaderStyle(
            theme: theme, isDark: systemDark, backgroundRGB: nil, surfaceRGB: nil, accentRGB: accentRGB,
            background: Color(uiColor: .systemGroupedBackground),
            surface: Color(uiColor: .secondarySystemGroupedBackground),
            raised: Color(uiColor: .tertiarySystemGroupedBackground),
            ink: .primary, accent: accent, onAccent: Palette.ink(Palette.rgb(accent)),
            tape: Palette.color(systemDark ? 0x8CC3B4 : 0x6E9A5B),
            marker: Palette.color(systemDark ? 0xE9C46A : 0xD6A03E))
    }

    private static func fixed(theme: ReaderTheme, backgroundRGB: Int, surfaceRGB: Int, accentRGB: Int) -> ReaderStyle {
        let dark = Palette.isDark(backgroundRGB)
        let reference = Palette.hardestSurface(backgroundRGB, surfaceRGB, accent: accentRGB)
        let accent = Palette.accessibleAccent(accentRGB, dark: dark, backgroundRGB: reference)
        // A theme's own warm ink is used only while it stays clearly readable.
        let plainInk = Palette.rgb(Palette.ink(backgroundRGB))
        var ink = plainInk
        if let warm = theme.inkRGB, Palette.contrast(warm, backgroundRGB) >= 7, Palette.contrast(warm, surfaceRGB) >= 7 { ink = warm }
        let tape = theme.tapeRGB ?? Palette.mix(accentRGB, toward: dark ? 0x8CC3B4 : 0x6E9A5B, 0.55)
        let marker = theme.markerRGB ?? (dark ? 0xE9C46A : 0xD6A03E)
        return ReaderStyle(
            theme: theme, isDark: dark, backgroundRGB: backgroundRGB, surfaceRGB: surfaceRGB, accentRGB: accentRGB,
            background: Palette.color(backgroundRGB),
            surface: Palette.color(surfaceRGB),
            raised: Palette.color(Palette.raised(surfaceRGB, 0.05)),
            ink: Palette.color(ink), accent: accent, onAccent: Palette.ink(Palette.rgb(accent)),
            tape: Palette.color(tape), marker: Palette.color(marker))
    }
}

// MARK: - Typography

/// Reading and dictionary typefaces available on every iPhone.
enum ReaderTypeface: String, CaseIterable, Identifiable {
    case kyokasho, gothic, mincho, rounded
    var id: String { rawValue }
    var title: String {
        switch self {
        case .kyokasho: return "Textbook · 教科書体"
        case .gothic: return "Gothic · ゴシック"
        case .mincho: return "Mincho · 明朝"
        case .rounded: return "Rounded · 丸ゴシック"
        }
    }
    /// PostScript names of the Hiragino faces bundled with iOS.
    private var postScriptName: String {
        switch self {
        case .kyokasho: return HandFont.regular
        case .gothic: return "HiraginoSans-W3"
        case .mincho: return "HiraMinProN-W3"
        case .rounded: return "HiraMaruProN-W4"
        }
    }
    func uiFont(size: CGFloat) -> UIFont {
        UIFont(name: postScriptName, size: size) ?? .systemFont(ofSize: size)
    }
    func font(size: CGFloat) -> Font { .custom(postScriptName, size: size) }
    static func resolve(_ raw: String) -> ReaderTypeface { ReaderTypeface(rawValue: raw) ?? .gothic }
}
