import SwiftUI
import UIKit

// Page-turn back swipe (Appearance → Going back, off by default).
//
// Swiping back peels the current screen away like a sheet of paper: its edge
// follows the finger, the sheet rolls over a cylinder, and the screen underneath
// shows through. Letting go far enough finishes the turn and goes back; letting go
// early lays the sheet down again.
//
// How it is put together:
//  - PageTurnGeometry: the arithmetic of the roll (pure, unit-tested).
//  - PageTurnView: draws one moment of the turn from two pictures.
//  - PageTurn: follows the finger, settles the turn, and keeps the pictures.
//  - PageTurnStackHook: the same gesture for pages pushed in a NavigationStack.
//
// Nothing below runs, and no picture is taken, while the setting is off.

// MARK: - Geometry

enum PageTurnGeometry {
    /// Radius of the cylinder the sheet rolls over.
    static func radius(width: CGFloat) -> CGFloat { min(60, max(34, width * 0.115)) }

    /// How far the sheet's free edge has travelled when the roll touches the page at
    /// `contact` (distances across the fold, from where the edge started).
    static func edgeTravel(contact: CGFloat, radius: CGFloat) -> CGFloat {
        guard contact > 0 else { return 0 }
        return contact <= .pi * radius ? contact - radius * sin(contact / radius) : 2 * contact - .pi * radius
    }

    /// The reverse: where the roll must be for the edge to sit under the finger.
    static func contact(forTravel travel: CGFloat, radius: CGFloat) -> CGFloat {
        guard travel > 0 else { return 0 }
        if travel >= .pi * radius { return (travel + .pi * radius) / 2 }
        var low: CGFloat = 0, high = .pi * radius
        for _ in 0..<32 {
            let middle = (low + high) / 2
            if edgeTravel(contact: middle, radius: radius) < travel { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }

    /// Leftmost point the lifted sheet still covers; everything before it shows the screen underneath.
    static func silhouette(contact: CGFloat, radius: CGFloat) -> CGFloat {
        contact <= .pi * radius / 2 ? edgeTravel(contact: contact, radius: radius) : contact - radius
    }

    /// Lean of the fold line (radians): a sheet taken near the top peels from the top
    /// corner, and dragging down or up while turning leans it further.
    static func tilt(start: CGPoint, finger: CGPoint, height: CGFloat, fromLeft: Bool) -> CGFloat {
        let direction: CGFloat = fromLeft ? 1 : -1
        let across = direction * (finger.x - start.x)
        let along = finger.y - start.y
        let bias = height > 0 ? (0.5 - start.y / height) * 2 * (7 * .pi / 180) : 0
        let limit: CGFloat = 13 * .pi / 180
        let lean = bias + atan2(along, max(across, 60)) * 0.5
        return min(limit, max(-limit, lean)) * direction
    }

    /// Whether letting go finishes the turn. `velocity` is along the turn (points per second).
    static func completes(travel: CGFloat, width: CGFloat, velocity: CGFloat) -> Bool {
        if velocity > 700 { return true }
        if velocity < -250 { return false }
        return travel > width * 0.36
    }
}

// MARK: - Pictures

/// A picture of a screen as it looked when it was left, shown under the turning sheet.
final class PagePicture {
    fileprivate(set) var image: CGImage?
    let size: CGSize
    let look: String
    init(image: CGImage, size: CGSize, look: String) {
        self.image = image; self.size = size; self.look = look
    }
}

// MARK: - Drawing

final class PageTurnView: UIView {
    struct Pose: Equatable {
        /// Where the roll touches the page, across the fold from the sheet's free edge.
        var contact: CGFloat
        /// Lean of the fold line.
        var tilt: CGFloat
    }

    private struct Strip {
        let box = CALayer()
        let image = CALayer()
        let shade = CALayer()
    }

    private static let curveCount = 40
    private static let overlap: CGFloat = 0.6
    private static let edgeShadowWidth: CGFloat = 36

    let radius: CGFloat
    private let direction: CGFloat
    private let pivot: CGPoint
    private let side: CGFloat
    private let underlay = CALayer()
    private let dim = CALayer()
    private let stage = CALayer()
    private let cast = CAGradientLayer()
    private let flat = Strip()
    private let flap = Strip()
    private var curve: [Strip] = []
    private(set) var pose = Pose(contact: 0, tilt: 0)

    init(frame: CGRect, page: CGImage, under: CGImage?, paper: UIColor, fromLeft: Bool, pivot: CGPoint) {
        radius = PageTurnGeometry.radius(width: frame.width)
        direction = fromLeft ? 1 : -1
        self.pivot = pivot
        side = 2 * hypot(frame.width, frame.height) + 200
        super.init(frame: frame)
        backgroundColor = paper
        clipsToBounds = true
        isOpaque = true
        accessibilityIdentifier = "pageTurn"

        underlay.frame = bounds
        underlay.contents = under
        underlay.contentsGravity = .resize
        underlay.backgroundColor = paper.cgColor
        layer.addSublayer(underlay)
        dim.frame = bounds
        dim.backgroundColor = UIColor.black.cgColor
        dim.opacity = 0
        layer.addSublayer(dim)

        stage.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        stage.position = pivot
        layer.addSublayer(stage)

        // Shadow the lifted sheet throws on the screen underneath.
        cast.colors = [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.withAlphaComponent(0.34).cgColor]
        cast.startPoint = CGPoint(x: fromLeft ? 0 : 1, y: 0.5)
        cast.endPoint = CGPoint(x: fromLeft ? 1 : 0, y: 0.5)
        stage.addSublayer(cast)

        var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
        paper.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        // On dark paper the back of the sheet is a little lighter, so the roll stands out.
        if 0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.4 {
            red += (1 - red) * 0.13; green += (1 - green) * 0.13; blue += (1 - blue) * 0.13
        }
        // The back of the sheet: paper, with the print faintly showing through.
        func back(_ shade: CGFloat) -> CGColor {
            UIColor(red: red * (1 - shade), green: green * (1 - shade), blue: blue * (1 - shade), alpha: 0.9).cgColor
        }
        func prepare(_ strip: Strip, angle: CGFloat, color: CGColor?) {
            strip.box.masksToBounds = true
            strip.box.allowsEdgeAntialiasing = true
            strip.box.transform = CATransform3DMakeRotation(direction * angle, 0, 1, 0)
            strip.image.bounds = bounds
            strip.image.contents = page
            strip.image.contentsGravity = .resize
            strip.image.allowsEdgeAntialiasing = true
            strip.shade.frame = bounds
            strip.shade.backgroundColor = color
            strip.shade.isHidden = color == nil
            strip.image.addSublayer(strip.shade)
            strip.box.addSublayer(strip.image)
            stage.addSublayer(strip.box)
        }
        // Back to front: the part still lying flat, the roll from its foot to its top, then the flap.
        prepare(flat, angle: 0, color: nil)
        let step = CGFloat.pi / CGFloat(Self.curveCount)
        for index in 0..<Self.curveCount {
            let angle = (CGFloat(index) + 0.5) * step
            let strip = Strip()
            let color: CGColor = angle < .pi / 2
                ? UIColor.black.withAlphaComponent(0.34 * pow(sin(angle), 1.5)).cgColor
                : back(0.05 + 0.30 * pow(sin(angle), 2.2))
            prepare(strip, angle: angle, color: color)
            strip.box.zPosition = radius * (1 - cos(angle))
            curve.append(strip)
        }
        prepare(flap, angle: .pi, color: back(0.05))
        flap.box.zPosition = 2 * radius
        // Shadow just past the sheet's free edge, carried along by the flap.
        let edge = CAGradientLayer()
        edge.colors = [UIColor.black.withAlphaComponent(0.30).cgColor, UIColor.black.withAlphaComponent(0).cgColor]
        edge.startPoint = CGPoint(x: fromLeft ? 1 : 0, y: 0.5)
        edge.endPoint = CGPoint(x: fromLeft ? 0 : 1, y: 0.5)
        edge.frame = CGRect(x: fromLeft ? -Self.edgeShadowWidth : bounds.width, y: 0, width: Self.edgeShadowWidth, height: bounds.height)
        flap.image.addSublayer(edge)
        show(pose)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Distance across the fold from the pivot to a point of the screen, for a given lean.
    private func across(_ point: CGPoint, tilt: CGFloat) -> CGFloat {
        direction * ((point.x - pivot.x) * cos(tilt) + (point.y - pivot.y) * sin(tilt))
    }
    private func extent(tilt: CGFloat) -> (low: CGFloat, high: CGFloat) {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: bounds.width, y: 0), CGPoint(x: 0, y: bounds.height), CGPoint(x: bounds.width, y: bounds.height)]
            .map { across($0, tilt: tilt) }
        return (corners.min() ?? 0, corners.max() ?? 0)
    }
    /// The finger's distance across the fold: how far the sheet's edge has been carried.
    func travel(of finger: CGPoint, tilt: CGFloat) -> CGFloat { max(0, across(finger, tilt: tilt)) }
    /// Where the roll is once the whole sheet has left the screen.
    func endContact(tilt: CGFloat) -> CGFloat { extent(tilt: tilt).high + radius + 2 }

    func show(_ pose: Pose) {
        self.pose = pose
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let contact = pose.contact, tilt = pose.tilt
        let (low, high) = extent(tilt: tilt)
        let progress = min(1, max(0, contact / (high + radius + 2)))
        dim.opacity = Float(0.16 * (1 - progress))
        stage.setAffineTransform(CGAffineTransform(rotationAngle: tilt))

        // The page picture's centre in stage coordinates, and the turn that keeps it upright.
        let centre = CGPoint(x: bounds.midX - pivot.x, y: bounds.midY - pivot.y)
        let image = CGPoint(x: side / 2 + centre.x * cos(tilt) + centre.y * sin(tilt),
                            y: side / 2 - centre.x * sin(tilt) + centre.y * cos(tilt))
        let upright = CGAffineTransform(rotationAngle: -tilt)

        func place(_ strip: Strip, from start: CGFloat, to end: CGFloat, centre: CGFloat) {
            let width = end - start
            guard width > 0.01 else { strip.box.isHidden = true; return }
            strip.box.isHidden = false
            strip.box.bounds = CGRect(x: 0, y: 0, width: width, height: side)
            strip.box.position = CGPoint(x: side / 2 + direction * centre, y: side / 2)
            let origin = min(side / 2 + direction * start, side / 2 + direction * end)
            strip.image.position = CGPoint(x: image.x - origin, y: image.y)
            strip.image.setAffineTransform(upright)
        }

        let lift = min(1, contact / (.pi * radius / 2))
        let silhouette = PageTurnGeometry.silhouette(contact: contact, radius: radius)
        let shadow = 46 * lift
        cast.opacity = Float(lift)
        cast.frame = CGRect(x: side / 2 + (direction > 0 ? silhouette - shadow : -silhouette), y: 0, width: shadow, height: side)

        let flatStart = max(contact, low)
        place(flat, from: flatStart, to: high + 1, centre: (flatStart + high + 1) / 2)

        let arc = CGFloat.pi * radius
        let step = arc / CGFloat(Self.curveCount)
        for (index, strip) in curve.enumerated() {
            let end = contact - CGFloat(index) * step
            let start = end - step
            if end < low { strip.box.isHidden = true; continue }
            let angle = (CGFloat(index) + 0.5) * step / radius
            place(strip, from: start, to: end + Self.overlap, centre: contact - radius * sin(angle))
        }

        if contact - arc > low {
            let start = low - Self.edgeShadowWidth - 4, end = contact - arc
            let middle = (start + end + Self.overlap) / 2
            place(flap, from: start, to: end + Self.overlap, centre: contact + (contact - middle - arc))
        } else {
            flap.box.isHidden = true
        }
        CATransaction.commit()
    }

    /// Shows the live screen through the picture underneath (after going back).
    func revealLive() {
        backgroundColor = .clear
        isOpaque = false
    }
}

// MARK: - Controller

@MainActor final class PageTurn: NSObject {
    static let shared = PageTurn()
    static let key = "pageTurnBack"
    /// Interface tests: the turn stays where the finger left it for a moment, so it can be photographed.
    private static let holdsForTests = ProcessInfo.processInfo.arguments.contains("--ui-page-turn-hold")

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.key) }
    /// Paper colour of the current theme (the back of the sheet), and the theme's identity.
    var paper = UIColor.systemBackground
    var look = "" {
        didSet { if look != oldValue { forgetPictures() } }
    }

    private enum Phase { case idle, tracking, holding, settling, leaving }
    private var phase = Phase.idle
    private var view: PageTurnView?
    private var link: CADisplayLink?
    private var fromLeft = true
    private var start = CGPoint.zero
    private var began: CFTimeInterval = 0
    private var target = PageTurnView.Pose(contact: 0, tilt: 0)
    private var travel: CGFloat = 0
    private var complete: (() -> Void)?
    private var settleFrom = PageTurnView.Pose(contact: 0, tilt: 0)
    private var settleStart: CFTimeInterval = 0
    private var settleDuration: CFTimeInterval = 0.3
    private var settleCompletes = false

    /// True from the first movement until the screen is back to normal.
    var active: Bool { phase != .idle }
    /// True while a finger is turning the page.
    var tracking: Bool { phase == .tracking }

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if PageTurn.shared.tracking { PageTurn.shared.cancel() } }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PageTurn.shared.forgetPictures() }
        }
    }

    // MARK: Pictures

    private struct Kept { weak var picture: PagePicture? }
    private var kept: [Kept] = []
    private var tabPictures: [Int: PagePicture] = [:]
    private static let keptLimit = 6

    static var window: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.windows.first { $0.isKeyWindow && $0.rootViewController != nil }
            ?? scene?.windows.first { $0.rootViewController != nil && !$0.isHidden }
    }

    private func draw(_ window: UIWindow, scale: CGFloat) -> CGImage? {
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

    /// The screen as it looks now, to show under a later turn back to it.
    /// Call it just before the screen changes. Nil while the setting is off.
    func picture() -> PagePicture? {
        guard enabled, !active, let window = Self.window,
              let image = draw(window, scale: min(window.screen.scale, 2)) else { return nil }
        let picture = PagePicture(image: image, size: window.bounds.size, look: look)
        kept.removeAll { $0.picture?.image == nil }
        kept.append(Kept(picture: picture))
        // Only the last few screens keep their picture; older ones turn back onto plain paper.
        while kept.count > Self.keptLimit {
            let oldest = kept.removeFirst()
            oldest.picture?.image = nil
        }
        return picture
    }

    /// A tab is being left for Search: remember how it looked.
    func leaving(tab: Int) {
        tabPictures = [:]
        if let picture = picture() { tabPictures[tab] = picture }
    }
    func picture(ofTab tab: Int) -> PagePicture? { tabPictures[tab] }

    private func forgetPictures() {
        for item in kept { item.picture?.image = nil }
        kept = []
        tabPictures = [:]
    }

    private func usable(_ picture: PagePicture?, in window: UIWindow) -> CGImage? {
        guard let picture, picture.look == look,
              abs(picture.size.width - window.bounds.width) < 0.5, abs(picture.size.height - window.bounds.height) < 0.5 else { return nil }
        return picture.image
    }

    // MARK: Following the finger

    /// Starts a turn. `point` is where the finger went down, in window coordinates;
    /// `under` is the screen going back leads to; `complete` goes back (without animation).
    @discardableResult
    func begin(fromLeft: Bool, at point: CGPoint, under: PagePicture?, complete: @escaping () -> Void) -> Bool {
        guard enabled, !active, let window = Self.window, let page = draw(window, scale: window.screen.scale) else { return false }
        self.fromLeft = fromLeft
        start = point
        // The sheet is held by its edge, at the height of the finger.
        let pivot = CGPoint(x: fromLeft ? 0 : window.bounds.width, y: min(max(point.y, 0), window.bounds.height))
        let view = PageTurnView(frame: window.bounds, page: page, under: usable(under, in: window), paper: paper,
                                fromLeft: fromLeft, pivot: pivot)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(view)
        self.view = view
        self.complete = complete
        target = PageTurnView.Pose(contact: 0, tilt: 0)
        travel = 0
        phase = .tracking
        began = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        return true
    }

    /// The finger moved to `point` (window coordinates).
    func move(to point: CGPoint) {
        guard phase == .tracking, let view else { return }
        let tilt = PageTurnGeometry.tilt(start: start, finger: point, height: view.bounds.height, fromLeft: fromLeft)
        travel = view.travel(of: point, tilt: tilt)
        target = PageTurnView.Pose(contact: PageTurnGeometry.contact(forTravel: travel, radius: view.radius), tilt: tilt)
    }

    /// The finger was lifted. `velocity` is horizontal, in window coordinates.
    func end(velocity: CGFloat) {
        guard phase == .tracking, let view else { return }
        let along = (fromLeft ? 1 : -1) * velocity
        let completes = PageTurnGeometry.completes(travel: travel, width: view.bounds.width, velocity: along)
        if Self.holdsForTests {
            phase = .holding
            view.show(target)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.phase == .holding else { return }
                    self.settle(completes: completes)
                }
            }
            return
        }
        settle(completes: completes)
    }

    /// The gesture was taken away (a call, the app switcher): lay the page down again.
    func cancel() {
        guard phase == .tracking else { return }
        settle(completes: false)
    }

    /// For gestures that report no cancellation: called when the touch is gone.
    func fingerLifted() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.phase == .tracking else { return }
                self.cancel()
            }
        }
    }

    private func settle(completes: Bool) {
        guard let view else { return }
        settleFrom = view.pose
        settleCompletes = completes
        settleStart = CACurrentMediaTime()
        let end = view.endContact(tilt: 0)
        let share = end > 0 ? Double(min(1, max(0, view.pose.contact / end))) : 0
        settleDuration = completes ? 0.24 + 0.26 * (1 - share) : 0.16 + 0.24 * share
        phase = .settling
        if completes { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let view else { finish(); return }
        if let window = view.window, window.bounds.size != view.bounds.size { finish(); return }
        let now = CACurrentMediaTime()
        switch phase {
        case .tracking:
            // The sheet rises under the finger over the first moments instead of jumping up.
            let rise = min(1, (now - began) / 0.16)
            let eased = CGFloat(rise * (2 - rise))
            view.show(PageTurnView.Pose(contact: target.contact * eased, tilt: target.tilt))
        case .settling:
            let time = min(1, (now - settleStart) / max(settleDuration, 0.01))
            let eased = CGFloat(1 - pow(1 - time, 3))
            if settleCompletes {
                let tilt = settleFrom.tilt * (1 - eased)
                let end = view.endContact(tilt: tilt)
                view.show(PageTurnView.Pose(contact: settleFrom.contact + (end - settleFrom.contact) * eased, tilt: tilt))
            } else {
                view.show(PageTurnView.Pose(contact: settleFrom.contact * (1 - eased), tilt: settleFrom.tilt))
            }
            if time >= 1 { settleCompletes ? leave() : finish() }
        case .idle, .holding, .leaving:
            break
        }
    }

    /// The sheet is gone: go back underneath, then fade the picture into the live screen.
    private func leave() {
        phase = .leaving
        link?.invalidate()
        link = nil
        let action = complete
        complete = nil
        action?()
        guard let view else { phase = .idle; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [weak self] in
            MainActor.assumeIsolated {
                view.revealLive()
                UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
                    view.alpha = 0
                } completion: { _ in
                    MainActor.assumeIsolated { self?.finish() }
                }
            }
        }
    }

    private func finish() {
        link?.invalidate()
        link = nil
        view?.removeFromSuperview()
        view = nil
        complete = nil
        phase = .idle
    }
}

// MARK: - NavigationStack pages

/// Put in the background of every page of a NavigationStack. It remembers how the
/// page looked when another was pushed over it, and gives the stack the page-turn
/// swipe (from the left edge) in place of the system's slide while the setting is on.
struct PageTurnStackHook: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.attach() }

    final class Controller: UIViewController {
        private weak var stack: UINavigationController?
        private weak var page: UIViewController?

        override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); attach() }
        override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); attach() }

        func attach() {
            guard let stack = navigationController else { return }
            self.stack = stack
            var node: UIViewController = self
            while let parent = node.parent, parent !== stack { node = parent }
            page = node.parent === stack ? node : nil
            PageTurnStackGesture.install(on: stack)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // Covered by a pushed page (not popped, not another tab): keep its picture.
            guard let stack, let page, let top = stack.viewControllers.last, top !== page,
                  stack.viewControllers.contains(page) else { return }
            PageTurnStackGesture.install(on: stack).keep(PageTurn.shared.picture(), for: page)
        }
    }
}

@MainActor final class PageTurnStackGesture: NSObject, UIGestureRecognizerDelegate {
    private static var association = 0
    private static let edgeWidth: CGFloat = 22
    private weak var stack: UINavigationController?
    private let pictures = NSMapTable<UIViewController, PagePicture>.weakToStrongObjects()
    private var pan: UIPanGestureRecognizer?

    @discardableResult
    static func install(on stack: UINavigationController) -> PageTurnStackGesture {
        if let existing = objc_getAssociatedObject(stack, &association) as? PageTurnStackGesture { return existing }
        let gesture = PageTurnStackGesture(stack)
        objc_setAssociatedObject(stack, &association, gesture, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return gesture
    }

    private init(_ stack: UINavigationController) {
        self.stack = stack
        super.init()
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        stack.view.addGestureRecognizer(pan)
        self.pan = pan
    }

    func keep(_ picture: PagePicture?, for page: UIViewController) {
        if let picture { pictures.setObject(picture, forKey: page) } else { pictures.removeObject(forKey: page) }
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard let stack, let window = stack.view.window else {
            if pan.state != .began && pan.state != .changed { PageTurn.shared.cancel() }
            return
        }
        switch pan.state {
        case .began:
            let pages = stack.viewControllers
            guard pages.count > 1 else { return }
            let now = pan.location(in: window), moved = pan.translation(in: window)
            let began = PageTurn.shared.begin(fromLeft: true, at: CGPoint(x: now.x - moved.x, y: now.y - moved.y),
                                              under: pictures.object(forKey: pages[pages.count - 2])) { [weak stack] in
                stack?.popViewController(animated: false)
            }
            if began { PageTurn.shared.move(to: now) }
        case .changed:
            PageTurn.shared.move(to: pan.location(in: window))
        case .ended:
            PageTurn.shared.end(velocity: pan.velocity(in: window).x)
        default:
            PageTurn.shared.cancel()
        }
    }

    // Only touches that start at the left edge of a pushed page, and only while the setting is on;
    // otherwise the system's own swipe back is left alone.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard PageTurn.shared.enabled, !PageTurn.shared.active, let stack,
              stack.viewControllers.count > 1, stack.transitionCoordinator == nil, stack.presentedViewController == nil else { return false }
        return touch.location(in: stack.view).x <= Self.edgeWidth
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let stack else { return false }
        let velocity = pan.velocity(in: stack.view)
        return velocity.x > 0 && velocity.x > abs(velocity.y)
    }
    /// Scrolling and the system's slide wait for this swipe to start or give way.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer is UIPanGestureRecognizer
    }
}

/// The hook is only part of the page while the setting is on.
private struct PageTurnStackPage: ViewModifier {
    @AppStorage(PageTurn.key) private var on = false
    func body(content: Content) -> some View {
        content.background { if on { PageTurnStackHook() } }
    }
}

extension View {
    /// Marks a page of a NavigationStack for the page-turn swipe back.
    func pageTurnStackPage() -> some View { modifier(PageTurnStackPage()) }
}
