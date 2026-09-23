import SwiftUI
import UIKit.UIGestureRecognizerSubclass

// Observe the window so native selection handles are covered too. This recognizer
// never recognizes or prevents another gesture: text selection retains control.
struct SelectionTouchObserver: UIViewRepresentable {
    let changed: (Bool, Bool) -> Void
    func makeUIView(context: Context) -> SelectionTouchObserverView { SelectionTouchObserverView() }
    func updateUIView(_ view: SelectionTouchObserverView, context: Context) { view.changed = changed }
    static func dismantleUIView(_ view: SelectionTouchObserverView, coordinator: ()) { view.detach() }
}

final class SelectionTouchObserverView: UIView {
    var changed: ((Bool, Bool) -> Void)?
    private let observer = SelectionTouchRecognizer(target: nil, action: nil)
    override func didMoveToWindow() {
        super.didMoveToWindow()
        detach()
        guard let window else { return }
        observer.changed = { [weak self] down, cancelled in self?.changed?(down, cancelled) }
        observer.cancelsTouchesInView = false
        observer.delaysTouchesBegan = false
        observer.delaysTouchesEnded = false
        window.addGestureRecognizer(observer)
    }
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
