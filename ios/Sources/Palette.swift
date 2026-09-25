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

    static let systemID = "system"
    static let customID = "custom"

    static let system = ReaderTheme(
        id: systemID, name: "System", detail: "Follows iPhone Light / Dark",
        family: .system, backgroundRGB: nil, surfaceRGB: nil, accentRGB: 0x1F7A73)

    static let custom = ReaderTheme(
        id: customID, name: "Custom", detail: "Your own accent and background",
        family: .custom, backgroundRGB: nil, surfaceRGB: nil, accentRGB: 0x1F7A73)

    static let light: [ReaderTheme] = [
        ReaderTheme(id: "washi", name: "Washi Paper", detail: "Warm white, jade accent",
                    family: .light, backgroundRGB: 0xFAF7F1, surfaceRGB: 0xFFFFFF, accentRGB: 0x1F7A73),
        ReaderTheme(id: "kinari", name: "Kinari Silk", detail: "Unbleached silk, vermilion seal",
                    family: .light, backgroundRGB: 0xF6F1E7, surfaceRGB: 0xFFFDF8, accentRGB: 0xB4432F),
        ReaderTheme(id: "sepia", name: "Sepia Study", detail: "Aged paper, easy on the eyes",
                    family: .light, backgroundRGB: 0xF3E8D5, surfaceRGB: 0xFCF5E8, accentRGB: 0x8A5524),
        ReaderTheme(id: "sumie", name: "Sumi-e", detail: "Ink-wash paper, crimson stamp",
                    family: .light, backgroundRGB: 0xF2F1ED, surfaceRGB: 0xFBFBF9, accentRGB: 0x9E2B25),
        ReaderTheme(id: "sakura", name: "Sakura", detail: "Soft blossom light",
                    family: .light, backgroundRGB: 0xFDF3F5, surfaceRGB: 0xFFFFFF, accentRGB: 0xB03A62),
        ReaderTheme(id: "momo", name: "Peach Tea", detail: "Blush paper, persimmon accent",
                    family: .light, backgroundRGB: 0xFFF1EA, surfaceRGB: 0xFFFBF8, accentRGB: 0xB84A2B),
        ReaderTheme(id: "yuzu", name: "Yuzu", detail: "Citrus morning",
                    family: .light, backgroundRGB: 0xFBF6E4, surfaceRGB: 0xFFFDF3, accentRGB: 0x946000),
        ReaderTheme(id: "matcha", name: "Matcha Latte", detail: "Pale tea green",
                    family: .light, backgroundRGB: 0xEEF2E4, surfaceRGB: 0xFAFCF5, accentRGB: 0x4F7A2E),
        ReaderTheme(id: "koke", name: "Moss Garden", detail: "Temple moss and stone",
                    family: .light, backgroundRGB: 0xEEF1EA, surfaceRGB: 0xF9FBF6, accentRGB: 0x3F6B4E),
        ReaderTheme(id: "mist", name: "Morning Mist", detail: "Cool blue daylight",
                    family: .light, backgroundRGB: 0xEEF3F8, surfaceRGB: 0xFFFFFF, accentRGB: 0x2C6DAF),
        ReaderTheme(id: "glacier", name: "Glacier", detail: "Clear ice, teal ink",
                    family: .light, backgroundRGB: 0xEAF4F4, surfaceRGB: 0xF8FDFD, accentRGB: 0x1E7C8A),
        ReaderTheme(id: "ajisai", name: "Hydrangea", detail: "Rainy-season indigo",
                    family: .light, backgroundRGB: 0xEDF1FA, surfaceRGB: 0xFBFCFF, accentRGB: 0x3E5BA9),
        ReaderTheme(id: "fuji", name: "Wisteria", detail: "Lavender afternoon",
                    family: .light, backgroundRGB: 0xF3F0FA, surfaceRGB: 0xFFFFFF, accentRGB: 0x6B4FA8),
        ReaderTheme(id: "shiro", name: "Pure White", detail: "Crisp and neutral",
                    family: .light, backgroundRGB: 0xFFFFFF, surfaceRGB: 0xF6F6F4, accentRGB: 0x2A5DB0)
    ]

    static let dark: [ReaderTheme] = [
        ReaderTheme(id: "midnight", name: "Midnight Ink", detail: "Deep navy, cyan accent",
                    family: .dark, backgroundRGB: 0x0E1320, surfaceRGB: 0x181F30, accentRGB: 0x6FC8E8),
        ReaderTheme(id: "suminight", name: "Sumi Night", detail: "Charcoal and vermilion",
                    family: .dark, backgroundRGB: 0x1C1B19, surfaceRGB: 0x262422, accentRGB: 0xE07A5F),
        ReaderTheme(id: "kissaten", name: "Kissaten", detail: "Coffee-house wood and cream",
                    family: .dark, backgroundRGB: 0x1E1813, surfaceRGB: 0x2A221B, accentRGB: 0xE0B07A),
        ReaderTheme(id: "lantern", name: "Lantern Night", detail: "Warm paper lantern glow",
                    family: .dark, backgroundRGB: 0x211C29, surfaceRGB: 0x2C2535, accentRGB: 0xF1B15A),
        ReaderTheme(id: "yozakura", name: "Night Sakura", detail: "Blossoms after dark",
                    family: .dark, backgroundRGB: 0x1D1519, surfaceRGB: 0x2A1F25, accentRGB: 0xF2A1B9),
        ReaderTheme(id: "koyo", name: "Autumn Maple", detail: "Ember reds and browns",
                    family: .dark, backgroundRGB: 0x211815, surfaceRGB: 0x2E211C, accentRGB: 0xF08B4C),
        ReaderTheme(id: "hotaru", name: "Firefly", detail: "Summer night, soft glow",
                    family: .dark, backgroundRGB: 0x10150F, surfaceRGB: 0x19211A, accentRGB: 0xD8E36B),
        ReaderTheme(id: "jade", name: "Jade Lantern", detail: "Dark green reading room",
                    family: .dark, backgroundRGB: 0x0C1614, surfaceRGB: 0x15201D, accentRGB: 0x75DDBA),
        ReaderTheme(id: "matchanight", name: "Matcha Night", detail: "Deep tea green",
                    family: .dark, backgroundRGB: 0x1B2520, surfaceRGB: 0x243029, accentRGB: 0xA6D08A),
        ReaderTheme(id: "shinkai", name: "Deep Sea", detail: "Abyssal blue, bioluminescent",
                    family: .dark, backgroundRGB: 0x071821, surfaceRGB: 0x0F2530, accentRGB: 0x5FD1E6),
        ReaderTheme(id: "ginga", name: "Galaxy", detail: "Starlit indigo, gold",
                    family: .dark, backgroundRGB: 0x0F1226, surfaceRGB: 0x1A1E3A, accentRGB: 0xFFD27A),
        ReaderTheme(id: "plum", name: "Plum Night", detail: "Violet dusk",
                    family: .dark, backgroundRGB: 0x140E1B, surfaceRGB: 0x1F1729, accentRGB: 0xC49BF0),
        ReaderTheme(id: "tsukiyo", name: "Moonlight", detail: "Silver on slate",
                    family: .dark, backgroundRGB: 0x15181D, surfaceRGB: 0x1F242B, accentRGB: 0xC9D6E8),
        ReaderTheme(id: "frost", name: "Frost", detail: "Nordic slate, ice blue",
                    family: .dark, backgroundRGB: 0x222831, surfaceRGB: 0x2D3440, accentRGB: 0x88C0D0),
        ReaderTheme(id: "black", name: "True Black", detail: "OLED friendly",
                    family: .dark, backgroundRGB: 0x000000, surfaceRGB: 0x101012, accentRGB: 0x64D8B4)
    ]

    static let all: [ReaderTheme] = [system] + light + dark + [custom]

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

    var usesSystemSurfaces: Bool { backgroundRGB == nil }
    var secondary: Color { ink.opacity(0.62) }
    var faint: Color { ink.opacity(0.42) }
    var hairline: Color { ink.opacity(isDark ? 0.16 : 0.09) }
    var separator: Color { ink.opacity(isDark ? 0.12 : 0.07) }
    var accentSoft: Color { accent.opacity(isDark ? 0.22 : 0.13) }
    var shadow: Color { Color.black.opacity(isDark ? 0.40 : 0.08) }
    /// Locks the interface to the theme's own mode; `nil` keeps following iOS.
    var colorScheme: ColorScheme? { usesSystemSurfaces ? nil : (isDark ? .dark : .light) }
    /// Identity for views that must be rebuilt when the palette changes.
    var identity: String { "\(theme.id)-\(backgroundRGB ?? -1)-\(accentRGB)-\(isDark)" }

    static func resolve(themeID: String, customPaper: Bool, paperRGB: Int, customAccentRGB: Int, systemDark: Bool) -> ReaderStyle {
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

    private static func system(theme: ReaderTheme, accentRGB: Int, systemDark: Bool) -> ReaderStyle {
        let accent = Palette.accessibleAccent(accentRGB, dark: systemDark)
        return ReaderStyle(
            theme: theme, isDark: systemDark, backgroundRGB: nil, surfaceRGB: nil, accentRGB: accentRGB,
            background: Color(uiColor: .systemGroupedBackground),
            surface: Color(uiColor: .secondarySystemGroupedBackground),
            raised: Color(uiColor: .tertiarySystemGroupedBackground),
            ink: .primary, accent: accent, onAccent: Palette.ink(Palette.rgb(accent)))
    }

    private static func fixed(theme: ReaderTheme, backgroundRGB: Int, surfaceRGB: Int, accentRGB: Int) -> ReaderStyle {
        let dark = Palette.isDark(backgroundRGB)
        let reference = Palette.hardestSurface(backgroundRGB, surfaceRGB, accent: accentRGB)
        let accent = Palette.accessibleAccent(accentRGB, dark: dark, backgroundRGB: reference)
        return ReaderStyle(
            theme: theme, isDark: dark, backgroundRGB: backgroundRGB, surfaceRGB: surfaceRGB, accentRGB: accentRGB,
            background: Palette.color(backgroundRGB),
            surface: Palette.color(surfaceRGB),
            raised: Palette.color(Palette.raised(surfaceRGB, 0.05)),
            ink: Palette.ink(backgroundRGB), accent: accent, onAccent: Palette.ink(Palette.rgb(accent)))
    }
}

// MARK: - Typography

/// Reading and dictionary typefaces available on every iPhone.
enum ReaderTypeface: String, CaseIterable, Identifiable {
    case gothic, mincho, rounded
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gothic: return "Gothic · ゴシック"
        case .mincho: return "Mincho · 明朝"
        case .rounded: return "Rounded · 丸ゴシック"
        }
    }
    /// PostScript names of the Hiragino faces bundled with iOS.
    private var postScriptName: String {
        switch self {
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
