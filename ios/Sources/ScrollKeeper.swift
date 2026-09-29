import UIKit

/// Puts a web page back where the reader left it, and remembers where they move it.
///
/// Long pages (grammar lessons especially) keep growing for a moment after they
/// finish loading, so a saved position further down can't be reached yet; setting
/// it once landed the page short or at the top. The position is re-applied until
/// the page is tall enough (about 3 seconds at most) and restoring stops as soon
/// as the reader touches the page.
///
/// Only positions the reader chose are saved. WebKit also moves the page while it
/// lays out, while a position is being restored and while the view is taken off
/// screen; saving those used to overwrite the real place with the top of the page.
final class ScrollKeeper {
    var target: CGPoint = .zero
    var save: ((CGPoint) -> Void)?
    private var loaded = false
    private var restoring = false
    private var attempt = 0

    /// The page finished loading: move to the saved place.
    func pageLoaded(_ scrollView: UIScrollView) {
        loaded = true
        attempt = 0
        restoring = target.y > 1
        step(scrollView)
    }

    func didScroll(_ scrollView: UIScrollView) {
        guard loaded, !restoring, scrollView.window != nil,
              scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }
        save?(scrollView.contentOffset)
    }

    func willBeginDragging() { restoring = false }

    /// A scroll the reader started has come to rest (or jumped to the top).
    func settled(_ scrollView: UIScrollView) {
        guard loaded, !restoring, scrollView.window != nil else { return }
        save?(scrollView.contentOffset)
    }

    private func step(_ scrollView: UIScrollView) {
        guard restoring else { return }
        let insets = scrollView.adjustedContentInset
        let bottom = max(-insets.top, scrollView.contentSize.height + insets.bottom - scrollView.bounds.height)
        let y = target.y
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: min(y, bottom)), animated: false)
        attempt += 1
        let reached = bottom + 1 >= y && abs(scrollView.contentOffset.y - y) < 2
        // Once reached, hold it a few more times in case WebKit moves it again.
        if attempt >= 30 || (reached && attempt >= 4) {
            restoring = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak scrollView] in
            guard let self, let scrollView else { return }
            self.step(scrollView)
        }
    }
}
