import SwiftUI
import UIKit.UIGestureRecognizerSubclass
import WebKit

// Observe the window so native selection handles are covered too. This recognizer
// never recognizes or prevents another gesture: text selection retains control.
struct SelectionTouchObserver: UIViewRepresentable {
    let enabled: Bool
    let changed: (Bool, Bool) -> Void
    func makeUIView(context: Context) -> SelectionTouchObserverView { SelectionTouchObserverView() }
    func updateUIView(_ view: SelectionTouchObserverView, context: Context) {
        view.enabled = enabled
        view.changed = changed
    }
    static func dismantleUIView(_ view: SelectionTouchObserverView, coordinator: ()) { view.detach() }
}

final class SelectionTouchObserverView: UIView, UIGestureRecognizerDelegate {
    var enabled = false
    var changed: ((Bool, Bool) -> Void)?
    private let observer = SelectionTouchRecognizer(target: nil, action: nil)
    override func didMoveToWindow() {
        super.didMoveToWindow()
        detach()
        guard let window else { return }
        observer.changed = { [weak self] down, cancelled in self?.changed?(down, cancelled) }
        observer.delegate = self
        observer.cancelsTouchesInView = false
        observer.delaysTouchesBegan = false
        observer.delaysTouchesEnded = false
        window.addGestureRecognizer(observer)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool { enabled }
    func detach() {
        observer.view?.removeGestureRecognizer(observer)
        observer.cancelTracking()
    }
}

final class SelectionTouchRecognizer: UIGestureRecognizer {
    var changed: ((Bool, Bool) -> Void)?
    private var fingers = Set<UITouch>()
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let wasEmpty = fingers.isEmpty
        fingers.formUnion(touches)
        if wasEmpty { changed?(true, false) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        fingers.subtract(touches)
        if fingers.isEmpty {
            changed?(false, false)
            state = .failed
        }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        cancelTracking()
        state = .failed
    }
    func cancelTracking() {
        guard !fingers.isEmpty else { return }
        fingers.removeAll()
        changed?(false, true)
    }
    override func reset() {
        cancelTracking()
        super.reset()
    }
}

/// With the iPhone Copy / Look Up bar hidden, the dictionary card is where Copy
/// and Translate live. A selection can outlive its card (switch tabs and come
/// back, or close the card), and tapping it then showed nothing at all. This tap
/// never blocks the text view's own gestures; it only reports where a single tap
/// landed so the page can check it is on the selection and reopen the card.
final class SelectionReopenTap: NSObject, UIGestureRecognizerDelegate {
    var enabled = false
    /// Tap location in the attached view's coordinates.
    var tapped: ((CGPoint) -> Void)?
    private(set) lazy var tap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(fired(_:)))
        tap.numberOfTapsRequired = 1
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        return tap
    }()

    func attach(to view: UIView) {
        if tap.view !== view { view.addGestureRecognizer(tap) }
    }

    @objc private func fired(_ tap: UITapGestureRecognizer) {
        guard enabled, tap.state == .ended, let view = tap.view else { return }
        let point = tap.location(in: view)
        // Let the text view finish handling the same tap first.
        DispatchQueue.main.async { [weak self] in self?.tapped?(point) }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { enabled }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { false }
}

extension SelectionReopenTap {
    /// For web pages: asks the selection script to post the selection again when
    /// the tap (converted to page coordinates) is on it.
    func attach(to webView: WKWebView) {
        attach(to: webView as UIView)
        tapped = { [weak webView] point in
            guard let webView else { return }
            let scroll = webView.scrollView
            let zoom = max(scroll.zoomScale, 0.01)
            let inContent = webView.convert(point, to: scroll)
            let x = inContent.x / zoom, y = inContent.y / zoom
            DictionaryPage.evaluateSelectionScript("window.__jpRepost ? window.__jpRepost(\(x), \(y)) : false", in: webView) { _, _ in }
        }
    }
}

/// Double-tap on a definition page: the right half steps to the same word in the
/// next dictionary, the left half to the previous one (like the ‹ › arrows).
/// It never blocks scrolling, selection or links on the page.
final class PageDoubleTap: NSObject, UIGestureRecognizerDelegate {
    /// -1 for the left half, +1 for the right half.
    var step: ((Int) -> Void)?
    private(set) lazy var tap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(fired(_:)))
        tap.numberOfTapsRequired = 2
        tap.numberOfTouchesRequired = 1
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        return tap
    }()

    func attach(to view: UIView) {
        if tap.view !== view { view.addGestureRecognizer(tap) }
    }

    @objc private func fired(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, let view = tap.view else { return }
        step?(tap.location(in: view).x < view.bounds.midX ? -1 : 1)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { step != nil }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { false }
}
