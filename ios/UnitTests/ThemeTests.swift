import XCTest
import SwiftUI
@testable import JapaneseReader

final class ThemeTests: XCTestCase {
    private func contrast(_ a: Int, _ b: Int) -> Double {
        let x = Palette.luminance(Palette.channels(a)), y = Palette.luminance(Palette.channels(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Every shipped preset has to stay readable: ink against its own background,
    /// and the accent against both the page and the card surface.
    func testPresetThemesStayReadable() {
        for theme in ReaderTheme.all {
            guard let background = theme.backgroundRGB else { continue }
            let surface = theme.surfaceRGB ?? Palette.raised(background)
            let ink = Palette.rgb(Palette.ink(background))
            XCTAssertGreaterThanOrEqual(contrast(background, ink), 4.5, "\(theme.name) ink")
            let style = ReaderStyle.resolve(themeID: theme.id, customPaper: false, paperRGB: 0xFFFFFF,
                                            customAccentRGB: 0x1F7A73, systemDark: false)
            let accent = Palette.rgb(style.accent)
            XCTAssertGreaterThanOrEqual(contrast(background, accent), 4.49, "\(theme.name) accent on background")
            XCTAssertGreaterThanOrEqual(contrast(surface, accent), 4.49, "\(theme.name) accent on surface")
            XCTAssertEqual(style.isDark, Palette.isDark(background), "\(theme.name) mode")
            XCTAssertEqual(style.backgroundRGB, background)
            XCTAssertEqual(style.surfaceRGB, surface)
        }
    }

    /// A filled accent shape always gets a label that survives on it.
    func testOnAccentContrast() {
        for theme in ReaderTheme.all {
            let style = ReaderStyle.resolve(themeID: theme.id, customPaper: false, paperRGB: 0xFFFFFF,
                                            customAccentRGB: 0x1F7A73, systemDark: theme.id == "system")
            let accent = Palette.rgb(style.accent), label = Palette.rgb(style.onAccent)
            XCTAssertGreaterThanOrEqual(contrast(accent, label), 4.5, "\(theme.name) label on accent")
        }
    }

    /// Upgrades: an install that already picked a custom background keeps it until
    /// a preset is chosen, and an unknown stored id never breaks the interface.
    func testStoredPreferenceResolution() {
        XCTAssertEqual(ReaderTheme.resolve("", hasCustomPaper: false).id, ReaderTheme.systemID)
        XCTAssertEqual(ReaderTheme.resolve("", hasCustomPaper: true).id, ReaderTheme.customID)
        XCTAssertEqual(ReaderTheme.resolve("removed-theme", hasCustomPaper: false).id, ReaderTheme.systemID)
        XCTAssertEqual(ReaderTheme.resolve("midnight", hasCustomPaper: true).id, "midnight")

        let legacy = ReaderStyle.resolve(themeID: "", customPaper: true, paperRGB: 0x2D3443,
                                         customAccentRGB: 0x1F7A73, systemDark: false)
        XCTAssertEqual(legacy.backgroundRGB, 0x2D3443, "A saved custom background must survive the update")
        XCTAssertTrue(legacy.isDark)
        XCTAssertEqual(legacy.colorScheme, .dark)

        let legacyAccentOnly = ReaderStyle.resolve(themeID: "", customPaper: false, paperRGB: 0x2D3443,
                                                   customAccentRGB: 0x1F7A73, systemDark: false)
        XCTAssertNil(legacyAccentOnly.backgroundRGB, "Accent-only installs keep the iOS system surfaces")
        XCTAssertNil(legacyAccentOnly.colorScheme)
    }

    /// The system preset must not lock the interface to one appearance.
    func testSystemThemeFollowsDeviceAppearance() {
        for dark in [false, true] {
            let style = ReaderStyle.resolve(themeID: ReaderTheme.systemID, customPaper: false, paperRGB: 0xFFFFFF,
                                            customAccentRGB: 0x1F7A73, systemDark: dark)
            XCTAssertTrue(style.usesSystemSurfaces)
            XCTAssertNil(style.colorScheme)
            XCTAssertEqual(style.isDark, dark)
        }
    }

    func testThemeIdentityChangesWithPalette() {
        let first = ReaderStyle.resolve(themeID: "jade", customPaper: false, paperRGB: 0xFFFFFF,
                                        customAccentRGB: 0x1F7A73, systemDark: true)
        let second = ReaderStyle.resolve(themeID: "sepia", customPaper: false, paperRGB: 0xFFFFFF,
                                         customAccentRGB: 0x1F7A73, systemDark: true)
        XCTAssertNotEqual(first.identity, second.identity, "Dictionary pages rebuild when the palette changes")
    }

    func testEveryThemeHasAUniqueIdentifier() {
        XCTAssertEqual(Set(ReaderTheme.all.map(\.id)).count, ReaderTheme.all.count)
        XCTAssertTrue(ReaderTheme.all.contains { $0.family == .light })
        XCTAssertTrue(ReaderTheme.all.contains { $0.family == .dark })
    }
}
