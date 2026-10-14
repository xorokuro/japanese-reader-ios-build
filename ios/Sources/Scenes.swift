import SwiftUI
import UIKit

// 手繪 Hand-drawn scenes — the seventeen watercolour pictures of the desktop reader and the JLPT
// lessons reader (organic-bg.js), as Fable papers (ReaderTheme.scenes, motif `.scene`). The
// picture is the page: it fills every screen edge to edge, behind the usual Fable layout, and
// the header keeps no emblem of its own.
//
// The pictures are bundled JPEGs in Sources/Backgrounds, made by tools/render_scenes.py:
//   <id>.jpg          the phone page, painted for a 440 x 956 pt screen at 3x
//   <id>-wide.jpg     the desktop composition, for iPad and landscape screens
//   <id>-swatch.jpg   the theme-picker miniature

enum ScenePicture {
    private static var pages: [String: UIImage] = [:]
    private static var swatches: [String: UIImage] = [:]

    /// The page picture, decoded once. Only the pictures in use stay in memory (a phone page
    /// is about 15 MB once decoded), so switching themes lets the previous one go.
    static func page(_ id: String, wide: Bool) -> UIImage? {
        let name = wide ? id + "-wide" : id
        if let image = pages[name] { return image }
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg"),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        let decoded = image.preparingForDisplay() ?? image
        if pages.count >= 2 { pages.removeAll() }
        pages[name] = decoded
        return decoded
    }

    /// The small picture for the theme picker (a few kilobytes each).
    static func swatch(_ id: String) -> UIImage? {
        if let image = swatches[id] { return image }
        guard let url = Bundle.main.url(forResource: id + "-swatch", withExtension: "jpg"),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        swatches[id] = image
        return image
    }

    /// True when a theme's pictures are in the app (all three sizes).
    static func isBundled(_ id: String) -> Bool {
        [id, id + "-wide", id + "-swatch"].allSatisfy { Bundle.main.url(forResource: $0, withExtension: "jpg") != nil }
    }
}

/// The picture behind every screen of a 手繪 theme: the phone composition on tall screens, the
/// desktop one on wider ones (iPad, landscape), filling the page and cropped at the edges.
struct SceneBackdrop: View {
    let themeID: String
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            if size.width > 0, size.height > 0,
               let picture = ScenePicture.page(themeID, wide: size.width / size.height > 0.62) {
                Image(uiImage: picture)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
