// The app's resource bundle is found where a packaged Huske.app keeps it
// (Contents/Resources) — the place the Xcode 26 `Bundle.module` accessor
// skipped, which made v0.15.0 crash on launch — and where `swift run` keeps
// it (beside the executable). A missing bundle is nil, never a trap.

import Foundation
import XCTest
@testable import HuskeKit

final class ResourceBundleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResourceBundleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A minimal `Huske.app` as `build-app.sh` lays it out.
    private func makeApp(withBundle: Bool) throws -> Bundle {
        let app = root.appendingPathComponent("Huske.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "test.huske.resource-bundle",
            "CFBundleExecutable": "Huske",
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try Data().write(to: macOS.appendingPathComponent("Huske"))
        if withBundle {
            let fonts = resources.appendingPathComponent("Huske_Huske.bundle/Fonts", isDirectory: true)
            try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
            try Data("font".utf8).write(to: fonts.appendingPathComponent("IBMPlexSans-Variable.ttf"))
        }
        return try XCTUnwrap(Bundle(url: app))
    }

    func testFindsTheBundleInAPackagedAppsResources() throws {
        let app = try makeApp(withBundle: true)
        let bundle = try XCTUnwrap(ResourceBundle.locate(named: "Huske_Huske", main: app))
        XCTAssertEqual(bundle.bundleURL.lastPathComponent, "Huske_Huske.bundle")
        XCTAssertEqual(bundle.bundleURL.deletingLastPathComponent().lastPathComponent, "Resources")
        XCTAssertNotNil(
            bundle.url(forResource: "IBMPlexSans-Variable", withExtension: "ttf", subdirectory: "Fonts"),
            "the fonts the app registers at launch")
    }

    func testAMissingBundleIsNilNotACrash() throws {
        let app = try makeApp(withBundle: false)
        XCTAssertNil(ResourceBundle.locate(named: "Huske_Huske", main: app))
    }

    /// `swift run` / `swift test`: the bundle sits beside the executable.
    func testFindsTheBundleBesideACommandLineExecutable() throws {
        let bin = root.appendingPathComponent("release", isDirectory: true)
        let fonts = bin.appendingPathComponent("Huske_Huske.bundle/Fonts", isDirectory: true)
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        let main = try XCTUnwrap(Bundle(url: bin))
        XCTAssertNotNil(ResourceBundle.locate(named: "Huske_Huske", main: main))
    }
}
