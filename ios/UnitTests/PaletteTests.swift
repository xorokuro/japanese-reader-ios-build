import XCTest
@testable import JapaneseReader

final class PaletteTests: XCTestCase {
    func testAccentOnCustomBackgrounds() {
        for paperRGB in [0x000000, 0xFFFFFF, 0x1F7A73, 0x777777, 0xFFCC88] {
            let paper = Palette.luminance(Palette.channels(paperRGB))
            for accentRGB in [0x000000, 0xFFFFFF, 0x1F7A73, 0x777777] {
                let color = Palette.accessibleAccent(accentRGB, dark: paper < 0.179, backgroundRGB: paperRGB)
                let accent = Palette.luminance(Palette.channels(Palette.rgb(color)))
                XCTAssertGreaterThanOrEqual((max(paper, accent) + 0.05) / (min(paper, accent) + 0.05), 4.49)
            }
        }
    }
    func testContrastAcrossPalette() {
        for r in stride(from: 0, through: 255, by: 51) {
            for g in stride(from: 0, through: 255, by: 51) {
                for b in stride(from: 0, through: 255, by: 51) {
                    let rgb = (r << 16) | (g << 8) | b
                    let paper = Palette.luminance(Palette.channels(rgb))
                    let ink = Palette.luminance(Palette.channels(Palette.rgb(Palette.ink(rgb))))
                    XCTAssertGreaterThanOrEqual((max(paper, ink) + 0.05) / (min(paper, ink) + 0.05), 4.5)
                    for dark in [false, true] {
                        let accent = Palette.luminance(Palette.channels(Palette.rgb(Palette.accessibleAccent(rgb, dark: dark))))
                        let surface = dark ? Palette.luminance(Palette.channels(0x2C2C2E)) : 1
                        XCTAssertGreaterThanOrEqual((max(accent, surface) + 0.05) / (min(accent, surface) + 0.05), 4.49)
                    }
                }
            }
        }
    }
}
