import UIKit

/// What a two-finger text-size gesture changes: the current size, its limits,
/// and what to do while and after it changes.
struct TextResize {
    var value: Double
    var range: ClosedRange<Double>
    var set: (Double) -> Void
    var ended: () -> Void = {}
}

/// Two fingers swiping up (or pinching out) makes the text bigger; swiping down
/// (or pinching in) makes it smaller. The text re-wraps at the new size instead
/// of being magnified. One-finger scrolling and text selection are unaffected.
final class TextSizeSwipe: NSObject, UIGestureRecognizerDelegate {
    var resize: TextResize?
    /// Finger travel for one point of text size.
    private let step: CGFloat = 18
    private var start = 0.0
    private var applied = 0.0
    private let feedback = UISelectionFeedbackGenerator()
    private weak var scrollView: UIScrollView?

    private(set) lazy var swipe: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.cancelsTouchesInView = true
        pan.delegate = self
        return pan
    }()
    private(set) lazy var pinch: UIPinchGestureRecognizer = {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        return pinch
    }()

    /// Adds the gestures to `view`. The scroll view keeps one-finger scrolling
    /// and loses its own pinch-zoom, which would otherwise take the fingers.
    func attach(to view: UIView, scrollView: UIScrollView) {
        self.scrollView = scrollView
        claimTwoFingers()
        if swipe.view !== view { view.addGestureRecognizer(swipe) }
        if pinch.view !== view { view.addGestureRecognizer(pinch) }
    }

    /// Safe to call repeatedly: WebKit can reset its scroll view's gestures.
    func claimTwoFingers() {
        guard let scrollView else { return }
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
        scrollView.pinchGestureRecognizer?.isEnabled = false
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 1
        scrollView.bouncesZoom = false
    }

    private func begin() {
        guard let resize else { return }
        start = resize.value
        applied = resize.value
        feedback.prepare()
    }

    private func apply(_ steps: Double) {
        guard let resize else { return }
        let value = min(max(start + steps.rounded(), resize.range.lowerBound), resize.range.upperBound)
        guard value != applied else { return }
        applied = value
        resize.set(value)
        feedback.selectionChanged()
    }

    @objc private func swiped(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began: begin()
        case .changed: apply(Double(-pan.translation(in: pan.view).y / step))
        case .ended, .cancelled, .failed: resize?.ended()
        default: break
        }
    }

    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began: begin()
        // Doubling the finger spread adds about 6 pt.
        case .changed: apply(Double(log2(max(pinch.scale, 0.01))) * 6)
        case .ended, .cancelled, .failed: resize?.ended()
        default: break
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard resize != nil else { return false }
        if gestureRecognizer === swipe {
            // Mostly-vertical movement only; a pinch is left to the pinch recogniser.
            let velocity = swipe.velocity(in: swipe.view)
            let travel = swipe.translation(in: swipe.view)
            return abs(velocity.y) >= abs(velocity.x) || abs(travel.y) >= abs(travel.x)
        }
        return true
    }

    /// Runs alongside WebKit's and UIKit's own recognisers, but the swipe and the
    /// pinch never drive the size at the same time.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        !((gestureRecognizer === swipe && other === pinch) || (gestureRecognizer === pinch && other === swipe))
    }
}
