// The transcript's Copy button: one tap, and it answers in place.
//
// In the `HuskeScreenshots` scheme with the other UI tests:
//   xcodebuild test -project Huske.xcodeproj -scheme HuskeScreenshots \
//     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
//     -only-testing:HuskeUITests/CopyTranscriptTests
// Uses the DEBUG demo launch arguments. PNGs land in $HUSKE_SHOT_DIR
// (default: /tmp/huske-shots). It doesn't read the clipboard back, because
// that would raise the paste prompt; TranscriptText.plain is unit-tested.

import XCTest

final class CopyTranscriptTests: XCTestCase {
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

    func testCopyingATranscript() {
        let app = XCUIApplication()
        app.launchArguments = ["-HuskeDemoData", "YES", "-HuskeDemoPaired", "YES", "-HuskeDemoRoute", "detail"]
        app.terminate()
        app.launch()

        let copy = app.buttons["Copy transcript"]
        XCTAssertTrue(copy.waitForExistence(timeout: 15), "a transcribed recording offers Copy above its text")
        XCTAssertTrue(copy.isHittable)
        save("copy-01-before")

        copy.tap()
        let copied = app.buttons["Transcript copied"].waitForExistence(timeout: 1.5)
        save("copy-02-copied")
        if !copied {
            try? app.debugDescription.write(to: shotDirectory.appendingPathComponent("copy-02.txt"),
                                            atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(copied, "it says so in place")

        XCTAssertTrue(app.buttons["Copy transcript"].waitForExistence(timeout: 6), "and goes back to Copy")
    }
}
