import SwiftUI
import UIKit
import CoreMotion

/// Upside-down use (phone on a stand with the charging cable at the top).
/// iPhones with Face ID never rotate apps to upside-down portrait, so the app
/// turns its own window 180° instead.
enum FlipMode: String, CaseIterable, Identifiable {
    case off, auto, on
    static let key = "flipMode"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off"
        case .auto: "Auto"
        case .on: "Always"
        }
    }
}

@MainActor final class FlipController: ObservableObject {
    static let shared = FlipController()

    /// True while the window is turned 180°.
    @Published private(set) var flipped = false
    private(set) var mode = FlipMode(rawValue: UserDefaults.standard.string(forKey: FlipMode.key) ?? "") ?? .off

    /// Auto mode: the phone is physically upside down (from the accelerometer,
    /// which keeps working when Portrait Orientation Lock is on).
    private var upsideDown = false
    private var pendingReading: Bool?
    private var pendingSince = Date.distantPast
    private let motion = CMMotionManager()

    /// Safe-area insets of the upright portrait window, captured just before flipping.
    private var portraitInsets: UIEdgeInsets?
    private var insetTimer: Timer?
    private var waitingForPortrait = false

    var wantsFlip: Bool { mode == .on || (mode == .auto && upsideDown) }

    var orientationMask: UIInterfaceOrientationMask {
        if wantsFlip || flipped { return .portrait }
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        // With the app's own flip in use, never let iOS rotate upside down as well.
        return mode == .off ? .all : .allButUpsideDown
    }

    func setMode(_ raw: String) {
        mode = FlipMode(rawValue: raw) ?? .off
        if mode != .auto { upsideDown = false; pendingReading = nil }
        updateMotion()
        apply()
    }

    func sceneBecameActive() {
        updateMotion()
        apply()
    }

    func sceneResigned() {
        motion.stopAccelerometerUpdates()
        pendingReading = nil
    }

    // MARK: - Motion (Auto)

    private func updateMotion() {
        guard mode == .auto, motion.isAccelerometerAvailable else {
            motion.stopAccelerometerUpdates()
            return
        }
        guard !motion.isAccelerometerActive else { return }
        motion.accelerometerUpdateInterval = 0.2
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let acceleration = data?.acceleration else { return }
            MainActor.assumeIsolated { self?.read(acceleration) }
        }
    }

    private func read(_ a: CMAcceleration) {
        // Gravity along the long edge: y < 0 upright, y > 0 upside down.
        // A clear sideways reading counts as "not upside down" so landscape works normally.
        let threshold = 0.45
        let reading: Bool?
        if abs(a.y) >= abs(a.x) && a.y > threshold { reading = true }
        else if abs(a.y) >= abs(a.x) && a.y < -threshold { reading = false }
        else if abs(a.x) > abs(a.y) && abs(a.x) > threshold { reading = false }
        else { reading = nil } // lying flat or in between: keep the current state
        guard let reading else { pendingReading = nil; return }
        if reading != pendingReading {
            pendingReading = reading
            pendingSince = Date()
            return
        }
        // Must hold steady for a moment so a wobble on the stand doesn't flip the screen.
        if reading != upsideDown && Date().timeIntervalSince(pendingSince) > 0.6 {
            upsideDown = reading
            apply()
        }
    }

    // MARK: - Window

    func apply() {
        guard let scene = Self.activeScene, let window = Self.mainWindow(in: scene) else { return }
        let want = wantsFlip
        refreshOrientations(scene)
        if want && !flipped {
            if scene.interfaceOrientation != .portrait {
                // Turn the interface back to upright portrait first, then flip.
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
                guard !waitingForPortrait else { return }
                waitingForPortrait = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(600))
                    self?.waitingForPortrait = false
                    self?.apply()
                }
                return
            }
            portraitInsets = window.safeAreaInsets
            flipped = true
            UIView.transition(with: window, duration: 0.3, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                window.transform = CGAffineTransform(rotationAngle: .pi)
            }
            fixInsets()
            startInsetTimer()
        } else if !want && flipped {
            flipped = false
            insetTimer?.invalidate()
            insetTimer = nil
            setAdditionalInsets(.zero, in: window)
            UIView.transition(with: window, duration: 0.3, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                window.transform = .identity
            }
            refreshOrientations(scene)
        } else if flipped {
            fixInsets()
        }
    }

    private func refreshOrientations(_ scene: UIWindowScene) {
        for window in scene.windows { window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
    }

    /// iOS keeps reporting the safe area for an upright window, so after the turn the
    /// Dynamic Island side (now the window's bottom) would only get the home-indicator
    /// inset. Add the difference so nothing slides under the island.
    private func fixInsets() {
        guard flipped, let base = portraitInsets,
              let scene = Self.activeScene, let window = Self.mainWindow(in: scene) else { return }
        let now = window.safeAreaInsets
        let extra = UIEdgeInsets(top: max(0, base.bottom - now.top),
                                 left: max(0, base.right - now.left),
                                 bottom: max(0, base.top - now.bottom),
                                 right: max(0, base.left - now.right))
        setAdditionalInsets(extra, in: window)
    }

    private func setAdditionalInsets(_ insets: UIEdgeInsets, in window: UIWindow) {
        var controller = window.rootViewController
        while let current = controller {
            if current.additionalSafeAreaInsets != insets { current.additionalSafeAreaInsets = insets }
            controller = current.presentedViewController
        }
    }

    /// Sheets and the share sheet appear later; keep their insets right too.
    private func startInsetTimer() {
        insetTimer?.invalidate()
        insetTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fixInsets() }
        }
    }

    private static var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private static func mainWindow(in scene: UIWindowScene) -> UIWindow? {
        scene.windows.first { $0.isKeyWindow && $0.rootViewController != nil }
            ?? scene.windows.first { $0.rootViewController != nil && !$0.isHidden }
    }
}

final class FlipAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        FlipController.shared.orientationMask
    }
}

/// Attaches the flip controller to the app's root view.
struct FlipHost: ViewModifier {
    @ObservedObject private var flip = FlipController.shared
    @AppStorage(FlipMode.key) private var modeRaw = FlipMode.off.rawValue
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            // The clock and battery would be upside down while flipped.
            .statusBarHidden(flip.flipped)
            .onAppear {
                flip.setMode(modeRaw)
                // The window may not be key yet on the first frame.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    flip.apply()
                }
            }
            .onChange(of: modeRaw) { _, value in flip.setMode(value) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { flip.sceneBecameActive() } else { flip.sceneResigned() }
            }
    }
}
