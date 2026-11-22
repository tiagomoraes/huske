// A pairing link that doesn't work must say so wherever the Mac screen
// happens to be — it used to be drawn only before the first pairing, so a bad
// or expired link opened on a paired phone did nothing visible.
//
// In the `HuskeScreenshots` scheme with the other UI tests:
//   xcodebuild test -project Huske.xcodeproj -scheme HuskeScreenshots \
//     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
//     -only-testing:HuskeUITests/PairingFeedbackTests
// Uses the DEBUG demo launch arguments: no Mac, no network.

import XCTest

final class PairingFeedbackTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(paired: Bool, opening link: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-HuskeDemoData", "YES", "-HuskeDemoPaired", paired ? "YES" : "NO", "-HuskeOpenURL", link,
        ]
        app.terminate()
        app.launch()
        return app
    }

    private func text(containing fragment: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    func testABadLinkSaysSoOnAPairedPhone() {
        // A pairing link with no key: incomplete.
        let app = launch(paired: true, opening: "huske://pair?v=1&mac=incomplete")

        XCTAssertTrue(app.buttons["Forget this Mac"].waitForExistence(timeout: 15), "the paired Mac screen should open")
        XCTAssertTrue(
            text(containing: "pairing link is incomplete", in: app).waitForExistence(timeout: 5),
            "a link that didn't work has to say so on the paired Mac screen too")
    }

    func testABadLinkStillSaysSoBeforeTheFirstPairing() {
        let app = launch(paired: false, opening: "huske://pair?v=1&mac=incomplete")

        XCTAssertTrue(
            text(containing: "pairing link is incomplete", in: app).waitForExistence(timeout: 15))
    }
}
