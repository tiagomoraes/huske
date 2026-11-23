import Foundation
import XCTest

@testable import HuskeKit

/// Start-up ran only from the main window's task, so a Huske launched with no
/// window (a login item, a window closed at the last quit) never started
/// receiving from the iPhone. The app delegate starts it now; this gate keeps
/// the delegate and the window from doing it twice.
@MainActor
final class LaunchGateTests: XCTestCase {
    @MainActor
    private final class Work {
        var runs = 0
        var inFlight = 0
        var maxInFlight = 0
        func run(seconds: Double = 0.05) async {
            runs += 1
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            inFlight -= 1
        }
    }

    private func settle(_ work: Work, runs: Int) async {
        for _ in 0..<200 where work.runs < runs || work.inFlight > 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// The case that was broken: no window ever appears.
    func testLaunchStartsTheWorkWithNoWindow() async {
        let (gate, work) = (LaunchGate(), Work())
        gate.startAtLaunch { await work.run() }
        await settle(work, runs: 1)
        XCTAssertEqual(work.runs, 1)
    }

    func testLaunchingTwiceRunsOnce() async {
        let (gate, work) = (LaunchGate(), Work())
        gate.startAtLaunch { await work.run() }
        gate.startAtLaunch { await work.run() }
        await settle(work, runs: 1)
        XCTAssertEqual(work.runs, 1)
    }

    /// A normal launch: the delegate and the window both ask, moments apart.
    func testAWindowThatAppearsDuringLaunchJoinsItInsteadOfRunningAgain() async {
        let (gate, work) = (LaunchGate(), Work())
        gate.startAtLaunch { await work.run() }
        await gate.runFromWindow { await work.run() }
        XCTAssertEqual(work.runs, 1, "the engine was probed twice at launch")
        XCTAssertEqual(work.inFlight, 0, "the window did not wait for the launch run")
    }

    /// The window's task can beat the delegate callback.
    func testAWindowThatComesFirstCountsAsTheLaunch() async {
        let (gate, work) = (LaunchGate(), Work())
        await gate.runFromWindow { await work.run() }
        gate.startAtLaunch { await work.run() }
        await settle(work, runs: 1)
        XCTAssertEqual(work.runs, 1)
    }

    /// Reopening the window hours later re-probes, as it always did.
    func testAWindowOpenedLaterRunsTheWorkAgain() async {
        let (gate, work) = (LaunchGate(), Work())
        gate.startAtLaunch { await work.run() }
        await settle(work, runs: 1)
        await gate.runFromWindow { await work.run() }
        XCTAssertEqual(work.runs, 2)
        await gate.runFromWindow { await work.run() }
        XCTAssertEqual(work.runs, 3)
        XCTAssertEqual(work.maxInFlight, 1)
    }
}
