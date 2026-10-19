import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

// Swiping back: definitions and results on Search, 文法 lessons, Appearance.
//
// Every NavigationStack page carries a `BackSwipeHook` (`.backSwipePage()`); the Search
// page's hook also says where its own Back goes. The hook gives the stack one recognizer
// (`BackSwipeGesture`) that decides, from where a finger lands and which way it moves,
// whether a touch is a swipe back:
//  - from the left edge (on Search also from the right edge, to the left): any mostly
//    sideways movement, decided after a few points;
//  - anywhere else on the page (Appearance → Going back → From anywhere, on by default):
//    a clearly sideways swipe to the right, like the iPhone's own apps. Never on things
//    that drag sideways themselves: the dictionary card, a text selection's handles,
//    sliders and switches, a row that scrolls sideways, the field being typed in.
// Scrolling waits for that decision (5–10 points of movement), so a scroll is not taken
// for a swipe and a swipe is not taken for a scroll.
//
// The page then follows the finger: it slides away over the previous screen (`PageSlide`),
// or with Page-turn on it curls like a sheet of paper (`PageTurn`). Letting go past about
// a third of the width, or with a flick, finishes and goes back; otherwise it returns.
// The screen underneath is a picture taken when it was left (`PagePictures`).
//
// On NavigationStack pages with the title bar showing, a slide from the very left edge
// (`systemEdge`) is left to UIKit's own swipe (it shows the live page underneath); everything
// else is ours.

// MARK: - Pictures

/// A picture of a screen as it looked when it was left, shown under a swipe back to it.
final class PagePicture {
    fileprivate(set) var image: CGImage?
    let size: CGSize
    let look: String
    init(image: CGImage, size: CGSize, look: String) {
        self.image = image; self.size = size; self.look = look
    }
}

/// Pictures of the screens a swipe back can lead to.
@MainActor final class PagePictures {
    static let shared = PagePictures()
    /// Paper colour of the current theme (shown where there is no picture), and the theme's identity.
    var paper = UIColor.systemBackground
    var look = "" {
        didSet { if look != oldValue { forget() } }
    }

    private struct Kept { weak var picture: PagePicture? }
    private var kept: [Kept] = []
    private var tabPictures: [Int: PagePicture] = [:]
    /// Only the last few screens keep their picture; older ones go back onto plain paper.
    private static let keptLimit = 6

    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PagePictures.shared.forget() }
        }
    }

    static var window: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.windows.first { $0.isKeyWindow && $0.rootViewController != nil }
            ?? scene?.windows.first { $0.rootViewController != nil && !$0.isHidden }
    }

    func draw(_ window: UIWindow, scale: CGFloat) -> CGImage? {
        guard window.bounds.width > 0, window.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let paper = self.paper
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            paper.setFill()
            context.fill(window.bounds)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }.cgImage
    }

    /// The screen as it looks now, to show under a later swipe back to it.
    /// Call it just before the screen changes.
    func take() -> PagePicture? {
        guard !BackSwipe.busy, let window = Self.window,
              let image = draw(window, scale: min(window.screen.scale, 2)) else { return nil }
        let picture = PagePicture(image: image, size: window.bounds.size, look: look)
        kept.removeAll { $0.picture?.image == nil }
        kept.append(Kept(picture: picture))
        while kept.count > Self.keptLimit {
            let oldest = kept.removeFirst()
            oldest.picture?.image = nil
        }
        return picture
    }

    /// A tab is being left for Search: remember how it looked.
    func leaving(tab: Int) {
        tabPictures = [:]
        if let picture = take() { tabPictures[tab] = picture }
    }
    func picture(ofTab tab: Int) -> PagePicture? { tabPictures[tab] }

    func forget() {
        for item in kept { item.picture?.image = nil }
        kept = []
        tabPictures = [:]
    }

    /// The picture, if it still fits the screen as it is now (same theme, same size).
    func usable(_ picture: PagePicture?, in window: UIWindow) -> CGImage? {
        guard let picture, picture.look == look,
              abs(picture.size.width - window.bounds.width) < 0.5, abs(picture.size.height - window.bounds.height) < 0.5 else { return nil }
        return picture.image
    }
}

extension Notification.Name {
    /// A dictionary or lesson page has finished loading (a swipe back waits for it before
    /// showing the live page in place of its picture).
    static let readerPageDrawn = Notification.Name("JapaneseReader.pageDrawn")
}

// MARK: - Rules

/// Where a swipe back goes on a page that is not a push in a NavigationStack (Search).
struct BackSwipeTarget {
    /// The screen going back shows, as it looked when it was left.
    var picture: @MainActor () -> PagePicture?
    /// Goes back, without animation (the swipe has already shown it).
    var goBack: @MainActor () -> Void
    /// Going back opens a dictionary page, which takes a moment to draw.
    var leadsToWebPage: @MainActor () -> Bool = { false }
    /// The swipe has started (put the keyboard away).
    var began: @MainActor () -> Void = {}
    /// A swipe from the right edge to the left goes back too.
    var bothEdges = false
}

/// The arithmetic of the swipe back (pure, unit-tested).
enum BackSwipeRules {
    enum Start { case left, right, page }
    enum Decision { case wait, begin, fail }

    /// Whether a touch is a swipe back yet. `move` is the finger's movement since it went
    /// down (points, page coordinates), `elapsed` the time since then.
    static func decide(_ start: Start, move: CGVector, elapsed: TimeInterval) -> Decision {
        let dx = move.dx, dy = move.dy
        let distance = (dx * dx + dy * dy).squareRoot()
        switch start {
        case .left, .right:
            // From the edge almost any sideways movement counts, and it is decided early.
            let across = start == .left ? dx : -dx
            guard distance >= 6 else { return elapsed > 1.5 ? .fail : .wait }
            return across > 0 && across >= abs(dy) * 0.6 ? .begin : .fail
        case .page:
            // A clearly vertical start is a scroll: give it up at once.
            if distance >= 5 && abs(dy) > abs(dx) * 1.5 { return .fail }
            // A finger resting first is selecting text, not swiping.
            guard distance >= 10 else { return elapsed > 0.6 ? .fail : .wait }
            return dx > 0 && dx >= abs(dy) * 1.15 ? .begin : .fail
        }
    }

    /// Whether letting go finishes going back. `velocity` is along the swipe (points per second).
    static func completes(travel: CGFloat, width: CGFloat, velocity: CGFloat) -> Bool {
        if velocity > 320 { return travel > 6 }
        if velocity < -160 { return false }
        return travel + max(0, velocity) * 0.12 > width * 0.35
    }
}

@MainActor enum BackSwipe {
    /// Appearance → Going back → From anywhere on the page (on unless switched off).
    static let anywhereKey = "swipeBackAnywhere"
    /// How far from the side of the screen a touch counts as starting at the edge.
    static let edgeZone: CGFloat = 32
    /// The strip at the very left edge where UIKit's own swipe back answers (on pages pushed
    /// in a stack with the title bar showing, it is left to UIKit there).
    static let systemEdge: CGFloat = 12
    /// Set by the app: something on screen owns sideways drags (the dictionary card is open).
    static var contentBlocked: @MainActor () -> Bool = { false }
    /// Set by the app: text is selected on the dictionary or lesson page.
    static var selectionPresent: @MainActor () -> Bool = { false }
    /// Interface tests: the page stays where the finger left it for 3 s, so it can be photographed.
    static let holdsForTests = ProcessInfo.processInfo.arguments.contains("--ui-page-turn-hold")

    static var anywhere: Bool { UserDefaults.standard.object(forKey: anywhereKey) as? Bool ?? true }
    static var curls: Bool { UserDefaults.standard.bool(forKey: PageTurn.key) }
    /// A swipe (slide or page turn) is on screen.
    static var busy: Bool { PageSlide.shared.active || PageTurn.shared.active }

    /// Something is presented over the stack (a sheet, a full-screen cover).
    static func presenting(over stack: UINavigationController) -> Bool {
        stack.presentedViewController != nil || stack.view.window?.rootViewController?.presentedViewController != nil
    }

    /// UIKit's own swipe from the left edge works on this stack (its title bar is showing).
    static func systemSwipeWorks(in stack: UINavigationController) -> Bool {
        guard let pop = stack.interactivePopGestureRecognizer, pop.isEnabled,
              !stack.isNavigationBarHidden, !stack.navigationBar.isHidden, stack.navigationBar.alpha > 0.01 else { return false }
        return !(stack.topViewController?.navigationItem.hidesBackButton ?? false)
    }

    /// The touch landed on something that drags sideways itself.
    static func ownsSidewaysDrags(_ touch: UITouch, in window: UIWindow) -> Bool {
        for area in BackSwipeBlockerView.areas.allObjects where area.window === window && !area.isHidden && area.alpha > 0.01 {
            if area.bounds.contains(touch.location(in: area)) { return true }
        }
        var node = touch.view
        while let view = node, view !== window {
            if view is UISlider || view is UISwitch || view is UISegmentedControl || view is UIPageControl
                || view is UIDatePicker || view is UIPickerView { return true }
            if let field = view as? UITextField, field.isFirstResponder { return true }
            if let text = view as? UITextView, text.isEditable, text.isFirstResponder { return true }
            // A row that scrolls sideways and is not at its start: the swipe scrolls it back.
            if let scroll = view as? UIScrollView, scroll.isScrollEnabled,
               scroll.contentSize.width > scroll.bounds.width + 1,
               scroll.contentOffset.x > -scroll.adjustedContentInset.left + 1 { return true }
            node = view.superview
        }
        return false
    }

    /// Areas around the handles of the text selected on the dictionary or lesson page
    /// (window coordinates): empty when nothing is selected, nil when the page does not say.
    static func selectionHandles(in window: UIWindow) -> [CGRect]? {
        guard let page = SelectionBridge.shared.dictionaryView, page.window === window, !page.isHidden else { return [] }
        guard let content = page.scrollView.subviews.first(where: { $0 is UITextInput }) as? (UIView & UITextInput) else {
            return selectionPresent() ? nil : []
        }
        guard let range = content.selectedTextRange, !range.isEmpty else { return [] }
        let start = content.convert(content.caretRect(for: range.start), to: window)
        let end = content.convert(content.caretRect(for: range.end), to: window)
        guard !start.isNull, !end.isNull, start.minX.isFinite, end.maxX.isFinite, start.height > 0 || end.height > 0 else {
            return selectionPresent() ? nil : []
        }
        // A handle is a line along the caret with a knob above (start) or below (end) it.
        let reach: CGFloat = 36
        return [CGRect(x: start.minX - reach, y: start.minY - reach - 10, width: reach * 2, height: start.height + reach * 2 + 10),
                CGRect(x: end.maxX - reach, y: end.minY - reach, width: reach * 2, height: end.height + reach * 2 + 10)]
    }
}

// MARK: - Recognizer

/// One finger, decided by `BackSwipeRules.decide` from where it landed (`start`) and how it moves.
final class BackSwipeRecognizer: UIGestureRecognizer {
    var start = BackSwipeRules.Start.page
    /// Called when the recognizer is done with a touch (whatever came of it).
    var finished: (@MainActor () -> Void)?
    private var finger: UITouch?
    /// Where the finger went down, in the recognizer's view.
    private(set) var origin = CGPoint.zero
    private var downTime: TimeInterval = 0
    private var samples: [(time: TimeInterval, point: CGPoint)] = []

    /// A finger is down and being watched.
    var watching: Bool { finger != nil }
    /// Where the finger is now, in the recognizer's view.
    var point: CGPoint { samples.last?.point ?? origin }
    /// Points per second over the last tenth of a second, in the recognizer's view.
    var velocity: CGVector {
        guard let first = samples.first, let last = samples.last, last.time - first.time > 0.005 else { return .zero }
        let time = CGFloat(last.time - first.time)
        return CGVector(dx: (last.point.x - first.point.x) / time, dy: (last.point.y - first.point.y) / time)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard finger == nil, touches.count == 1, let touch = touches.first, let view else {
            // Another finger: a pinch, a two-finger tap or swipe, not a swipe back.
            if state == .possible { state = .failed }
            return
        }
        finger = touch
        origin = touch.location(in: view)
        downTime = touch.timestamp
        samples = [(touch.timestamp, origin)]
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let finger, touches.contains(finger), let view else { return }
        let now = finger.location(in: view)
        note(now, at: finger.timestamp)
        switch state {
        case .possible:
            let move = CGVector(dx: now.x - origin.x, dy: now.y - origin.y)
            switch BackSwipeRules.decide(start, move: move, elapsed: finger.timestamp - downTime) {
            case .begin: state = .began
            case .fail: state = .failed
            case .wait: break
            }
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let finger, touches.contains(finger) else { return }
        if let view { note(finger.location(in: view), at: finger.timestamp) }
        state = state == .began || state == .changed ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let finger, touches.contains(finger) else { return }
        state = state == .began || state == .changed ? .cancelled : .failed
    }

    override func reset() {
        super.reset()
        finger = nil
        samples.removeAll()
        finished?()
    }

    private func note(_ point: CGPoint, at time: TimeInterval) {
        samples.append((time, point))
        samples.removeAll { time - $0.time > 0.1 }
    }
}

// MARK: - The stack's swipe

/// How a swipe back looks: a slide (`PageSlide`) or a page turn (`PageTurn`).
@MainActor protocol BackSwipeStyle: AnyObject {
    var active: Bool { get }
    /// Starts a swipe taken at `point` (window coordinates). `under` is the screen going back
    /// shows; `complete` goes back once the page is gone.
    func begin(in window: UIWindow, fromLeft: Bool, at point: CGPoint, under: CGImage?,
               waitsForWebPage: Bool, complete: @escaping @MainActor () -> Void) -> Bool
    /// The finger moved to `point` (window coordinates).
    func move(to point: CGPoint)
    /// The finger was lifted; `velocity` is horizontal (window coordinates, points per second).
    func end(velocity: CGFloat)
    /// The touch was taken away (a call, the app switcher): the page returns.
    func cancel()
}

/// The swipe back of one NavigationStack: pops a pushed page, or (Search) goes where the
/// page's own Back goes.
@MainActor final class BackSwipeGesture: NSObject, UIGestureRecognizerDelegate {
    private static var association = 0
    private weak var stack: UINavigationController?
    /// Where a swipe goes when nothing was pushed (the Search page's own Back).
    var target: BackSwipeTarget?
    private let pictures = NSMapTable<UIViewController, PagePicture>.weakToStrongObjects()
    private let recognizer = BackSwipeRecognizer(target: nil, action: nil)
    /// The watched touch would go to `target` (not pop a page).
    private var toTarget = false
    /// The style showing the swipe in progress.
    private var style: BackSwipeStyle?
    /// A swipe from the page turns as if the sheet were taken at its edge.
    private var shift: CGFloat = 0

    @discardableResult
    static func install(on stack: UINavigationController) -> BackSwipeGesture {
        if let existing = objc_getAssociatedObject(stack, &association) as? BackSwipeGesture { return existing }
        let gesture = BackSwipeGesture(stack)
        objc_setAssociatedObject(stack, &association, gesture, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return gesture
    }

    private init(_ stack: UINavigationController) {
        self.stack = stack
        super.init()
        recognizer.addTarget(self, action: #selector(swiped(_:)))
        recognizer.delegate = self
        recognizer.delaysTouchesEnded = false
        recognizer.finished = { PageTurn.shared.dropPrepared() }
        stack.view.addGestureRecognizer(recognizer)
    }

    /// The picture of `page`, shown under a swipe back to it.
    func keep(_ picture: PagePicture?, for page: UIViewController) {
        if let picture { pictures.setObject(picture, forKey: page) } else { pictures.removeObject(forKey: page) }
    }

    @objc private func swiped(_ recognizer: BackSwipeRecognizer) {
        switch recognizer.state {
        case .began:
            begin()
        case .changed:
            if let window = stack?.view.window { style?.move(to: finger(in: window)) }
        case .ended:
            style?.end(velocity: recognizer.velocity.dx)
            style = nil
        case .cancelled, .failed:
            style?.cancel()
            style = nil
        default:
            break
        }
    }

    private func begin() {
        guard let stack, let window = stack.view.window else { stop(); return }
        let style: BackSwipeStyle = BackSwipe.curls ? PageTurn.shared as BackSwipeStyle : PageSlide.shared as BackSwipeStyle
        let origin = stack.view.convert(recognizer.origin, to: window)
        shift = recognizer.start == .page ? -origin.x : 0
        let under: CGImage?, goBack: @MainActor () -> Void, waits: Bool
        if toTarget, let target {
            under = PagePictures.shared.usable(target.picture(), in: window)
            goBack = target.goBack
            waits = target.leadsToWebPage()
        } else {
            let pages = stack.viewControllers
            guard pages.count > 1 else { stop(); return }
            under = PagePictures.shared.usable(pictures.object(forKey: pages[pages.count - 2]), in: window)
            goBack = { [weak stack] in stack?.popViewController(animated: false) }
            waits = false
        }
        guard style.begin(in: window, fromLeft: recognizer.start != .right, at: CGPoint(x: origin.x + shift, y: origin.y),
                          under: under, waitsForWebPage: waits, complete: goBack) else { stop(); return }
        self.style = style
        if toTarget { target?.began() }
        style.move(to: finger(in: window))
    }

    /// The finger, moved like the start of the swipe (window coordinates).
    private func finger(in window: UIWindow) -> CGPoint {
        let point = stack?.view.convert(recognizer.point, to: window) ?? recognizer.point
        return CGPoint(x: point.x + shift, y: point.y)
    }

    /// Gives up the touch (nothing to go back to after all).
    private func stop() {
        recognizer.isEnabled = false
        recognizer.isEnabled = true
    }

    // MARK: Which touches

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Another finger while one is watched: it ends the watch (see the recognizer).
        if recognizer.watching { return true }
        guard !BackSwipe.busy, let stack, let window = stack.view.window,
              stack.transitionCoordinator == nil, !BackSwipe.presenting(over: stack) else { return false }
        let pops = stack.viewControllers.count > 1
        guard pops || target != nil else { return false }
        let view: UIView = stack.view
        let point = touch.location(in: view)
        let start: BackSwipeRules.Start
        if point.x <= BackSwipe.edgeZone { start = .left }
        else if !pops, target?.bothEdges == true, point.x >= view.bounds.width - BackSwipe.edgeZone { start = .right }
        else { start = .page }
        if start == .page && (!BackSwipe.anywhere || BackSwipe.contentBlocked()) { return false }
        // UIKit's own swipe from the very edge shows the live page underneath: it keeps the
        // strip it answers to (a little narrower than this edge, which takes the rest).
        if pops, start == .left, point.x <= BackSwipe.systemEdge, !BackSwipe.curls, BackSwipe.systemSwipeWorks(in: stack) { return false }
        if BackSwipe.ownsSidewaysDrags(touch, in: window) { return false }
        let spot = touch.location(in: window)
        if let handles = BackSwipe.selectionHandles(in: window) {
            if handles.contains(where: { $0.contains(spot) }) { return false }
        } else if start == .page {
            // Text is selected and the page does not say where: leave the page to the selection.
            return false
        }
        if BackSwipe.curls && start != .page { PageTurn.shared.prepare(window) }
        recognizer.start = start
        toTarget = !pops
        return true
    }

    /// Scrolling waits until the touch is known not to be a swipe back (5–10 points), and so
    /// does UIKit's own edge swipe where this one takes the edge (page turn, hidden title bar).
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        if let scroll = other.view as? UIScrollView, other === scroll.panGestureRecognizer { return true }
        return other === stack?.interactivePopGestureRecognizer
    }
}

// MARK: - Hook

/// Put in the background of every page of a NavigationStack (`.backSwipePage()`), and of the
/// Search page with where its Back goes. It gives the stack its swipe back, and keeps a
/// picture of a page when another is pushed over it.
struct BackSwipeHook: UIViewControllerRepresentable {
    var target: BackSwipeTarget? = nil
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.target = target
        controller.attach()
    }

    final class Controller: UIViewController {
        var target: BackSwipeTarget?
        private weak var stack: UINavigationController?
        private weak var page: UIViewController?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
        }
        override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); attach() }
        override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); attach() }

        func attach() {
            guard let stack = navigationController else { return }
            self.stack = stack
            var node: UIViewController = self
            while let parent = node.parent, parent !== stack { node = parent }
            page = node.parent === stack ? node : nil
            let gesture = BackSwipeGesture.install(on: stack)
            if let target { gesture.target = target }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // Covered by a pushed page (not popped, not another tab): keep its picture.
            guard let stack, let page, let top = stack.viewControllers.last, top !== page,
                  stack.viewControllers.contains(page) else { return }
            BackSwipeGesture.install(on: stack).keep(PagePictures.shared.take(), for: page)
        }
    }
}

extension View {
    /// A page of a NavigationStack: it can be swiped back from, and swiped back to.
    func backSwipePage() -> some View { background(BackSwipeHook()) }
}

/// Marks an area that drags sideways itself (the dictionary card): no swipe back starts there.
struct BackSwipeBlocker: UIViewRepresentable {
    func makeUIView(context: Context) -> BackSwipeBlockerView { BackSwipeBlockerView() }
    func updateUIView(_ view: BackSwipeBlockerView, context: Context) {}
}

final class BackSwipeBlockerView: UIView {
    static let areas = NSHashTable<UIView>.weakObjects()
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        Self.areas.add(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Slide

/// The page slides away under the finger and the previous screen comes in from underneath,
/// a little behind, the way iPhone apps go back. The tab bar stays where it is.
@MainActor final class PageSlide: BackSwipeStyle {
    static let shared = PageSlide()
    private enum Phase { case idle, tracking, holding, settling, leaving }
    private var phase = Phase.idle
    private var view: PageSlideView?
    private var animator: UIViewPropertyAnimator?
    private var start = CGPoint.zero
    private var fromLeft = true
    private var travel: CGFloat = 0
    private var complete: (@MainActor () -> Void)?
    private var waitsForWebPage = false
    private var windowSize = CGSize.zero

    var active: Bool { phase != .idle }

    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PageSlide.shared.cancel() }
        }
    }

    func begin(in window: UIWindow, fromLeft: Bool, at point: CGPoint, under: CGImage?,
               waitsForWebPage: Bool, complete: @escaping @MainActor () -> Void) -> Bool {
        guard phase == .idle, let root = window.rootViewController?.view,
              let sheet = root.snapshotView(afterScreenUpdates: false) else { return false }
        let region = Self.region(in: window)
        guard region.width > 0, region.height > 0 else { return false }
        sheet.frame = root.convert(root.bounds, to: window).offsetBy(dx: -region.minX, dy: -region.minY)
        let view = PageSlideView(frame: region, sheet: sheet, under: Self.crop(under, to: region, in: window),
                                 paper: PagePictures.shared.paper, fromLeft: fromLeft)
        window.addSubview(view)
        self.view = view
        self.start = point
        self.fromLeft = fromLeft
        self.complete = complete
        self.waitsForWebPage = waitsForWebPage
        travel = 0
        windowSize = window.bounds.size
        phase = .tracking
        view.show(travel: 0)
        return true
    }

    func move(to point: CGPoint) {
        guard phase == .tracking, let view else { return }
        guard view.window?.bounds.size == windowSize else { finish(); return }
        travel = max(0, (fromLeft ? 1 : -1) * (point.x - start.x))
        view.show(travel: travel)
    }

    func end(velocity: CGFloat) {
        guard phase == .tracking, let view else { return }
        let along = (fromLeft ? 1 : -1) * velocity
        let completes = BackSwipeRules.completes(travel: travel, width: view.bounds.width, velocity: along)
        if BackSwipe.holdsForTests {
            phase = .holding
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                MainActor.assumeIsolated {
                    guard PageSlide.shared.phase == .holding else { return }
                    PageSlide.shared.settle(completes: completes, velocity: 0)
                }
            }
            return
        }
        settle(completes: completes, velocity: along)
    }

    func cancel() {
        guard phase == .tracking || phase == .holding else { return }
        settle(completes: false, velocity: 0)
    }

    private func settle(completes: Bool, velocity: CGFloat) {
        guard let view else { finish(); return }
        phase = .settling
        let width = view.bounds.width
        let distance = completes ? width - travel : travel
        let speed = completes ? velocity : -velocity
        // Carries on at the finger's speed instead of starting from rest.
        let initial = distance > 1 ? min(max(speed / distance, 0), 12) : 0
        let timing = UISpringTimingParameters(dampingRatio: 1, initialVelocity: CGVector(dx: initial, dy: 0))
        let animator = UIViewPropertyAnimator(duration: completes ? 0.34 : 0.3, timingParameters: timing)
        animator.addAnimations { view.show(travel: completes ? width : 0) }
        animator.addCompletion { _ in
            MainActor.assumeIsolated {
                if completes { PageSlide.shared.leave() } else { PageSlide.shared.finish() }
            }
        }
        self.animator = animator
        animator.startAnimation()
    }

    /// The page is gone: go back underneath, then let the live screen take the picture's place.
    private func leave() {
        phase = .leaving
        animator = nil
        let action = complete
        complete = nil
        action?()
        guard let view else { phase = .idle; return }
        view.isUserInteractionEnabled = false
        _ = PageReadyWait(waitsForWebPage: waitsForWebPage) {
            UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                view.alpha = 0
            } completion: { _ in
                MainActor.assumeIsolated { PageSlide.shared.finish() }
            }
        }
    }

    private func finish() {
        if let animator, animator.state == .active { animator.stopAnimation(true) }
        animator = nil
        view?.removeFromSuperview()
        view = nil
        complete = nil
        phase = .idle
    }

    /// The part of the window that slides: all of it but a tab bar along the bottom.
    static func region(in window: UIWindow) -> CGRect {
        var region = window.bounds
        if let bar = tabBar(in: window), bar.window === window, !bar.isHidden, bar.alpha > 0.01 {
            let frame = bar.convert(bar.bounds, to: window)
            if frame.minY > window.bounds.midY && frame.minY < region.maxY { region.size.height = frame.minY - region.minY }
        }
        return region
    }

    private static func tabBar(in window: UIWindow) -> UITabBar? {
        var queue = [window.rootViewController].compactMap { $0 }
        while !queue.isEmpty {
            let controller = queue.removeFirst()
            if let tabs = controller as? UITabBarController { return tabs.tabBar }
            queue += controller.children
        }
        return nil
    }

    /// The part of a whole-window picture that falls in `region`.
    private static func crop(_ image: CGImage?, to region: CGRect, in window: UIWindow) -> CGImage? {
        guard let image, window.bounds.width > 0 else { return image }
        let scale = CGFloat(image.width) / window.bounds.width
        let rect = CGRect(x: (region.minX - window.bounds.minX) * scale, y: (region.minY - window.bounds.minY) * scale,
                          width: region.width * scale, height: region.height * scale).integral
        return image.cropping(to: rect) ?? image
    }
}

/// One moment of the slide: the screen underneath (a little to the side and dimmed), and
/// the page on top with a soft shadow along its moving edge.
final class PageSlideView: UIView {
    private let underlay = UIImageView()
    private let dim = UIView()
    private let sheet = UIView()
    private let shadow = SlideShadowView()
    private let direction: CGFloat
    /// How far to the side the screen underneath starts (share of the width).
    private static let parallax: CGFloat = 0.3
    private static let shadowWidth: CGFloat = 14

    init(frame: CGRect, sheet page: UIView, under: CGImage?, paper: UIColor, fromLeft: Bool) {
        direction = fromLeft ? 1 : -1
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = paper
        accessibilityIdentifier = "backSwipe"
        underlay.frame = bounds
        underlay.backgroundColor = paper
        underlay.contentMode = .scaleToFill
        if let under { underlay.image = UIImage(cgImage: under) }
        addSubview(underlay)
        dim.frame = bounds
        dim.backgroundColor = .black
        addSubview(dim)
        sheet.frame = bounds
        sheet.addSubview(page)
        shadow.frame = CGRect(x: fromLeft ? -Self.shadowWidth : bounds.width, y: 0, width: Self.shadowWidth, height: bounds.height)
        shadow.gradient.colors = fromLeft
            ? [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.withAlphaComponent(0.16).cgColor]
            : [UIColor.black.withAlphaComponent(0.16).cgColor, UIColor.black.withAlphaComponent(0).cgColor]
        shadow.gradient.startPoint = CGPoint(x: 0, y: 0.5)
        shadow.gradient.endPoint = CGPoint(x: 1, y: 0.5)
        sheet.addSubview(shadow)
        addSubview(sheet)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(travel: CGFloat) {
        let width = max(bounds.width, 1)
        let progress = min(1, max(0, travel / width))
        sheet.transform = CGAffineTransform(translationX: direction * travel, y: 0)
        underlay.transform = CGAffineTransform(translationX: -direction * width * Self.parallax * (1 - progress), y: 0)
        dim.alpha = 0.12 * (1 - progress)
        shadow.alpha = 1 - progress * 0.5
    }
}

private final class SlideShadowView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    var gradient: CAGradientLayer { layer as! CAGradientLayer }
}

/// After going back: runs `then` once the screen underneath has been drawn. A dictionary
/// page is a new web page, so that waits for it to load (at most 0.7 s).
@MainActor final class PageReadyWait: NSObject {
    private var then: (@MainActor () -> Void)?

    init(waitsForWebPage: Bool, then: @escaping @MainActor () -> Void) {
        self.then = then
        super.init()
        if waitsForWebPage {
            NotificationCenter.default.addObserver(self, selector: #selector(pageDrawn), name: .readerPageDrawn, object: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (waitsForWebPage ? 0.7 : 0.05)) {
            MainActor.assumeIsolated { self.finish() }
        }
    }

    @objc private func pageDrawn() {
        // A couple of frames for the loaded page to reach the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            MainActor.assumeIsolated { self.finish() }
        }
    }

    private func finish() {
        guard let then else { return }
        self.then = nil
        NotificationCenter.default.removeObserver(self)
        then()
    }
}
