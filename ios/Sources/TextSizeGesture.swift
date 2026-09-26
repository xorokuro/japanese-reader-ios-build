import UIKit

/// What a two-finger text-size swipe changes: the current size, its limits,
/// and what to do while and after it changes.
struct TextResize {
    var value: Double
    var range: ClosedRange<Double>
    var set: (Double) -> Void
    var ended: () -> Void = {}
}

/// Two fingers swiping up makes the text bigger, down makes it smaller: the text
/// re-wraps at the new size instead of being magnified like a pinch zoom.
/// One-finger scrolling, text selection and pinch zoom are unaffected.
final class TextSizeSwipe: NSObject, UIGestureRecognizerDelegate {
    var resize: TextResize?
    /// Finger travel for one point of text size.
    private let step: CGFloat = 20
    private var start = 0.0
    private var applied = 0.0
    private let feedback = UISelectionFeedbackGenerator()
    private(set) lazy var recognizer: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(changed(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        return pan
    }()

    /// Adds the swipe to `view` and keeps `scrollView` scrolling with one finger only.
    func attach(to view: UIView, scrollView: UIScrollView) {
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
        if recognizer.view !== view { view.addGestureRecognizer(recognizer) }
    }

    @objc private func changed(_ pan: UIPanGestureRecognizer) {
        guard let resize else { return }
        switch pan.state {
        case .began:
            start = resize.value
            applied = resize.value
            feedback.prepare()
        case .changed:
            let steps = (-pan.translation(in: pan.view).y / step).rounded()
            let value = min(max(start + Double(steps), resize.range.lowerBound), resize.range.upperBound)
            if value != applied {
                applied = value
                resize.set(value)
                feedback.selectionChanged()
            }
        case .ended, .cancelled, .failed:
            resize.ended()
        default:
            break
        }
    }

    /// Only mostly-vertical two-finger movement counts.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard resize != nil, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: pan.view)
        return abs(velocity.y) > abs(velocity.x) * 1.2
    }
}
