import XCTest
@testable import JapaneseReader

/// The arithmetic behind the page-turn swipe back.
final class PageTurnTests: XCTestCase {
    func testTheSheetEdgeStaysUnderTheFinger() {
        let radius = PageTurnGeometry.radius(width: 440)
        for travel in stride(from: CGFloat(1), through: 900, by: 23) {
            let contact = PageTurnGeometry.contact(forTravel: travel, radius: radius)
            XCTAssertEqual(PageTurnGeometry.edgeTravel(contact: contact, radius: radius), travel, accuracy: 0.05,
                           "edge at \(travel) pt")
        }
        XCTAssertEqual(PageTurnGeometry.contact(forTravel: 0, radius: radius), 0)
        XCTAssertEqual(PageTurnGeometry.contact(forTravel: -30, radius: radius), 0)
    }

    func testDraggingFurtherTurnsFurther() {
        let radius = PageTurnGeometry.radius(width: 440)
        var lastContact: CGFloat = 0, lastShown: CGFloat = -1
        for travel in stride(from: CGFloat(2), through: 880, by: 6) {
            let contact = PageTurnGeometry.contact(forTravel: travel, radius: radius)
            let shown = PageTurnGeometry.silhouette(contact: contact, radius: radius)
            XCTAssertGreaterThan(contact, lastContact)
            XCTAssertGreaterThanOrEqual(shown, lastShown, "more of the screen underneath shows at \(travel) pt")
            XCTAssertLessThanOrEqual(shown, contact)
            lastContact = contact; lastShown = shown
        }
    }

    func testLettingGoFarEnoughGoesBack() {
        XCTAssertFalse(PageTurnGeometry.completes(travel: 60, width: 440, velocity: 0), "a short swipe stays on the page")
        XCTAssertTrue(PageTurnGeometry.completes(travel: 200, width: 440, velocity: 0), "a long swipe goes back")
        XCTAssertTrue(PageTurnGeometry.completes(travel: 60, width: 440, velocity: 1200), "a quick flick goes back")
        XCTAssertFalse(PageTurnGeometry.completes(travel: 300, width: 440, velocity: -600), "flicking the page back down stays")
    }

    func testTheFoldLeansWithinLimitsAndMirrors() {
        let limit = 13 * CGFloat.pi / 180 + 0.0001
        for y in stride(from: CGFloat(0), through: 956, by: 120) {
            for drop in [CGFloat(-400), 0, 400] {
                let left = PageTurnGeometry.tilt(start: CGPoint(x: 6, y: y), finger: CGPoint(x: 220, y: y + drop), height: 956, fromLeft: true)
                let right = PageTurnGeometry.tilt(start: CGPoint(x: 434, y: y), finger: CGPoint(x: 220, y: y + drop), height: 956, fromLeft: false)
                XCTAssertLessThanOrEqual(abs(left), limit)
                XCTAssertEqual(left, -right, accuracy: 0.0001, "the right edge turns as the mirror image")
            }
        }
        let level = PageTurnGeometry.tilt(start: CGPoint(x: 6, y: 478), finger: CGPoint(x: 300, y: 478), height: 956, fromLeft: true)
        XCTAssertEqual(level, 0, accuracy: 0.0001, "a level swipe from the middle folds straight")
    }
}
