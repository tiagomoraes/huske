// Which engine the app drives when a Mac has several installed.
//
// The bug these pin down: `~/.local/bin` was probed before `/opt/homebrew/bin`,
// so a stale uv-tool engine won over a freshly installed brew one purely by
// list position. The app then feature-probed the *old* engine and showed its
// "engine outdated" screen while a current engine sat one directory away.

import XCTest

@testable import HuskeKit

final class EngineVersionTests: XCTestCase {
    func testParsesReleaseTriples() {
        let v = EngineVersion("0.11.0")
        XCTAssertEqual(v?.major, 0)
        XCTAssertEqual(v?.minor, 11)
        XCTAssertEqual(v?.patch, 0)
        XCTAssertEqual(v?.isPrerelease, false)
    }

    func testStripsTheProgramName() {
        // `huske --version` prints "huske 0.11.0".
        XCTAssertEqual(EngineVersion("huske 0.11.0\n"), EngineVersion("0.11.0"))
    }

    func testOrdersNumericallyNotLexically() {
        // The trap: "0.9.0" > "0.11.0" as strings.
        XCTAssertLessThan(EngineVersion("0.9.0")!, EngineVersion("0.11.0")!)
        XCTAssertLessThan(EngineVersion("0.10.0")!, EngineVersion("0.11.0")!)
        XCTAssertLessThan(EngineVersion("0.11.0")!, EngineVersion("1.0.0")!)
        XCTAssertLessThan(EngineVersion("0.11.1")!, EngineVersion("0.11.10")!)
    }

    func testPrereleaseSortsBelowItsRelease() {
        XCTAssertLessThan(EngineVersion("0.12.0rc1")!, EngineVersion("0.12.0")!)
        XCTAssertLessThan(EngineVersion("0.12.0.dev3")!, EngineVersion("0.12.0")!)
        // …but still above the previous release.
        XCTAssertGreaterThan(EngineVersion("0.12.0rc1")!, EngineVersion("0.11.0")!)
    }

    func testShortAndMissingFormsDegrade() {
        XCTAssertEqual(EngineVersion("1")?.major, 1)
        XCTAssertEqual(EngineVersion("0.11")?.minor, 11)
        XCTAssertNil(EngineVersion(""))
        XCTAssertNil(EngineVersion("unknown"))
        XCTAssertNil(EngineVersion("huske"))
    }
}

final class EngineSelectionTests: XCTestCase {
    private func candidate(_ path: String, _ version: String?) -> EngineCandidate {
        EngineCandidate(
            url: URL(fileURLWithPath: path),
            version: version.flatMap(EngineVersion.init),
            origin: (path as NSString).deletingLastPathComponent
        )
    }

    func testNewestWinsOverDiscoveryOrder() {
        // The exact shape of the reported bug.
        let best = BinaryLocator.best(among: [
            candidate("/Users/x/.local/bin/huske", "0.10.0"),
            candidate("/opt/homebrew/bin/huske", "0.11.0"),
        ])
        XCTAssertEqual(best?.url.path, "/opt/homebrew/bin/huske")
    }

    func testDiscoveryOrderBreaksVersionTies() {
        let best = BinaryLocator.best(among: [
            candidate("/Users/x/.local/bin/huske", "0.11.0"),
            candidate("/opt/homebrew/bin/huske", "0.11.0"),
        ])
        XCTAssertEqual(best?.url.path, "/Users/x/.local/bin/huske")
    }

    func testKnownVersionBeatsUnreadableOne() {
        let best = BinaryLocator.best(among: [
            candidate("/Users/x/.local/bin/huske", nil),
            candidate("/opt/homebrew/bin/huske", "0.9.0"),
        ])
        XCTAssertEqual(best?.url.path, "/opt/homebrew/bin/huske")
    }

    func testAllUnreadableFallsBackToFirstFound() {
        // Better to drive *something* and let capability probing decide than to
        // report no engine at all.
        let best = BinaryLocator.best(among: [
            candidate("/Users/x/.local/bin/huske", nil),
            candidate("/opt/homebrew/bin/huske", nil),
        ])
        XCTAssertEqual(best?.url.path, "/Users/x/.local/bin/huske")
    }

    func testNoCandidatesIsNil() {
        XCTAssertNil(BinaryLocator.best(among: []))
    }

    // What the Configuration pane lists under "Also installed, not in use".

    func testShadowedExcludesTheChosenEngine() {
        let chosen = candidate("/opt/homebrew/bin/huske", "0.11.0")
        let other = candidate("/Users/x/.local/bin/huske", "0.10.0")
        let shadowed = BinaryLocator.shadowed(among: [other, chosen], chosen: chosen.url)
        XCTAssertEqual(shadowed.map(\.url.path), ["/Users/x/.local/bin/huske"])
    }

    func testShadowedSortsNewestFirstNumerically() {
        // Lexically "0.9.0" > "0.11.0"; the list must not believe that.
        let shadowed = BinaryLocator.shadowed(
            among: [
                candidate("/a/huske", "0.9.0"),
                candidate("/b/huske", "0.11.0"),
                candidate("/c/huske", "0.10.0"),
            ],
            chosen: URL(fileURLWithPath: "/elsewhere/huske")
        )
        XCTAssertEqual(shadowed.map { $0.version?.description }, ["0.11.0", "0.10.0", "0.9.0"])
    }

    func testShadowedPutsUnreadableVersionsLast() {
        let shadowed = BinaryLocator.shadowed(
            among: [candidate("/a/huske", nil), candidate("/b/huske", "0.10.0")],
            chosen: nil
        )
        XCTAssertEqual(shadowed.map(\.url.path), ["/b/huske", "/a/huske"])
    }

    func testShadowedIsEmptyForTheOnlyEngine() {
        let only = candidate("/opt/homebrew/bin/huske", "0.11.0")
        XCTAssertTrue(BinaryLocator.shadowed(among: [only], chosen: only.url).isEmpty)
    }

    func testShadowedMatchesThroughSymlinks() throws {
        // ~/.local/bin/huske is a symlink into uv's tool dir; picking one must
        // not make the other look like a second, separate engine.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hsk-shadow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("huske")
        try "#!/bin/sh\n".write(to: real, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("huske-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)

        let shadowed = BinaryLocator.shadowed(
            among: [EngineCandidate(url: link, version: EngineVersion("0.11.0"), origin: dir.path)],
            chosen: real
        )
        XCTAssertTrue(shadowed.isEmpty, "a symlink to the chosen engine is not a second engine")
    }
}

final class EngineCandidateDiscoveryTests: XCTestCase {
    /// Creates `<tmp>/<name>/huske` as an executable stub and returns its path.
    private func makeStub(_ name: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hsk-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("huske")
        try "#!/bin/sh\n".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return bin.path
    }

    func testPicksNewestAcrossWellKnownLocations() throws {
        let old = try makeStub("old")
        let new = try makeStub("new")
        let versions = [old: "huske 0.10.0", new: "huske 0.11.0"]

        let picked = BinaryLocator.locate(
            wellKnown: [old, new],           // old listed first, as ~/.local/bin was
            environment: ["PATH": ""],
            probe: { versions[$0.path] }
        )

        XCTAssertEqual(picked?.path, new)
    }

    func testWellKnownAndPathAreBothConsidered() throws {
        let known = try makeStub("known")
        let onPath = try makeStub("onpath")
        let versions = [known: "huske 0.10.0", onPath: "huske 0.11.0"]

        let picked = BinaryLocator.locate(
            wellKnown: [known],
            environment: ["PATH": (onPath as NSString).deletingLastPathComponent],
            probe: { versions[$0.path] }
        )

        // A newer engine only on PATH should still win.
        XCTAssertEqual(picked?.path, onPath)
    }

    func testSymlinkToTheSameEngineIsCountedOnce() throws {
        let real = try makeStub("real")
        let linkDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hsk-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: linkDir) }
        let link = linkDir.appendingPathComponent("huske")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: real)

        let found = BinaryLocator.candidates(
            wellKnown: [link.path, real],
            environment: ["PATH": ""],
            probe: { _ in "huske 0.11.0" }
        )

        XCTAssertEqual(found.count, 1, "a symlink and its target are one engine")
    }

    func testMissingPathsAreSkipped() {
        let found = BinaryLocator.candidates(
            wellKnown: ["/tmp/nope-\(UUID().uuidString)/huske"],
            environment: ["PATH": ""],
            probe: { _ in "huske 0.11.0" }
        )
        XCTAssertTrue(found.isEmpty)
    }

    func testOverrideStillWinsOverANewerEngine() throws {
        let chosen = try makeStub("chosen")
        let newer = try makeStub("newer")
        let versions = [chosen: "huske 0.10.0", newer: "huske 0.11.0"]

        let picked = BinaryLocator.locate(
            override: chosen,
            wellKnown: [newer],
            environment: ["PATH": ""],
            probe: { versions[$0.path] }
        )

        XCTAssertEqual(picked?.path, chosen, "an explicit choice is not second-guessed")
    }
}
