// Naming the paired Mac on the iPhone: the name heads the Mac screen, the
// Mac's own name stays visible beneath it, and clearing the field brings the
// Mac's own name back.
//
// In the `HuskeScreenshots` scheme with the other UI tests:
//   xcodebuild test -project Huske.xcodeproj -scheme HuskeScreenshots \
//     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
//     -only-testing:HuskeUITests/MacNameTests
// Uses the DEBUG demo launch arguments: no Mac, no network. PNGs land in
// $HUSKE_SHOT_DIR (default: /tmp/huske-shots).

import XCTest

final class MacNameTests: XCTestCase {
    private let demoMacName = "Studio MacBook Pro"

    override func setUp() {
        continueAfterFailure = false
    }

    private var shotDirectory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["HUSKE_SHOT_DIR"] ?? "/tmp/huske-shots",
            isDirectory: true)
    }

    private func save(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? FileManager.default.createDirectory(at: shotDirectory, withIntermediateDirectories: true)
        try? png.write(to: shotDirectory.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func text(containing fragment: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    /// Replaces whatever the field holds (the demo suite remembers a name
    /// between launches) with `text`, then presses Done.
    private func enter(_ text: String, in field: XCUIElement) {
        // The text is right-aligned: tapping the far end puts the caret after it.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 70) + text + "\n")
    }

    func testNamingThePairedMac() {
        let app = XCUIApplication()
        app.launchArguments = ["-HuskeDemoData", "YES", "-HuskeDemoPaired", "YES", "-HuskeDemoRoute", "mac"]
        app.terminate()
        app.launch()

        let field = app.textFields["Name for this Mac"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "the paired Mac screen should open with a Name field")
        enter("", in: field)
        XCTAssertTrue(app.staticTexts[demoMacName].waitForExistence(timeout: 5), "unnamed, it is the Mac's own name")
        XCTAssertFalse(text(containing: "Calls itself", in: app).exists)
        save("mac-name-01-own-name")

        enter("Office", in: field)
        XCTAssertTrue(app.staticTexts["Office"].waitForExistence(timeout: 5), "the given name heads the screen")
        XCTAssertTrue(text(containing: "Calls itself “\(demoMacName)”", in: app).exists,
                      "the Mac's own name stays visible")
        save("mac-name-02-renamed")

        enter("", in: field)
        XCTAssertTrue(app.staticTexts[demoMacName].waitForExistence(timeout: 5), "cleared, it is the Mac's own name again")
        XCTAssertFalse(text(containing: "Calls itself", in: app).exists)
    }
}
