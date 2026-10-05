import XCTest
import SwiftUI
import UIKit
@testable import JapaneseReader

@MainActor final class SearchFieldLayoutTests: XCTestCase {
    private func textField(in view: UIView) -> JapaneseTextField? {
        if let field = view as? JapaneseTextField { return field }
        for child in view.subviews { if let found = textField(in: child) { return found } }
        return nil
    }

    /// The search field takes the room its row has left. When it insisted on the width
    /// of its text or placeholder, the row (and with it the whole Search page) became
    /// wider than a narrow screen and both edges were cut off.
    func testSearchFieldShrinksToTheRoomItIsGiven() async throws {
        let long = String(repeating: "あいうえお", count: 30)
        let row = HStack(spacing: 0) {
            JapaneseSearchField(text: .constant(long), focusRequest: 0, active: false, ink: .black) {}
                .frame(height: 38)
            Color.red.frame(width: 80, height: 38)
        }
        let controller = UIHostingController(rootView: row)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            window = UIWindow(windowScene: scene)
        } else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 240, height: 300)) }
        window.frame = CGRect(x: 0, y: 0, width: 240, height: 300)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var field: JapaneseTextField?
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            controller.view.layoutIfNeeded()
            field = textField(in: controller.view)
            if let field, field.frame.width > 0 { break }
        }
        let found = try XCTUnwrap(field, "The search field is in the row")
        let frame = found.convert(found.bounds, to: window)
        XCTAssertGreaterThan(found.intrinsicContentSize.width, 400, "The text is wider than the row")
        XCTAssertLessThanOrEqual(frame.width, 161, "The field is as wide as the room left beside the 80-point block: \(frame)")
        XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "The field starts on the screen: \(frame)")
        XCTAssertLessThanOrEqual(frame.maxX, 240.5, "The field ends on the screen: \(frame)")
    }
}
