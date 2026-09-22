import SwiftUI
import WebKit

// Observe background taps without swallowing buttons, text editing or selection.
struct KeyboardDismissArea: UIViewRepresentable {
    var enabled: Bool
    let dismiss: () -> Void
    func makeUIView(context: Context) -> TapObserverView { TapObserverView() }
    func updateUIView(_ view: TapObserverView, context: Context) {
        view.enabled = enabled
        view.dismiss = dismiss
    }
    static func dismantleUIView(_ view: TapObserverView, coordinator: ()) { view.detach() }
}

final class TapObserverView: UIView, UIGestureRecognizerDelegate {
    var enabled = false
    var dismiss: (() -> Void)?
    private weak var observedWindow: UIWindow?
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
    override func didMoveToWindow() {
        super.didMoveToWindow()
        detach()
        guard let window else { return }
        observedWindow = window
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
    }
    func detach() { observedWindow?.removeGestureRecognizer(tap); observedWindow = nil }
    @objc private func tapped() { if enabled { dismiss?() } }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard enabled, bounds.contains(touch.location(in: self)) else { return false }
        for control in KeyboardControlAreaView.controls.allObjects {
            if control.window === window && !control.isHidden && control.bounds.contains(touch.location(in: control)) { return false }
        }
        var target = touch.view
        while let view = target {
            if view is UITextView || view is UITextField || view is WKWebView || view is UIControl { return false }
            target = view.superview
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}

// SwiftUI buttons are not necessarily UIControl subclasses. Mark their actual
// layout rectangles so the background observer never treats filters as blank space.
struct KeyboardControlArea: UIViewRepresentable {
    func makeUIView(context: Context) -> KeyboardControlAreaView { KeyboardControlAreaView() }
    func updateUIView(_ view: KeyboardControlAreaView, context: Context) {}
}
final class KeyboardControlAreaView: UIView {
    static let controls = NSHashTable<UIView>.weakObjects()
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        Self.controls.add(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
