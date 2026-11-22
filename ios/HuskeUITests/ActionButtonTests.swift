// Recording without opening Huske, end to end, on an iPhone 15 Pro-or-later
// simulator, with the real (Mac) microphone and no demo data:
// - assign the "Huske Record" control to the Action button in Settings;
// - run the "Record or Stop" App Shortcut from Spotlight with Huske not
//   running, check the Dynamic Island and the Lock Screen (pause, resume), run
//   it again to stop and save;
// - tap the same control in Control Center (what the Action button runs): it
//   records in the background, a second tap stops.
// XCTest can't press-and-hold the simulator's Action button, so the button
// itself is the one step left for a device.
//
// Run (HuskeScreenshots scheme, not CI):
//   xcrun simctl privacy booted grant microphone cloud.tiagomoraes.huske.ios
//   xcodebuild test -project Huske.xcodeproj -scheme HuskeScreenshots \
//     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
//     -only-testing:HuskeUITests/ActionButtonTests
// If Xcode reports "The bundle identifier for Huske couldn't be read", the
// generated .xctestrun's UITargetAppPath lacks ".app" (Xcode 27 confuses the
// app target with the `Huske` Swift package): build-for-testing, append
// ".app" there, then test-without-building -xctestrun.

import XCTest

final class ActionButtonTests: XCTestCase {
    private var shotDirectory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["HUSKE_SHOT_DIR"] ?? "/tmp/huske-shots",
            isDirectory: true)
    }

    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")

    override func setUp() {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(at: shotDirectory, withIntermediateDirectories: true)
    }

    private func save(_ name: String, tree app: XCUIApplication? = nil) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: shotDirectory.appendingPathComponent("\(name).png"))
        if let app {
            try? app.debugDescription.write(to: shotDirectory.appendingPathComponent("\(name).txt"),
                                            atomically: true, encoding: .utf8)
        }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAssignControlToActionButton() throws {
        settings.terminate()
        settings.launch()
        let row = settings.staticTexts["Action Button"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let carousel = settings.scrollViews.firstMatch
        XCTAssertTrue(carousel.waitForExistence(timeout: 5))
        // The carousel opens on the current choice: look both ways.
        var found = false
        var pages: [String] = []
        search: for direction in ["right", "left"] {
            for _ in 0..<13 {
                let page = settings.pageIndicators.firstMatch.value as? String ?? "?"
                pages.append(page)
                if page == "Controls" {
                    found = true
                    break search
                }
                // A slow drag moves exactly one page; a swipe can skip several.
                let from = carousel.coordinate(withNormalizedOffset: CGVector(dx: direction == "right" ? 0.3 : 0.7, dy: 0.5))
                let to = carousel.coordinate(withNormalizedOffset: CGVector(dx: direction == "right" ? 0.75 : 0.25, dy: 0.5))
                from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.2)
                sleep(1)
            }
        }
        try? pages.joined(separator: "\n").write(to: shotDirectory.appendingPathComponent("ab-pages.txt"),
                                                  atomically: true, encoding: .utf8)
        save("ab-01-controls-page", tree: settings)
        XCTAssertTrue(found, "no Controls page in the Action Button carousel")
        let choose = settings.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'control'")).firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 3), "no choose-a-control button")
        choose.tap()
        let search = settings.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Huske")
        let control = settings.buttons["cloud.tiagomoraes.huske.ios.start-recording"]
        XCTAssertTrue(control.waitForExistence(timeout: 5), "the Huske Record control is not in the gallery")
        save("ab-02-gallery", tree: settings)
        control.tap()
        sleep(2)
        save("ab-03-assigned", tree: settings)
        // The page now names the chosen control under "Controls".
        XCTAssertTrue(settings.buttons["Record"].waitForExistence(timeout: 5)
                      || settings.staticTexts["Record"].exists, "the control was not assigned")
    }

    /// Runs Huske's "Record or Stop" App Shortcut from Spotlight — the same
    /// `ToggleRecordingIntent` the Action button control runs. (The simulator
    /// can't press-and-hold the Action button from XCTest.)
    private func runRecordOrStop(_ step: String) {
        XCUIDevice.shared.press(.home)
        sleep(1)
        let pill = springboard.otherElements["spotlight-pill"].firstMatch
        if pill.waitForExistence(timeout: 3) { pill.tap() } else { springboard.swipeDown() }
        let spotlight = XCUIApplication(bundleIdentifier: "com.apple.Spotlight")
        let field = spotlight.textFields["SpotlightSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        spotlight.typeText("Record or Stop")
        let hit = spotlight.cells.matching(NSPredicate(format: "label CONTAINS 'Record or Stop'")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 6), "Huske's Record or Stop shortcut is not in Spotlight")
        save("\(step)-spotlight")
        hit.staticTexts["Record or Stop"].tap()
        sleep(5)
    }

    func testRecordOrStopRunsInTheBackground() throws {
        let huske = XCUIApplication(bundleIdentifier: "cloud.tiagomoraes.huske.ios")
        // Opened once after install, as a person would (registers its shortcuts).
        huske.launch()
        sleep(3)
        huske.terminate()
        settings.terminate()

        runRecordOrStop("rs-10")
        save("rs-11-after-start", tree: springboard)
        XCTAssertNotEqual(huske.state, .runningForeground, "starting should not open the app")
        XCTAssertEqual(huske.state, .runningBackground, "Huske should be recording in the background")

        // Compact island on the Home Screen, then expanded.
        XCUIDevice.shared.press(.home)
        sleep(2)
        save("rs-12-island-compact")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.028)).press(forDuration: 1.2)
        sleep(2)
        save("rs-13-island-expanded", tree: springboard)
        XCUIDevice.shared.press(.home)
        sleep(1)

        // Lock Screen.
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(2)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(3)
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) {
            allow.tap()
            sleep(2)
        }
        save("rs-14-lock-screen", tree: springboard)

        // Pause and resume with the Lock Screen buttons.
        let pause = springboard.buttons["Pause recording"]
        XCTAssertTrue(pause.waitForExistence(timeout: 3), "no Pause button on the Lock Screen")
        pause.tap()
        sleep(3)
        save("rs-15-lock-paused", tree: springboard)
        let resume = springboard.buttons["Resume recording"]
        XCTAssertTrue(resume.waitForExistence(timeout: 3), "Pause didn't take")
        resume.tap()
        sleep(3)
        save("rs-16-lock-resumed")

        // Unlock and stop with the same shortcut.
        XCUIDevice.shared.press(.home)
        sleep(2)
        runRecordOrStop("rs-20")
        save("rs-21-after-stop")
        huske.activate()
        sleep(3)
        save("rs-22-library", tree: huske)
        XCTAssertFalse(huske.buttons["Stop and save recording"].exists, "the second run should stop the recording")
    }

    /// The control itself — what Settings › Action Button › Controls runs —
    /// tapped in Control Center, with Huske not running.
    func testRecordControlInControlCenter() throws {
        let huske = XCUIApplication(bundleIdentifier: "cloud.tiagomoraes.huske.ios")
        huske.terminate()
        XCUIDevice.shared.press(.home)
        sleep(1)
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.005))
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.6)))
        sleep(2)
        save("cc-01-open", tree: springboard)

        var control = springboard.buttons["cloud.tiagomoraes.huske.ios.start-recording"]
        if !control.exists {
            // Add it: edit Control Center, "Add a Control", search, pick.
            let edit = springboard.buttons.matching(NSPredicate(format: "label == 'Edit' OR identifier CONTAINS[c] 'edit'")).firstMatch
            if edit.waitForExistence(timeout: 2) {
                edit.tap()
            } else {
                springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).press(forDuration: 1.5)
            }
            sleep(2)
            save("cc-02-editing", tree: springboard)
            let add = springboard.buttons["Add a Control"]
            XCTAssertTrue(add.waitForExistence(timeout: 4), "no Add a Control button")
            add.tap()
            sleep(2)
            let search = springboard.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 4))
            search.tap()
            search.typeText("Huske")
            let pick = springboard.buttons["cloud.tiagomoraes.huske.ios.start-recording"]
            XCTAssertTrue(pick.waitForExistence(timeout: 4))
            pick.tap()
            sleep(2)
            save("cc-03-added", tree: springboard)
            // Leave edit mode.
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
            sleep(2)
            control = springboard.buttons["cloud.tiagomoraes.huske.ios.start-recording"]
        }
        XCTAssertTrue(control.waitForExistence(timeout: 4), "the control is not in Control Center")
        save("cc-04-before-tap", tree: springboard)
        control.tap()
        sleep(5)
        save("cc-05-after-tap")
        XCTAssertEqual(huske.state, .runningBackground, "the control should record in the background")

        // Same control again: stop and save.
        if !control.exists {
            XCUIDevice.shared.press(.home)
            sleep(1)
            top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.6)))
            sleep(2)
        }
        control.tap()
        sleep(4)
        save("cc-06-after-second-tap")
        XCUIDevice.shared.press(.home)
    }
}
