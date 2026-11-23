import Foundation
import XCTest

@testable import HuskeKit
import HuskeSync

/// The words and decisions behind "why isn't it syncing?" on the Mac.
final class PhoneSyncStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_763_571_780)

    private func device(
        _ id: String, name: String? = "iPhone", model: String? = "iPhone17,1",
        pairedDaysAgo: Double, lastSeenDaysAgo: Double?
    ) -> PairedDevice {
        PairedDevice(
            deviceID: id, key: Data(repeating: 1, count: 32), name: name, model: model,
            createdAt: now.addingTimeInterval(-86_400 * pairedDaysAgo),
            pairedAt: now.addingTimeInterval(-86_400 * pairedDaysAgo),
            lastSeenAt: lastSeenDaysAgo.map { now.addingTimeInterval(-86_400 * $0) })
    }

    // MARK: can the phone reach this Mac?

    func testReachableSaysSoInTheUsersWords() {
        let line = PhoneReachability.line(enabled: true, health: .listening(port: 51_234), macName: "MacBook Pro")
        XCTAssertEqual(line.text, "Your iPhone can reach this Mac as “MacBook Pro”")
        XCTAssertNil(line.detail)
        XCTAssertEqual(line.tone, .ok)
    }

    func testWithNoPhonePairedItDoesNotSayYourIPhone() {
        let line = PhoneReachability.line(
            enabled: true, health: .listening(port: 1), macName: "MacBook Pro", hasPairedPhone: false)
        XCTAssertEqual(line.text, "Ready to pair. An iPhone will find this Mac as “MacBook Pro”")
    }

    func testOffAndStarting() {
        XCTAssertEqual(
            PhoneReachability.line(enabled: false, health: .listening(port: 1), macName: "M"),
            .init(text: "Off", tone: .off))
        XCTAssertEqual(
            PhoneReachability.line(enabled: true, health: .starting, macName: "M"),
            .init(text: "Getting ready…", tone: .working))
        XCTAssertEqual(
            PhoneReachability.line(enabled: true, health: .stopped, macName: "M"),
            .init(text: "Getting ready…", tone: .working))
    }

    /// A bound port with no advert used to read "Ready".
    func testNotAdvertisingIsNeverReady() {
        let line = PhoneReachability.line(
            enabled: true, health: .notAdvertising(.advertNotRegistered), macName: "M")
        XCTAssertEqual(line.text, "Your iPhone can't find this Mac right now")
        XCTAssertEqual(line.tone, .problem)
        XCTAssertNotNil(line.detail)
    }

    func testLocalNetworkDeniedSaysWhereToTurnItOn() {
        for health in [SyncServerHealth.notAdvertising(.localNetworkDenied), .recovering(.localNetworkDenied)] {
            let line = PhoneReachability.line(enabled: true, health: health, macName: "M")
            XCTAssertEqual(line.tone, .problem)
            XCTAssertEqual(line.detail?.contains("System Settings › Privacy & Security › Local Network"), true)
        }
    }

    func testRecoveringReadsAsWorkInProgress() {
        let line = PhoneReachability.line(
            enabled: true, health: .recovering(.other("POSIXErrorCode(rawValue: 50)")), macName: "M")
        XCTAssertEqual(line.text, "Getting ready again…")
        XCTAssertEqual(line.tone, .working)
        XCTAssertEqual(line.detail, "Receiving stopped unexpectedly. Huske is starting it again.")
    }

    func testNoNetworkSaysSo() {
        let line = PhoneReachability.line(enabled: true, health: .notAdvertising(.noNetwork), macName: "M")
        XCTAssertEqual(line.detail?.contains("isn't connected to a network"), true)
    }

    func testAStartThatFailedSaysWhyAndThatItKeepsTrying() {
        let line = PhoneReachability.line(
            enabled: true, health: .stopped, macName: "M", startError: "The disk is full.")
        XCTAssertEqual(line.text, "Receiving couldn't start")
        XCTAssertEqual(line.detail, "The disk is full. Huske keeps trying.")
        XCTAssertEqual(line.tone, .problem)
    }

    /// DESIGN.md § Words: the user's terms, never the protocol's.
    func testNoProtocolWordsReachThePane() {
        let reasons: [SyncServerHealth.Reason] = [
            .localNetworkDenied, .noNetwork, .advertNotRegistered, .other("NWError -65563 DNS mDNSResponder"),
        ]
        var healths: [SyncServerHealth] = [.stopped, .starting, .listening(port: 4_242)]
        healths += reasons.map { .notAdvertising($0) } + reasons.map { .recovering($0) }
        for health in healths {
            for paired in [true, false] {
                let line = PhoneReachability.line(
                    enabled: true, health: health, macName: "MacBook Pro", hasPairedPhone: paired)
                let words = (line.text + " " + (line.detail ?? "")).lowercased()
                for banned in ["bonjour", "tls", "psk", "mdns", "listener", "advert", "nwerror", "port", "4242", "dns"] {
                    XCTAssertFalse(words.contains(banned), "“\(banned)” in: \(words)")
                }
            }
        }
    }

    func testTheTechnicalLineKeepsTheDetailForTheLog() {
        XCTAssertEqual(PhoneReachability.technical(.listening(port: 51_234)), "listening on port 51234, advert confirmed")
        XCTAssertEqual(
            PhoneReachability.technical(.recovering(.other("Address already in use"))),
            "listener down, restarting (Address already in use)")
        XCTAssertEqual(
            PhoneReachability.technical(.notAdvertising(.advertNotRegistered)),
            "not advertising (advert not registered)")
    }

    // MARK: last contact

    func testLastContact() {
        XCTAssertEqual(PhoneContact.line(lastSeen: nil, connected: false, now: now), "Never connected")
        XCTAssertEqual(PhoneContact.line(lastSeen: now.addingTimeInterval(-20), connected: false, now: now), "Last seen just now")
        XCTAssertEqual(
            PhoneContact.line(lastSeen: now.addingTimeInterval(-120), connected: false, now: now),
            "Last seen 2 minutes ago")
        XCTAssertEqual(
            PhoneContact.line(lastSeen: now.addingTimeInterval(-3 * 86_400), connected: false, now: now),
            "Last seen 3 days ago")
        // Connected wins over any timestamp, old or missing.
        XCTAssertEqual(PhoneContact.line(lastSeen: now.addingTimeInterval(-3_600), connected: true, now: now), "Connected")
        XCTAssertEqual(PhoneContact.line(lastSeen: nil, connected: true, now: now), "Connected")
    }

    // MARK: pairings left behind by a re-pair

    /// "Forget this Mac" + pair again mints a new device; the old entry stays
    /// paired on the Mac with a key that still works.
    func testAnOlderPairingOfAPhoneThatPairedAgainIsFlagged() {
        let old = device("OLD", pairedDaysAgo: 30, lastSeenDaysAgo: 5)
        let new = device("NEW", pairedDaysAgo: 2, lastSeenDaysAgo: 0)
        XCTAssertEqual(PhoneContact.supersededPairings([old, new]), ["OLD"])
        XCTAssertEqual(PhoneContact.supersededPairings([new, old]), ["OLD"], "order must not matter")
    }

    /// Two real iPhones with the same name and model (the default name is
    /// just "iPhone"): the older one is still talking, so it is not a leftover.
    func testTwoPhonesThatBothKeepTalkingAreLeftAlone() {
        let hers = device("HERS", pairedDaysAgo: 30, lastSeenDaysAgo: 0.1)
        let his = device("HIS", pairedDaysAgo: 2, lastSeenDaysAgo: 0)
        XCTAssertEqual(PhoneContact.supersededPairings([hers, his]), [])
    }

    func testOnlyTheSameNameAndModelCountAsTheSamePhone() {
        let old = device("OLD", pairedDaysAgo: 30, lastSeenDaysAgo: 5)
        XCTAssertEqual(
            PhoneContact.supersededPairings([old, device("N", name: "Work iPhone", pairedDaysAgo: 2, lastSeenDaysAgo: 0)]), [])
        XCTAssertEqual(
            PhoneContact.supersededPairings([old, device("N", model: "iPhone15,2", pairedDaysAgo: 2, lastSeenDaysAgo: 0)]), [])
        // Without a name or model there is nothing to match on.
        let nameless = device("A", name: nil, pairedDaysAgo: 30, lastSeenDaysAgo: 5)
        XCTAssertEqual(
            PhoneContact.supersededPairings([nameless, device("B", name: nil, pairedDaysAgo: 2, lastSeenDaysAgo: 0)]), [])
    }

    func testAPendingInviteSupersedesNothing() {
        let old = device("OLD", pairedDaysAgo: 30, lastSeenDaysAgo: 5)
        let pending = PairedDevice(
            deviceID: "PENDING", key: Data(repeating: 2, count: 32), name: "iPhone", model: "iPhone17,1",
            createdAt: now, expiresAt: now.addingTimeInterval(600))
        XCTAssertEqual(PhoneContact.supersededPairings([old, pending]), [])
    }

    func testAChainOfRePairingsFlagsEveryOlderOne() {
        let first = device("A", pairedDaysAgo: 60, lastSeenDaysAgo: 40)
        let second = device("B", pairedDaysAgo: 30, lastSeenDaysAgo: 10)
        let third = device("C", pairedDaysAgo: 5, lastSeenDaysAgo: 0)
        XCTAssertEqual(PhoneContact.supersededPairings([first, second, third]), ["A", "B"])
    }

    // MARK: uploads that went quiet

    func testAnUploadWithRecentProgressIsLeftAlone() {
        let partial = RemoteStatus(recordingID: "r", state: .receiving, progress: 0.42)
        XCTAssertEqual(
            StaleUpload.verdict(lastProgress: now.addingTimeInterval(-5), now: now, server: partial), .arriving)
        XCTAssertFalse(StaleUpload.isQuiet(lastProgress: now.addingTimeInterval(-5), now: now))
        XCTAssertTrue(StaleUpload.isQuiet(lastProgress: now.addingTimeInterval(-31), now: now))
        XCTAssertTrue(StaleUpload.isQuiet(lastProgress: nil, now: now), "restored from the saved list")
    }

    /// The phone walked away mid-upload: the Mac holds 42 % and waits.
    func testAQuietUploadTheMacStillHoldsWaitsForThePhone() {
        let partial = RemoteStatus(recordingID: "r", state: .receiving, progress: 0.42)
        XCTAssertEqual(
            StaleUpload.verdict(lastProgress: now.addingTimeInterval(-60), now: now, server: partial),
            .waitingForPhone(progress: 0.42))
        // After a relaunch nothing has arrived in this run at all.
        XCTAssertEqual(
            StaleUpload.verdict(lastProgress: nil, now: now, server: partial), .waitingForPhone(progress: 0.42))
    }

    /// The partial was pruned, or the pairing and its upload are gone.
    func testAQuietUploadTheMacNoLongerHoldsIsDropped() {
        XCTAssertEqual(StaleUpload.verdict(lastProgress: nil, now: now, server: .unknown("r", now: now)), .gone)
    }

    func testAQuietUploadThatFinishedElsewhereMovesOn() {
        let queued = RemoteStatus(recordingID: "r", state: .queued, detail: "Waiting for the transcriber", updatedAt: now)
        XCTAssertEqual(StaleUpload.verdict(lastProgress: nil, now: now, server: queued), .moved(queued))
    }

    func testWithoutAnAnswerFromTheServerNothingIsDecided() {
        XCTAssertEqual(StaleUpload.verdict(lastProgress: nil, now: now, server: nil), .arriving)
    }

    // MARK: Copy details

    func testTheReportSaysWhatIsGoingOnAndHoldsNoContent() {
        let text = PhoneSyncReport.text(
            now: now, appVersion: "0.14.0", engineVersion: "0.14.0", engineTakesRecordings: true,
            enabled: true, health: .notAdvertising(.advertNotRegistered), macName: "MacBook Pro",
            openAtLogin: false, keepingAwake: true,
            phones: [
                .init(name: "iPhone de Teste", model: "iPhone17,1", lastSeen: nil, connected: true),
                .init(
                    name: "iPhone de Teste", model: "iPhone17,1", lastSeen: now.addingTimeInterval(-3 * 86_400),
                    connected: false, superseded: true),
            ],
            recordingStates: [.receiving, .queued, .queued, .transcribed, .failed],
            logTail: "2026-11-19T14:02:00-03:00 listening on port 51234\n",
            timeZone: TimeZone(identifier: "America/Sao_Paulo")!)
        XCTAssertEqual(
            text,
            """
            Huske iPhone sync — 2025-11-19T14:03:00-03:00
            App 0.14.0 · engine 0.14.0 · takes phone recordings
            Receiving: on · Your iPhone can't find this Mac right now
            Listener: not advertising (advert not registered)
            Open at login: off · keeping the Mac awake: yes
            Paired iPhones:
              iPhone de Teste (iPhone17,1) — connected
              iPhone de Teste (iPhone17,1) — last seen 3 days ago · looks like an earlier pairing, unused since it paired again
            Recordings: 5 (1 receiving, 2 queued, 1 transcribed, 1 failed)

            Recent activity:
            2026-11-19T14:02:00-03:00 listening on port 51234

            """)
    }

    func testAnEmptyReport() {
        let text = PhoneSyncReport.text(
            now: now, appVersion: "0.14.0", engineVersion: nil, engineTakesRecordings: false,
            enabled: false, health: .stopped, macName: "M", openAtLogin: true, keepingAwake: false,
            phones: [], recordingStates: [], logTail: "  \n")
        XCTAssertTrue(text.contains("engine not found · cannot take phone recordings"))
        XCTAssertTrue(text.contains("Receiving: off · Off"))
        XCTAssertTrue(text.contains("Paired iPhones: none"))
        XCTAssertTrue(text.contains("Recordings: none"))
        XCTAssertTrue(text.hasSuffix("Recent activity:\n(nothing logged yet)\n"))
    }

    // MARK: Open at login

    /// Offered once a phone is paired; never when it is already on, cannot
    /// be managed (a dev build), or the user said no.
    func testTheLoginOfferIsAnOfferNotANag() {
        func offer(paired: Bool = true, on: Bool = false, can: Bool = true, declined: Bool = false) -> Bool {
            LoginItemOffer.shouldOffer(
                hasPairedPhone: paired, openAtLogin: on, canManageLoginItem: can, declined: declined)
        }
        XCTAssertTrue(offer())
        XCTAssertFalse(offer(paired: false), "nothing to be reachable for")
        XCTAssertFalse(offer(on: true), "already on")
        XCTAssertFalse(offer(can: false), "not a packaged app")
        XCTAssertFalse(offer(declined: true), "the user said no; do not ask again")
    }
}
