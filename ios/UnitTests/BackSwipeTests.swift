import XCTest
@testable import JapaneseReader

/// When a touch becomes a swipe back, and when letting go goes back.
final class BackSwipeTests: XCTestCase {
    private func decide(_ start: BackSwipeRules.Start, _ dx: CGFloat, _ dy: CGFloat, after elapsed: TimeInterval = 0.05) -> BackSwipeRules.Decision {
        BackSwipeRules.decide(start, move: CGVector(dx: dx, dy: dy), elapsed: elapsed)
    }

    func testFromTheEdgeAlmostAnySidewaysMovementStartsEarly() {
        XCTAssertEqual(decide(.left, 7, 0), .begin, "a short sideways movement from the edge is enough")
        XCTAssertEqual(decide(.left, 7, 9), .begin, "a thumb arc of about 50° from the edge still counts")
        XCTAssertEqual(decide(.left, 3, 2), .wait, "too little movement to tell yet")
        XCTAssertEqual(decide(.left, -8, 0), .fail, "moving away from the edge is not back")
        XCTAssertEqual(decide(.left, 2, 12), .fail, "scrolling along the edge is not back")
        XCTAssertEqual(decide(.right, -8, 2), .begin, "the right edge goes back with a swipe to the left")
        XCTAssertEqual(decide(.right, 8, 0), .fail)
    }

    func testOnThePageOnlyAClearSwipeToTheRightCounts() {
        XCTAssertEqual(decide(.page, 11, 2), .begin)
        XCTAssertEqual(decide(.page, 11, 8), .begin, "a slightly rising or falling swipe still counts")
        XCTAssertEqual(decide(.page, 8, 3), .wait, "decided only after 10 points")
        XCTAssertEqual(decide(.page, -11, 2), .fail, "a swipe to the left is not back")
        XCTAssertEqual(decide(.page, 9, 9), .fail, "a diagonal is left to scrolling")
        XCTAssertEqual(decide(.page, 1, 6), .fail, "a vertical start is a scroll, given up after 5 points")
        XCTAssertEqual(decide(.page, 3, -5), .fail)
        XCTAssertEqual(decide(.page, 2, 1, after: 0.7), .fail, "a finger resting first is selecting text")
        XCTAssertEqual(decide(.left, 2, 1, after: 0.7), .wait, "at the edge a slow start is still a swipe")
    }

    func testScrollingIsGivenUpQuickly() {
        // Typical scrolls with a thumb: never taken for a swipe back.
        for angle in stride(from: CGFloat(55), through: 125, by: 5) {
            let radians = angle * .pi / 180
            for distance in stride(from: CGFloat(5), through: 14, by: 1) {
                let decision = decide(.page, cos(radians) * distance, sin(radians) * distance)
                XCTAssertNotEqual(decision, .begin, "a scroll at \(angle)° is not a swipe back")
            }
        }
        // Swipes within 35° of level always go back.
        for angle in stride(from: CGFloat(-35), through: 35, by: 5) {
            let radians = angle * .pi / 180
            XCTAssertEqual(decide(.page, cos(radians) * 12, sin(radians) * 12), .begin, "a swipe at \(angle)° goes back")
        }
    }

    func testTheCardCoverKeepsTheSelectionAboveIt() {
        let page = CGRect(x: 0, y: 100, width: 390, height: 600)
        XCTAssertEqual(FrameReader.cover(of: page, by: CGRect(x: 0, y: 500, width: 390, height: 260), fallback: 250), 204)
        XCTAssertEqual(FrameReader.cover(of: page, by: .zero, fallback: 250), 250, "before the card is measured")
        XCTAssertEqual(FrameReader.cover(of: page, by: CGRect(x: 0, y: 800, width: 390, height: 100), fallback: 250), 0,
                       "a card below the page covers nothing")
    }

    func testLettingGoFarEnoughOrFlickingGoesBack() {
        XCTAssertFalse(BackSwipeRules.completes(travel: 60, width: 440, velocity: 0), "a short drag returns")
        XCTAssertTrue(BackSwipeRules.completes(travel: 170, width: 440, velocity: 0), "past about a third goes back")
        XCTAssertTrue(BackSwipeRules.completes(travel: 40, width: 440, velocity: 600), "a flick goes back")
        XCTAssertTrue(BackSwipeRules.completes(travel: 125, width: 440, velocity: 300), "a quick release just short of a third goes back")
        XCTAssertFalse(BackSwipeRules.completes(travel: 300, width: 440, velocity: -400), "flicking the page back returns")
        XCTAssertFalse(BackSwipeRules.completes(travel: 3, width: 440, velocity: 900), "a twitch is not a swipe")
    }
}
