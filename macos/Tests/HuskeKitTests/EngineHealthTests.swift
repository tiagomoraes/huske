// "Can this engine run?" — separately from "is it current?".
//
// The bug these pin down: a pinned engine whose virtualenv had been rebuilt
// rendered as "your huske engine needs an update", and the upgrade button on
// that screen ran `uv tool upgrade huske`, which exits 0 after upgrading a
// completely different install. The screen never changed, so the app asked for
// an update that no click could ever deliver.

import XCTest

@testable import HuskeKit

final class EngineDiagnosisTests: XCTestCase {
    func testReadsAShebangInterpreter() {
        XCTAssertEqual(
            EngineDiagnosis.interpreter(inShebangLine: "#!/Users/x/code/huske/.venv/bin/python"),
            "/Users/x/code/huske/.venv/bin/python")
    }

    func testIgnoresEnvShebangs() {
        // `env` resolves through PATH, so the script says nothing about which
        // interpreter is missing — better to fall back to the launch error.
        XCTAssertNil(EngineDiagnosis.interpreter(inShebangLine: "#!/usr/bin/env python3"))
    }

    func testIgnoresNonShebangFirstLines() {
        XCTAssertNil(EngineDiagnosis.interpreter(inShebangLine: "\u{7F}ELF"))
        XCTAssertNil(EngineDiagnosis.interpreter(inShebangLine: ""))
    }

    func testNamesTheMissingInterpreterNotTheScript() {
        // macOS reports "the file doesn't exist" naming the *script*, which is
        // sitting right there. Say what is actually gone.
        let message = EngineDiagnosis.launchFailure(
            interpreter: "/Users/x/code/huske/.venv/bin/python",
            interpreterExists: false,
            error: "The file “huske” doesn’t exist.")
        XCTAssertTrue(message.contains("/Users/x/code/huske/.venv/bin/python"))
        XCTAssertTrue(message.contains("virtualenv"))
        XCTAssertFalse(message.contains("doesn’t exist."), "the misleading error is dropped")
    }

    func testFallsBackToTheLaunchErrorWhenTheInterpreterIsFine() {
        let message = EngineDiagnosis.launchFailure(
            interpreter: "/usr/bin/python3", interpreterExists: true,
            error: "Permission denied")
        XCTAssertTrue(message.contains("Permission denied"))
    }

    func testSilentEngineQuotesItsStderr() {
        let message = EngineDiagnosis.silentEngine(
            status: 1, stderr: "ModuleNotFoundError: No module named 'huske'\n")
        XCTAssertTrue(message.contains("ModuleNotFoundError"))
        XCTAssertTrue(message.contains("exit 1"))
    }
}

final class EngineProbeDiagnosisTests: XCTestCase {
    private func run(
        launched: Bool, status: Int32 = 0, stdout: String = "", stderr: String = "",
        launchError: String? = nil
    ) -> EngineCapabilities.ProbeRun {
        EngineCapabilities.ProbeRun(
            launched: launched, status: status, stdout: stdout, stderr: stderr,
            launchError: launchError)
    }

    func testNothingLaunchedIsADiagnosis() {
        let failure = EngineCapabilities.diagnose(
            runs: [run(launched: false, launchError: "The file “huske” doesn’t exist.")],
            interpreter: "/gone/bin/python",
            interpreterExists: { _ in false })
        XCTAssertNotNil(failure)
        XCTAssertTrue(failure!.contains("/gone/bin/python"))
    }

    func testAnOldButAnsweringEngineIsNotAFailure() {
        // 0.10.0 has no --control-socket. That is "outdated", not "broken",
        // and it must stay on the upgrade path.
        let failure = EngineCapabilities.diagnose(
            runs: [
                run(launched: true, stdout: "huske 0.10.0\n"),
                run(launched: true, status: 2, stderr: "No such option: --control-socket"),
            ],
            interpreter: nil,
            interpreterExists: { _ in true })
        XCTAssertNil(failure)
    }

    func testAProcessThatStartsAndSaysNothingIsBroken() {
        let failure = EngineCapabilities.diagnose(
            runs: [run(launched: true, status: 1, stderr: "ImportError: bad magic number")],
            interpreter: nil,
            interpreterExists: { _ in true })
        XCTAssertNotNil(failure)
        XCTAssertTrue(failure!.contains("ImportError"))
    }
}

final class EngineStateTests: XCTestCase {
    private let binary = URL(fileURLWithPath: "/Users/x/.local/bin/huske")

    private func caps(
        version: String? = "0.14.0", controlSocket: Bool = true, failure: String? = nil
    ) -> EngineCapabilities {
        EngineCapabilities(
            version: version, controlSocket: controlSocket, configCLI: true, devicesCLI: true,
            failure: failure)
    }

    func testNothingInstalledIsOnboarding() {
        XCTAssertEqual(
            EngineStateResolver.resolve(binary: nil, override: nil, capabilities: nil),
            .missing)
    }

    func testAStalePinIsRepairNotOnboarding() {
        // The screen this distinction exists for: a pinned path that stopped
        // resolving used to show "Welcome to huske — install the engine" on a
        // Mac with two working engines on it.
        let state = EngineStateResolver.resolve(
            binary: nil, override: "/Users/x/code/huske/.venv/bin/huske", capabilities: nil)
        guard case .unusable(let path, _) = state else {
            return XCTFail("expected .unusable, got \(state)")
        }
        XCTAssertEqual(path, "/Users/x/code/huske/.venv/bin/huske")
    }

    func testStillProbingShowsNoSetupScreen() {
        // Optimistic on purpose: a setup screen must not flash between launch
        // and the first probe result.
        XCTAssertEqual(
            EngineStateResolver.resolve(binary: binary, override: nil, capabilities: nil),
            .ready)
    }

    func testAFailureOutranksEveryOtherReading() {
        let state = EngineStateResolver.resolve(
            binary: binary, override: nil,
            capabilities: caps(version: nil, controlSocket: false, failure: "Its interpreter is gone"))
        guard case .unusable(let path, let reason) = state else {
            return XCTFail("expected .unusable, got \(state)")
        }
        XCTAssertEqual(path, binary.path)
        XCTAssertEqual(reason, "Its interpreter is gone")
    }

    func testNoControlSocketIsOutdated() {
        let state = EngineStateResolver.resolve(
            binary: binary, override: nil,
            capabilities: caps(version: "0.10.0", controlSocket: false))
        XCTAssertEqual(state, .outdated(path: binary.path, version: "0.10.0"))
    }

    func testACurrentEngineIsReady() {
        XCTAssertEqual(
            EngineStateResolver.resolve(binary: binary, override: nil, capabilities: caps()),
            .ready)
        XCTAssertTrue(EngineState.ready.canRecord)
        XCTAssertFalse(EngineState.missing.canRecord)
    }
}

final class EngineAlternativeTests: XCTestCase {
    private func candidate(_ path: String, _ version: String?) -> EngineCandidate {
        EngineCandidate(
            url: URL(fileURLWithPath: path),
            version: version.flatMap(EngineVersion.init),
            origin: (path as NSString).deletingLastPathComponent)
    }

    func testOffersTheNewestWorkingEngine() {
        let alternative = BinaryLocator.alternative(
            among: [
                candidate("/Users/x/code/huske/.venv/bin/huske", nil),
                candidate("/opt/homebrew/bin/huske", "0.13.0"),
                candidate("/Users/x/.local/bin/huske", "0.14.0"),
            ],
            chosen: URL(fileURLWithPath: "/Users/x/code/huske/.venv/bin/huske"))
        XCTAssertEqual(alternative?.url.path, "/Users/x/.local/bin/huske")
    }

    func testNeverOffersAnEngineThatCouldNotReportAVersion() {
        // Silence is not proof of health — it may be broken the same way.
        let alternative = BinaryLocator.alternative(
            among: [candidate("/a/huske", nil), candidate("/b/huske", nil)],
            chosen: URL(fileURLWithPath: "/b/huske"))
        XCTAssertNil(alternative)
    }

    func testTheEngineInUseIsNotItsOwnAlternative() {
        let only = candidate("/Users/x/.local/bin/huske", "0.14.0")
        XCTAssertNil(BinaryLocator.alternative(among: [only], chosen: only.url))
    }
}
