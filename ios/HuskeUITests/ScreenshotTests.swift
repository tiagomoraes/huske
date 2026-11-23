// Screenshot tour for design review (not part of the `Huske` scheme's tests).
// Run: xcodebuild test -project Huske.xcodeproj -scheme HuskeScreenshots \
//        -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
// PNGs land in $HUSKE_SHOT_DIR (default: /tmp/huske-shots). Uses DEBUG demo
// launch arguments, so it needs no Mac and no working microphone.

import XCTest

final class ScreenshotTests: XCTestCase {
    private var shotDirectory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["HUSKE_SHOT_DIR"] ?? "/tmp/huske-shots",
            isDirectory: true)
    }

    override func setUp() {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(at: shotDirectory, withIntermediateDirectories: true)
    }

    private func save(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: shotDirectory.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLiveActivityTour() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HuskeDemoData", "YES", "-HuskeDemoRecording", "YES"]
        app.terminate()
        app.launch()
        // The simulated recording starts a second after launch.
        let stop = app.buttons["Stop and save recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "demo recording did not start")
        sleep(2)
        save("10-recording-in-app")

        // Expanded Dynamic Island: go home, then long-press the island.
        XCUIDevice.shared.press(.home)
        sleep(2)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.025)).press(forDuration: 1.2)
        sleep(2)
        save("11-dynamic-island-expanded")

        // Lock Screen banner: lock, then wake to the Lock Screen.
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(2)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(3)
        save("12-lock-screen")
    }

    /// Lock Screen only, for an app session started beforehand, e.g.
    /// `xcrun simctl launch booted cloud.tiagomoraes.huske.ios -HuskeDemoData YES -HuskeDemoRecording YES`.
    func testLockScreenOfRunningSession() throws {
        XCUIDevice.shared.press(.home)
        sleep(1)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(2)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(3)
        // On the Lock Screen iOS asks whether to allow Live Activities: "Allow"
        // the first time, and from iOS 27 again later with "Always Allow".
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Always Allow", "Allow"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 2) {
                button.tap()
                sleep(2)
                break
            }
        }
        save("12-lock-screen")
    }
}
