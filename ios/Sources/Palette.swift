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
}
