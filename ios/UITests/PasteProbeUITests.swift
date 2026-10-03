import XCTest

final class PasteProbeUITests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func probe(_ theme: String) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-dictionary-fixture", "--ui-clipboard", "みほんの文を読みます。", "-readerThemePreset", theme]
        app.launch()
        sleep(3)
        shot(app, "\(theme) 1 empty")
        let paste = app.buttons["pastePassage"]
        let found = paste.waitForExistence(timeout: 5)
        XCTContext.runActivity(named: "\(theme) paste exists=\(found) frame=\(found ? "\(paste.frame)" : "-")") { _ in }
        print("PROBE \(theme) empty exists=\(found) frame=\(found ? "\(paste.frame)" : "-")")
        if found && paste.isHittable {
            paste.tap()
            sleep(3)
            shot(app, "\(theme) 2 pasted")
            let clear = app.buttons["clearPassage"]
            if clear.waitForExistence(timeout: 5) {
                clear.tap()
                sleep(2)
                shot(app, "\(theme) 3 cleared")
                print("PROBE \(theme) cleared exists=\(paste.exists) frame=\(paste.exists ? "\(paste.frame)" : "-")")
            }
        }
    }
    func testFable() { probe("fable") }
    func testSundown() { probe("fable-sundown") }
}
