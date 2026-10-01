import SwiftUI
import UIKit

/// Full-screen reading: hides the tab bar, title bar, page buttons, status bar and
/// home indicator on whatever page is open. A two-finger tap anywhere toggles it.
@MainActor final class ImmersiveController: ObservableObject {
    static let shared = ImmersiveController()
    /// Library switch: the two-finger tap turns full screen on (it can always turn it off).
    static let gestureKey = "immersiveGesture"
    private static let hintCountKey = "immersiveHintCount"

    @Published private(set) var on = false
    @Published private(set) var hint: String?
    private var hintTask: Task<Void, Never>?

    func toggle() { set(!on) }

    func set(_ value: Bool) {
        guard value != on else { return }
        withAnimation(.easeInOut(duration: 0.25)) { on = value }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if value {
            // Remind how to get back, the first few times only.
            let shown = UserDefaults.standard.integer(forKey: Self.hintCountKey)
            if shown < 5 {
                UserDefaults.standard.set(shown + 1, forKey: Self.hintCountKey)
                showHint("Tap with two fingers to show the buttons · 雙指輕點顯示按鈕")
            }
        } else {
            hintTask?.cancel()
            hint = nil
        }
    }

    private func showHint(_ text: String) {
        hintTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { hint = text }
        hintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { self?.hint = nil }
        }
    }
}

/// Watches the whole window for a two-finger tap without taking touches from
/// anything else (text selection, scrolling, the pinch for text size, buttons).
struct ImmersiveGesture: UIViewRepresentable {
    var enabled: Bool
    func makeUIView(context: Context) -> ImmersiveGestureView { ImmersiveGestureView() }
    func updateUIView(_ view: ImmersiveGestureView, context: Context) { view.enabled = enabled }
    static func dismantleUIView(_ view: ImmersiveGestureView, coordinator: ()) { view.detach() }
}

final class ImmersiveGestureView: UIView, UIGestureRecognizerDelegate {
    var enabled = true
    private weak var observedWindow: UIWindow?
    private lazy var tap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.numberOfTouchesRequired = 2
        tap.numberOfTapsRequired = 1
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        return tap
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        detach()
        guard let window else { return }
        observedWindow = window
        window.addGestureRecognizer(tap)
    }

    func detach() {
        observedWindow?.removeGestureRecognizer(tap)
        observedWindow = nil
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        MainActor.assumeIsolated {
            let controller = ImmersiveController.shared
            if enabled || controller.on { controller.toggle() }
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        enabled || MainActor.assumeIsolated { ImmersiveController.shared.on }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}

/// The reminder pill shown when full screen starts.
struct ImmersiveHint: View {
    let text: String
    let style: ReaderStyle
    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(style.separator, lineWidth: 1))
            .padding(.horizontal, 24)
            .allowsHitTesting(false)
            .accessibilityIdentifier("immersiveHint")
    }
}
