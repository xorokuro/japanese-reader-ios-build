import SwiftUI

// Intercept tab reselection and forward all other delegate behavior to SwiftUI.
struct SearchTabObserver: UIViewControllerRepresentable {
    let selected: () -> Void
    func makeUIViewController(context: Context) -> ObserverController { ObserverController() }
    func updateUIViewController(_ controller: ObserverController, context: Context) {
        controller.selected = selected
        controller.install()
    }
    static func dismantleUIViewController(_ controller: ObserverController, coordinator: ()) {
        controller.detach()
    }
    final class ObserverController: UIViewController, UITabBarControllerDelegate {
        var selected: (() -> Void)?
        private weak var tabs: UITabBarController?
        private weak var original: UITabBarControllerDelegate?
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); install() }
        override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); install() }
        func install() {
            guard let controller = tabBarController, controller.delegate !== self else { return }
            tabs = controller
            original = controller.delegate
            controller.delegate = self
        }
        func detach() {
            if tabs?.delegate === self { tabs?.delegate = original }
        }
        func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
            let allowed = original?.tabBarController?(tabBarController, shouldSelect: viewController) ?? true
            if allowed, tabBarController.viewControllers?.firstIndex(of: viewController) == 1 {
                DispatchQueue.main.async { [weak self] in self?.selected?() }
            }
            return allowed
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            if original?.responds(to: selector) == true { return original }
            return super.forwardingTarget(for: selector)
        }
    }
}
