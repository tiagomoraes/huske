// LinkState is pure: what the Mac screen and the home header say follows from
// the browse, the network path, and what the current pass is doing.

import HuskeSync
import Network
import XCTest
@testable import Huske

final class LinkStateTests: XCTestCase {
    private let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 4242)

    private func state(
        _ presence: MacPresence, wifi: Bool? = true, connecting: Bool = false,
        route: SyncRoute? = nil, retryAt: Date? = nil
    ) -> LinkState {
        LinkState(presence: presence, hasLocalNetwork: wifi, isConnecting: connecting, route: route, retryAt: retryAt)
    }

    private var visible: MacPresence { MacPresence(isBrowsing: true, endpoint: endpoint, routes: [.wifi]) }
    private var looking: MacPresence { MacPresence(isBrowsing: true) }

    // MARK: derivation

    /// A denied Local Network permission used to read as "open Huske on your
    /// Mac": the browser reported nothing and nobody asked it why.
    func testLocalNetworkOffIsItsOwnState() {
        let denied = MacPresence(isBrowsing: true, issue: .localNetworkDenied)
        XCTAssertEqual(state(denied), .localNetworkOff)
        XCTAssertEqual(state(denied, wifi: false), .localNetworkOff, "the permission comes first: nothing works without it")
        XCTAssertEqual(state(denied, connecting: true), .localNetworkOff)
    }

    func testNotOnWiFiOnlyWhenTheMacIsNotVisible() {
        XCTAssertEqual(state(looking, wifi: false), .noWiFi)
        XCTAssertEqual(state(visible, wifi: false), .visible, "seen directly (peer-to-peer): Wi-Fi isn't the problem")
        XCTAssertEqual(state(looking, wifi: nil), .searching, "not known yet is not 'off'")
    }

    func testLookingVisibleAndPaused() {
        XCTAssertEqual(state(looking), .searching)
        XCTAssertEqual(state(visible), .visible)
        XCTAssertEqual(state(MacPresence()), .paused, "in the background, not looking")
        XCTAssertEqual(
            state(MacPresence(isBrowsing: true, issue: .browsingUnavailable("ServiceNotRunning"))), .searching,
            "a browser that will recover by itself is still looking")
    }

    func testAPassInFlight() {
        XCTAssertEqual(state(visible, connecting: true), .connecting)
        XCTAssertEqual(state(looking, connecting: true), .searching, "waiting for the Mac to show up is not connecting")
        XCTAssertEqual(state(visible, route: .wifi), .connected(.wifi))
        XCTAssertEqual(state(visible, route: .peerToPeer), .connected(.peerToPeer))
        XCTAssertEqual(state(MacPresence(), connecting: true), .connecting, "no browse of our own (demo, tests)")
    }

    func testRetryingOnlyWhileTheMacIsVisible() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(state(visible, retryAt: at), .retrying(at: at))
        XCTAssertEqual(state(visible, connecting: true, retryAt: at), .connecting)
        XCTAssertEqual(state(looking, retryAt: at), .searching, "nothing to retry against")
    }

    /// A Mac that refuses this iPhone's key is not "nearby" and not
    /// "trying again": only pairing again helps.
    func testRejectedByTheMac() {
        func rejected(_ presence: MacPresence, connecting: Bool = false, retryAt: Date? = nil) -> LinkState {
            LinkState(presence: presence, hasLocalNetwork: true, isConnecting: connecting, route: nil,
                      retryAt: retryAt, isRejected: true)
        }
        XCTAssertEqual(rejected(visible), .rejected)
        XCTAssertEqual(rejected(looking), .rejected, "still true while the Mac is away")
        XCTAssertEqual(rejected(visible, retryAt: Date()), .rejected)
        XCTAssertEqual(rejected(visible, connecting: true), .connecting, "an attempt in flight is shown as that")
        XCTAssertEqual(rejected(MacPresence(isBrowsing: true, issue: .localNetworkDenied)), .localNetworkOff)

        let state = LinkState.rejected
        XCTAssertTrue(state.isBlocked)
        XCTAssertTrue(state.needsPairing)
        XCTAssertFalse(state.needsSettings)
        XCTAssertEqual(state.label(), "Your Mac didn't accept this iPhone")
        XCTAssertEqual(state.headline, "Pair again")
        XCTAssertEqual(state.explanation(macName: "Studio")?.contains("Pair iPhone"), true)
    }

    // MARK: words

    func testLabelsAreSentenceCaseAndInTheUsersTerms() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let labels = [
            LinkState.localNetworkOff, .noWiFi, .searching, .visible, .connecting,
            .connected(.wifi), .connected(.peerToPeer), .connected(.other),
            .retrying(at: now.addingTimeInterval(12)), .paused,
        ].map { $0.label(now: now) }

        XCTAssertEqual(labels, [
            "Local Network access is off", "Not on Wi-Fi", "Looking for your Mac…", "Nearby", "Connecting…",
            "Connected over Wi-Fi", "Connected directly", "Connected",
            "Couldn't connect · trying again in 12 s", "Not looking right now",
        ])
        for label in labels {
            XCTAssertEqual(label.first?.isUppercase, true, label)
            for jargon in ["Bonjour", "TLS", "AWDL", "peer", "PSK", "browse"] {
                XCTAssertFalse(label.localizedCaseInsensitiveContains(jargon), "\(label) speaks protocol")
            }
        }
    }

    func testRetryCountdownRoundsUpAndNeverGoesNegative() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(LinkState.retrying(at: now.addingTimeInterval(1.2)).label(now: now),
                       "Couldn't connect · trying again in 2 s")
        XCTAssertEqual(LinkState.retrying(at: now.addingTimeInterval(0.4)).label(now: now),
                       "Couldn't connect · trying again in 1 s")
        XCTAssertEqual(LinkState.retrying(at: now.addingTimeInterval(-3)).label(now: now), "Trying again…")
    }

    /// Every state the user has to act on comes with the way out.
    func testBlockedStatesSayWhatToDo() {
        let off = LinkState.localNetworkOff
        XCTAssertTrue(off.isBlocked)
        XCTAssertTrue(off.needsSettings)
        XCTAssertEqual(off.explanation(macName: "Studio")?.contains("Settings"), true)
        XCTAssertEqual(off.headline, "Local Network off")

        let noWiFi = LinkState.noWiFi
        XCTAssertTrue(noWiFi.isBlocked)
        XCTAssertFalse(noWiFi.needsSettings)
        XCTAssertEqual(noWiFi.explanation(macName: "Studio")?.contains("Wi-Fi"), true)

        XCTAssertEqual(LinkState.searching.explanation(macName: "Studio")?.contains("Studio"), true)
        for fine in [LinkState.visible, .connecting, .connected(.wifi), .paused] {
            XCTAssertNil(fine.explanation(macName: "Studio"))
            XCTAssertFalse(fine.isBlocked)
            XCTAssertNil(fine.headline, "the Mac's name stands in the header")
        }
    }

    // MARK: backoff

    func testBackoffGoesFromTwoSecondsToAMinute() {
        let middle = (1...8).map { LinkBackoff.delay(afterFailures: $0, jitter: 0.5) }
        XCTAssertEqual(middle, [2, 4, 8, 16, 32, 60, 60, 60].map { Duration.seconds($0) })
    }

    func testBackoffJitterStaysWithinTwentyPercentAndUnderTheCeiling() {
        XCTAssertEqual(LinkBackoff.delay(afterFailures: 1, jitter: 0), .milliseconds(1600))
        XCTAssertEqual(LinkBackoff.delay(afterFailures: 1, jitter: 1), .milliseconds(2400))
        XCTAssertEqual(LinkBackoff.delay(afterFailures: 3, jitter: 0), .milliseconds(6400))
        XCTAssertEqual(LinkBackoff.delay(afterFailures: 6, jitter: 1), .seconds(60), "never past the ceiling")
        XCTAssertEqual(LinkBackoff.delay(afterFailures: 500, jitter: 1), .seconds(60), "no overflow")
        XCTAssertEqual(LinkBackoff.delay(afterFailures: 0, jitter: 0.5), .seconds(2), "treated as the first failure")
        for failures in 1...12 {
            for _ in 0..<20 {
                let delay = LinkBackoff.delay(afterFailures: failures)
                XCTAssertGreaterThanOrEqual(delay, .milliseconds(1600))
                XCTAssertLessThanOrEqual(delay, .seconds(60))
            }
        }
    }
}
