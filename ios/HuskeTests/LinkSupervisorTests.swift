// The link supervisor in SyncManager: one browse says where the Mac is, a
// pass connects straight to it (and isn't attempted while the Mac is not
// visible), recovery is driven by events — the Mac appears or is seen another
// way, the network path changes, the app comes to the front — and only a
// failure with the Mac still visible is retried on a backoff clock.
//
// Scripted: `FakePresence` and `FakePath` play Bonjour and NWPathMonitor,
// `FakeMac` plays the Mac, and the clock and delays are injected.

import HuskeSync
import Network
import XCTest
@testable import Huske

/// Plays `NWPathMonitor`: reports only while watched, the current path first.
final class FakePath: NetworkPathSource, @unchecked Sendable {
    static let wifi = NetworkPath(hasLocalNetwork: true, interfaces: ["en0"])
    static let offline = NetworkPath(hasLocalNetwork: false, interfaces: [])

    private let lock = NSLock()
    private var continuations: [AsyncStream<NetworkPath>.Continuation] = []
    private var current: NetworkPath
    private var watching = false

    init(_ path: NetworkPath = FakePath.wifi) {
        current = path
    }

    var isWatching: Bool { lock.withLock { watching } }

    var updates: AsyncStream<NetworkPath> {
        AsyncStream { continuation in
            lock.lock()
            continuations.append(continuation)
            if watching { continuation.yield(current) }
            lock.unlock()
        }
    }

    func start() {
        lock.lock()
        watching = true
        for continuation in continuations { continuation.yield(current) }
        lock.unlock()
    }

    func stop() {
        lock.withLock { watching = false }
    }

    func set(_ path: NetworkPath) {
        lock.lock()
        current = path
        if watching { for continuation in continuations { continuation.yield(path) } }
        lock.unlock()
    }
}

/// A SyncManager wired to scripted fakes, with a temporary library — shared
/// by the sync scenario suites (no tests of its own). The helpers are
/// `@nonobjc`: XCTestCase exposes its subclasses' methods to Objective-C, which
/// an async method taking a non-escaping closure can't be.
@MainActor
class SyncScenarioTestCase: XCTestCase {
    /// What `retryDelay` was asked, in order.
    final class Asked {
        var failures: [Int] = []
    }

    var directory: URL!
    var suiteName: String!
    var defaults: UserDefaults!
    var library: LibraryStore!
    var journal: SyncJournal!
    var pairingStore: InMemoryPairingStore!
    var managers: [SyncManager] = []
    let startOfTime = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkSupervisorTests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "LinkSupervisorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        library = LibraryStore(rootDirectory: directory)
        journal = SyncJournal()
    }

    override func tearDown() async throws {
        for manager in managers { manager.forgetMac() }
        managers = []
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: helpers

    /// - Parameter presences: a presence source per Mac (by macID), for
    ///   scenarios with two Macs; `presence` serves every Mac otherwise.
    @nonobjc final func makeManager(
        paired: FakeMac?, macs: [FakeMac] = [], presence: FakePresence?, path: FakePath? = nil,
        presences: [String: FakePresence] = [:],
        retryDelay: @escaping (Int) -> Duration = { _ in .milliseconds(40) },
        discoveryWait: Duration = .milliseconds(300),
        lookAgainInterval: Duration = .seconds(60),
        backgroundPollingWindow: TimeInterval = 20,
        inBackground: Bool = false,
        now: (() -> Date)? = nil
    ) -> SyncManager {
        if let paired { defaults.set(paired.macID, forKey: "sync.confirmedMacID") }
        let known = macs + (paired.map { [$0] } ?? [])
        let fixedNow = startOfTime
        pairingStore = InMemoryPairingStore(paired?.pairing)
        let manager = SyncManager(
            library: library,
            pairingStore: pairingStore,
            defaults: defaults,
            defaultDeviceName: "Test iPhone",
            makeConnector: { pairing, _ in
                FakeConnector(mac: known.first { $0.macID == pairing.macID }, deviceID: pairing.deviceID)
            },
            makePresence: { presences[$0.macID] ?? presence },
            retryDelay: retryDelay,
            backgroundPollingWindow: backgroundPollingWindow,
            applicationIsInBackground: { inBackground },
            makePathSource: { path },
            discoveryWait: discoveryWait,
            lookAgainInterval: lookAgainInterval,
            journal: journal,
            now: now ?? { fixedNow })
        managers.append(manager)
        return manager
    }

    @discardableResult
    @nonobjc final func addRecording(_ id: String, title: String? = nil, minutesAgo: Double = 1,
                              sync: SyncRecord = SyncRecord()) -> Recording {
        let recording = Recording(
            id: id, title: title ?? "Recording \(id)", startedAt: Date().addingTimeInterval(-minutesAgo * 60),
            duration: 12, fileName: "\(id).m4a", byteCount: 16, capture: .complete, sync: sync)
        try? Data("synthetic audio \(id)".utf8).write(to: library.audioURL(for: recording))
        library.insert(recording)
        return recording
    }

    @nonobjc final func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @nonobjc final func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(60))
    }

    /// `pair(with:)`, without hanging the test if it never returns.
    @nonobjc final func pair(_ sync: SyncManager, with invite: PairingInvite,
              within seconds: TimeInterval = 3) async -> SyncManager.PairingResult? {
        final class Box { var result: SyncManager.PairingResult? }
        let box = Box()
        Task { @MainActor in box.result = await sync.pair(with: invite) }
        _ = await waitUntil(timeout: seconds) { box.result != nil }
        if box.result == nil { sync.cancelRun() }
        return box.result
    }
}

@MainActor
final class LinkSupervisorTests: SyncScenarioTestCase {
    /// The Mac is visible and every connection to it fails; the first failed
    /// pass is over and its retry is `delay` away.
    private func failingVisibleMac(
        retryIn delay: Duration = .seconds(60), path: FakePath? = nil
    ) async -> (SyncManager, FakeMac, FakePresence, Asked) {
        let mac = FakeMac("Studio")
        mac.with { $0.defaultConnect = .fail(SyncError.timeout) }
        let presence = FakePresence(reachable: true)
        let asked = Asked()
        addRecording("a")
        let sync = makeManager(paired: mac, presence: presence, path: path, retryDelay: {
            asked.failures.append($0)
            return delay
        })
        let failed = await waitUntil { mac.connects == 1 && !sync.isRunning && sync.retryAt != nil }
        XCTAssertTrue(failed, "the first pass should have failed and scheduled a retry")
        return (sync, mac, presence, asked)
    }

    // MARK: one browse, no connect without a Mac

    /// Every attempt used to start its own Bonjour browse and, with the Mac
    /// away, spend 8 s on it only to report "not found".
    func testDoesNotTryToConnectWhileTheMacIsNotVisible() async {
        let mac = FakeMac("Studio")
        let presence = FakePresence(reachable: false)
        addRecording("a")
        let sync = makeManager(paired: mac, presence: presence)
        await settle()

        sync.recordingSaved("a")
        sync.scenePhaseChanged(isActive: true)
        // A recording just saved looks for the Mac for a moment (a fresh
        // browse), then leaves it to the browse result.
        let ended = await waitUntil(timeout: 2) { !sync.isRunning }

        XCTAssertTrue(ended, "gives up after the discovery wait")
        XCTAssertEqual(mac.connects, 0, "nothing to connect to")
        XCTAssertEqual(sync.activity, .idle)
        XCTAssertNil(sync.lastError, "not being nearby is not an error")
        XCTAssertEqual(sync.link, .searching)
    }

    func testConnectsStraightToWhereTheMacWasSeen() async {
        let mac = FakeMac("Studio")
        addRecording("a")
        _ = makeManager(paired: mac, presence: FakePresence(reachable: true))

        let uploaded = await waitUntil { mac.uploaded == ["a"] }

        XCTAssertTrue(uploaded)
        XCTAssertEqual(mac.with { $0.endpoints }, [FakePresence.endpoint], "the endpoint the browse reported")
        XCTAssertEqual(mac.with { $0.browses }, 0, "never a second browse")
    }

    func testTheMacAppearingStartsTheUpload() async {
        let mac = FakeMac("Studio")
        let presence = FakePresence(reachable: false)
        addRecording("a")
        let sync = makeManager(paired: mac, presence: presence)
        sync.recordingSaved("a")
        await settle()
        XCTAssertEqual(mac.connects, 0)

        presence.set(true)

        let uploaded = await waitUntil { mac.uploaded == ["a"] }
        XCTAssertTrue(uploaded, "the browse result is the trigger")
        XCTAssertEqual(mac.connects, 1)
    }

    // MARK: looking again (peer-to-peer results drop off Wi-Fi)

    /// Seen on a real iPhone 15 Pro with Wi-Fi switched off in Control
    /// Center: the Mac showed up over peer-to-peer, its result dropped 11 s
    /// later, and the recording saved next sat on "Waiting for your Mac".
    /// Only a fresh browse finds it again.
    func testASavedRecordingLooksAgainForAMacThatDroppedOutOfSight() async {
        let mac = FakeMac("Studio")
        let presence = FakePresence(reachable: false)
        presence.appearOnNextRefresh()
        addRecording("a")
        let sync = makeManager(paired: mac, presence: presence, discoveryWait: .seconds(5))
        await settle()

        sync.recordingSaved("a")

        let uploaded = await waitUntil { mac.uploaded == ["a"] }
        XCTAssertTrue(uploaded, "the fresh browse found the Mac and the recording went")
        XCTAssertGreaterThanOrEqual(presence.refreshes, 1)
    }

    func testAnUnseenMacIsLookedForAgainWhileOnScreen() async {
        let mac = FakeMac("Studio")
        let presence = FakePresence(reachable: false)
        let sync = makeManager(paired: mac, presence: presence, lookAgainInterval: .milliseconds(50))

        let looked = await waitUntil(timeout: 2) { presence.refreshes >= 2 }
        XCTAssertTrue(looked, "a browse that can't see the Mac is started over, repeatedly")
        XCTAssertEqual(journal.entries.filter { $0.text.contains("starting the browse over") }.count, 1,
                       "said once, not every time")

        presence.set(true)
        await settle()
        let seenAt = presence.refreshes
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(presence.refreshes, seenAt, "a visible Mac needs no more looking")
        XCTAssertTrue(sync.isMacReachable)
    }

    func testNoLookingAgainWhileNotBrowsing() async {
        let mac = FakeMac("Studio")
        let presence = FakePresence(reachable: false)
        _ = makeManager(paired: mac, presence: presence, lookAgainInterval: .milliseconds(50), inBackground: true)
        await settle()

        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(presence.isBrowsing, "in the background with nothing to send, nobody browses")
        XCTAssertEqual(presence.refreshes, 0, "and nobody looks again")
    }

    /// "Sync now" is someone waiting for an answer: look for a moment, then
    /// stop — without inventing an error the link state already explains.
    func testSyncNowLooksForTheMacBrieflyThenStops() async {
        let mac = FakeMac("Studio")
        let sync = makeManager(paired: mac, presence: FakePresence(reachable: false), discoveryWait: .milliseconds(200))
        await settle()

        sync.syncNow(.manual)
        XCTAssertTrue(sync.isRunning)
        XCTAssertEqual(sync.link, .searching, "looking, not connecting")
        let ended = await waitUntil(timeout: 2) { !sync.isRunning }

        XCTAssertTrue(ended, "gives up after the discovery wait")
        XCTAssertEqual(mac.connects, 0)
        XCTAssertNil(sync.lastError)
        XCTAssertEqual(sync.link, .searching)
        XCTAssertTrue(journal.entries.contains { $0.text.contains("gave up") })
    }

    func testSyncNowConnectsWhenTheMacShowsUpWhileItLooks() async {
        let mac = FakeMac("Studio")
        let presence = FakePresence(reachable: false)
        let sync = makeManager(paired: mac, presence: presence, discoveryWait: .seconds(10))
        await settle()

        sync.syncNow(.manual)
        await settle()
        presence.set(true)
        let ended = await waitUntil(timeout: 2) { !sync.isRunning }
        await settle()

        XCTAssertTrue(ended, "the wait ends with the browse result, not the clock")
        XCTAssertEqual(mac.connects, 1, "one pass: the appearance fed the waiting pass, it didn't queue another")
        XCTAssertNotNil(sync.lastSyncAt)
    }

    /// Pairing starts the browse and connects in the same breath: it has to
    /// wait for the first result instead of failing with "not found".
    func testPairingWaitsForTheBrowseToFindTheMac() async {
        let mac = FakeMac("Studio")
        let presence = FakePresence(reachable: false)
        let sync = makeManager(paired: nil, macs: [mac], presence: presence, discoveryWait: .seconds(10))
        final class Box { var result: SyncManager.PairingResult? }
        let box = Box()

        Task { @MainActor in box.result = await sync.pair(with: mac.invite) }
        await settle()
        XCTAssertNil(box.result, "still looking")
        presence.set(true)
        _ = await waitUntil { box.result != nil }

        XCTAssertEqual(box.result, .paired)
        XCTAssertEqual(mac.with { $0.endpoints }, [FakePresence.endpoint])
    }

    /// With Local Network access off the browse can never find the Mac: say
    /// so at once, in words with the way out — not "open Huske on your Mac"
    /// after a timeout.
    func testPairingWithLocalNetworkOffSaysSoAtOnce() async {
        let mac = FakeMac("Studio")
        let presence = FakePresence(reachable: true)
        presence.set(issue: .localNetworkDenied)
        let sync = makeManager(paired: nil, macs: [mac], presence: presence, discoveryWait: .seconds(10))
        final class Box { var result: SyncManager.PairingResult? }
        let box = Box()

        Task { @MainActor in box.result = await sync.pair(with: mac.invite) }
        let answered = await waitUntil(timeout: 2) { box.result != nil }
        if !answered { sync.cancelRun() }

        XCTAssertTrue(answered, "no point waiting out the discovery time")
        guard case let .savedButNotReached(message)? = box.result else {
            return XCTFail("expected savedButNotReached, got \(String(describing: box.result))")
        }
        XCTAssertTrue(message.contains("Local Network"), message)
        XCTAssertTrue(message.contains("Settings"), message)
        XCTAssertEqual(mac.connects, 0)
        XCTAssertEqual(sync.link, .localNetworkOff)
    }

    /// In the background the browse only runs for the pass, so the pass has
    /// to wait for it — and stop it afterwards.
    func testABackgroundPassWaitsForItsOwnBrowse() async {
        let mac = FakeMac("Studio")
        mac.with { $0.stateAfterUpload = .transcribed }  // nothing left to poll for
        let presence = FakePresence(reachable: true)
        let sync = makeManager(paired: mac, presence: presence, inBackground: true)
        await settle()
        XCTAssertFalse(presence.isBrowsing, "launched into the background: not looking")
        addRecording("a")

        await sync.runBackgroundPass()

        XCTAssertEqual(mac.uploaded, ["a"])
        XCTAssertEqual(mac.with { $0.endpoints }, [FakePresence.endpoint])
        XCTAssertFalse(presence.isBrowsing, "the pass is over")
        XCTAssertEqual(sync.link, .paused)
    }

    // MARK: backoff

    func testAFailedConnectIsRetriedWithGrowingBackoff() async {
        let mac = FakeMac("Studio")
        mac.with { $0.connectScript = Array(repeating: .fail(SyncError.timeout), count: 3) }
        let asked = Asked()
        addRecording("a")
        _ = makeManager(paired: mac, presence: FakePresence(reachable: true), retryDelay: {
            asked.failures.append($0)
            return .milliseconds(30)
        })

        let uploaded = await waitUntil { mac.uploaded == ["a"] }
        await settle()

        XCTAssertTrue(uploaded, "it keeps trying while the Mac is visible")
        XCTAssertEqual(asked.failures, [1, 2, 3], "each failure in a row waits longer")
        XCTAssertEqual(mac.connects, 4)
    }

    func testTheBackoffClockRunsFromTwoSecondsToAMinute() {
        let first = SyncManager.retryDelay(afterFailures: 1)
        XCTAssertGreaterThanOrEqual(first, .milliseconds(1600))
        XCTAssertLessThanOrEqual(first, .milliseconds(2400))
        let late = SyncManager.retryDelay(afterFailures: 12)
        XCTAssertGreaterThanOrEqual(late, .seconds(48))
        XCTAssertLessThanOrEqual(late, .seconds(60))
    }

    func testSaysWhenItWillTryAgain() async {
        let (sync, _, _, _) = await failingVisibleMac(retryIn: .seconds(30))

        XCTAssertEqual(sync.retryAt, startOfTime.addingTimeInterval(30))
        XCTAssertEqual(sync.link, .retrying(at: startOfTime.addingTimeInterval(30)))
        XCTAssertEqual(sync.link.label(now: startOfTime.addingTimeInterval(18)),
                       "Couldn't connect · trying again in 12 s")
        XCTAssertNotNil(sync.lastError)
    }

    func testTheMacComingBackRetriesAtOnceAndStartsTheBackoffOver() async {
        let (sync, mac, presence, asked) = await failingVisibleMac()

        presence.set(false)
        await settle()
        XCTAssertNil(sync.retryAt, "nothing to retry against")
        XCTAssertEqual(sync.link, .searching)
        XCTAssertEqual(mac.connects, 1)

        presence.set(true)
        let retried = await waitUntil { mac.connects == 2 && !sync.isRunning }

        XCTAssertTrue(retried, "the Mac reappearing is the retry — not the 60 s clock")
        XCTAssertEqual(asked.failures, [1, 1], "and the failure count started over")
    }

    /// Wi-Fi ↔ peer-to-peer: the same Mac, another way to it.
    func testSeeingTheMacAnotherWayRetriesAtOnce() async {
        let (sync, mac, presence, asked) = await failingVisibleMac()

        presence.set(routes: [.wifi, .peerToPeer])
        let retried = await waitUntil { mac.connects == 2 && !sync.isRunning }

        XCTAssertTrue(retried)
        XCTAssertEqual(asked.failures, [1, 1])
    }

    func testANetworkChangeRetriesAtOnce() async {
        let path = FakePath()
        let (sync, mac, _, asked) = await failingVisibleMac(path: path)
        await settle()
        XCTAssertEqual(mac.connects, 1, "the first reading says where we are; it is not a change")
        XCTAssertEqual(sync.networkPath, FakePath.wifi)

        path.set(NetworkPath(hasLocalNetwork: true, interfaces: ["en0", "pdp_ip0"]))
        let retried = await waitUntil { mac.connects == 2 && !sync.isRunning }

        XCTAssertTrue(retried)
        XCTAssertEqual(asked.failures, [1, 1])
    }

    func testComingToTheFrontRetriesAtOnce() async {
        let (sync, mac, _, asked) = await failingVisibleMac()

        sync.scenePhaseChanged(isActive: false)
        XCTAssertNil(sync.retryAt, "no clock in the background")
        sync.scenePhaseChanged(isActive: true)
        let retried = await waitUntil { mac.connects == 2 && !sync.isRunning }

        XCTAssertTrue(retried)
        XCTAssertEqual(asked.failures, [1, 1])
    }

    func testSyncNowStartsTheBackoffOver() async {
        let (sync, mac, _, asked) = await failingVisibleMac()

        sync.syncNow(.manual)
        _ = await waitUntil { mac.connects == 2 && !sync.isRunning }

        XCTAssertEqual(asked.failures, [1, 1])
    }

    func testNoRetryClockOnceTheMacIsGone() async {
        let (sync, mac, presence, _) = await failingVisibleMac(retryIn: .milliseconds(150))

        presence.set(false)
        try? await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(mac.connects, 1, "the pending retry was dropped with the Mac")
        XCTAssertFalse(sync.isRunning)
    }

    /// An unconfirmed pairing has to reach the Mac within the invite's ten
    /// minutes, recordings or not.
    func testAnUnconfirmedPairingKeepsTryingWhileTheMacIsVisible() async {
        let mac = FakeMac("Studio")
        mac.with { $0.connectScript = [.fail(SyncError.connectionClosed)] }
        let presence = FakePresence(reachable: true)
        let sync = makeManager(paired: nil, macs: [mac], presence: presence)

        _ = await sync.pair(with: mac.invite)
        let confirmed = await waitUntil { sync.hasConfirmedPairing }

        XCTAssertTrue(confirmed, "retried on its own although there is nothing to upload")
        XCTAssertEqual(mac.connects, 2)
    }

    // MARK: why isn't it syncing

    func testLocalNetworkOffIsShownAndSyncNowDoesNotWait() async {
        let mac = FakeMac("Studio")
        let presence = FakePresence(reachable: true)
        presence.set(issue: .localNetworkDenied)
        addRecording("a")
        let sync = makeManager(paired: mac, presence: presence, discoveryWait: .seconds(10))
        await settle()
        XCTAssertEqual(sync.link, .localNetworkOff)
        XCTAssertFalse(sync.isMacReachable)

        sync.syncNow(.manual)
        let ended = await waitUntil(timeout: 2) { !sync.isRunning }

        XCTAssertTrue(ended, "nobody finds the Mac while Local Network is off")
        XCTAssertEqual(mac.connects, 0)

        // The switch is flipped in Settings: sync picks up by itself.
        mac.with { $0.stateAfterUpload = .transcribed }
        presence.set(issue: nil)
        let uploaded = await waitUntil { mac.uploaded == ["a"] && !sync.isRunning }
        XCTAssertTrue(uploaded)
        XCTAssertEqual(sync.link, .visible)
    }

    func testNotOnWiFiIsShownUntilTheMacIsSeenAnyway() async {
        let mac = FakeMac("Studio")
        let presence = FakePresence(reachable: false)
        let sync = makeManager(paired: mac, presence: presence, path: FakePath(FakePath.offline))
        await settle()
        XCTAssertEqual(sync.link, .noWiFi)

        // Seen directly (peer-to-peer) although this iPhone is on no network.
        presence.set(routes: [.peerToPeer])
        presence.set(true)
        await settle()

        XCTAssertEqual(sync.link, .visible)
    }

    func testLinkFollowsAPass() async {
        let mac = FakeMac("Studio")
        mac.with {
            $0.connectScript = [.succeedAfter(.milliseconds(200))]
            $0.uploadSteps = 6
            $0.route = .peerToPeer
            $0.stateAfterUpload = .transcribed
        }
        addRecording("a")
        let sync = makeManager(paired: mac, presence: FakePresence(reachable: true))

        let connecting = await waitUntil { sync.link == .connecting }
        let connected = await waitUntil { sync.link == .connected(.peerToPeer) }
        let done = await waitUntil { sync.link == .visible }

        XCTAssertTrue(connecting)
        XCTAssertTrue(connected, "while the session is open the link says how")
        XCTAssertTrue(done, "back to nearby once the session is closed")
        XCTAssertNil(sync.route)
    }

    func testWatchesTheNetworkOnlyWhileLooking() async {
        let path = FakePath()
        let presence = FakePresence(reachable: false)
        let sync = makeManager(paired: FakeMac("Studio"), presence: presence, path: path)
        await settle()
        XCTAssertTrue(path.isWatching)
        XCTAssertEqual(sync.networkPath, FakePath.wifi)

        sync.scenePhaseChanged(isActive: false)

        XCTAssertFalse(path.isWatching, "in the background, without a pass: watch nothing")
        XCTAssertNil(sync.networkPath)
        XCTAssertEqual(sync.link, .paused)

        sync.scenePhaseChanged(isActive: true)
        await settle()
        XCTAssertTrue(path.isWatching)
        XCTAssertEqual(sync.link, .searching)
    }

    func testForgettingTheMacStopsWatching() async {
        let path = FakePath()
        let presence = FakePresence(reachable: true)
        let sync = makeManager(paired: FakeMac("Studio"), presence: presence, path: path)
        await settle()

        sync.forgetMac()

        XCTAssertFalse(presence.isBrowsing)
        XCTAssertFalse(path.isWatching)
        XCTAssertEqual(sync.macPresence, MacPresence())
        XCTAssertNil(sync.retryAt)
    }

    // MARK: journal

    /// "Copy details" has to be safe to paste into a support message.
    func testTheJournalTellsWhatHappenedWithoutNamesOrContent() async {
        let mac = FakeMac("Studio de Tiago")
        mac.with {
            $0.connectScript = [.fail(SyncError.network(.refused))]
            $0.stateAfterUpload = .transcribed
            $0.transcripts["4E1C0A5B-0F7E-4C67-9C0B-3C8F3A1B2D11"] = "[10:00:00 · mic] segredo absoluto"
        }
        addRecording("4E1C0A5B-0F7E-4C67-9C0B-3C8F3A1B2D11", title: "Reunião confidencial")
        let sync = makeManager(paired: mac, presence: FakePresence(reachable: true))

        let fetched = await waitUntil {
            self.library.recording(id: "4E1C0A5B-0F7E-4C67-9C0B-3C8F3A1B2D11")?.transcript != nil && !sync.isRunning
        }
        XCTAssertTrue(fetched)
        let report = sync.diagnosticsReport()

        for expected in [
            "mac visible", "failed after", "not accepting connections", "next attempt in", "connected in", "via wifi",
            "4E1C0A5B: sent", "4E1C0A5B: fetched", "finished", "Waiting to send: 0", "Paired: yes",
        ] {
            XCTAssertTrue(report.contains(expected), "missing \"\(expected)\" in:\n\(report)")
        }
        for secret in ["Reunião", "confidencial", "segredo", "Studio", "Tiago", "Test iPhone", "0F7E-4C67"] {
            XCTAssertFalse(report.contains(secret), "\"\(secret)\" leaked into:\n\(report)")
        }
        XCTAssertEqual(sync.lastError, nil)
    }

    func testTheJournalStaysBoundedAcrossManyPasses() async {
        let mac = FakeMac("Studio")
        let presence = FakePresence(reachable: true)
        let sync = makeManager(paired: mac, presence: presence)
        await settle()

        for _ in 0..<150 {
            presence.set(false)
            presence.set(true)
        }
        await settle()
        _ = sync

        XCTAssertLessThanOrEqual(journal.entries.count, SyncJournal.defaultCapacity)
        XCTAssertGreaterThan(journal.entries.count, 0)
    }
}
