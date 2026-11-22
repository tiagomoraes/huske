// SyncManager against a scripted Mac behind the transport seam
// (`MacConnecting` / `MacSession` / `PresenceSource`). No network, no Bonjour.

import HuskeSync
import Network
import XCTest
@testable import Huske

// MARK: - fakes

/// A Mac whose answers each test scripts. Thread-safe: SyncManager calls the
/// session from the main actor, tests read it from the main actor, and the
/// protocol requires `Sendable`.
final class FakeMac: @unchecked Sendable {
    enum ConnectStep {
        case succeed
        case fail(Error)
        /// Never answers; ends only when the connecting task is cancelled.
        case hangUntilCancelled
        case succeedAfter(Duration)
    }

    struct State {
        var connectScript: [ConnectStep] = []
        var defaultConnect: ConnectStep = .succeed
        var connects = 0
        /// Where each `connect(to:)` was told to go (the presence source's
        /// endpoint), and how many connects had to find the Mac themselves.
        var endpoints: [NWEndpoint] = []
        var browses = 0
        var route: SyncRoute = .wifi
        /// PSK identities the Mac no longer accepts (a pruned invite, a
        /// forgotten device): the handshake is refused.
        var rejectedDeviceIDs: Set<String> = []
        /// Every `offer`, including those answered "skip".
        var offered: [String] = []
        /// Offering a recording that failed on the Mac queues it again there
        /// (the phone's Retry, sync-protocol.md § Retrying).
        var requeuesFailedOnOffer = false
        /// Each upload step reports progress and stops when its task is
        /// cancelled, as HuskeSync does between chunks.
        var uploadStopsWhenCancelled = false
        var engineAvailable = true
        /// Thrown by every upload while set.
        var uploadError: Error?
        var uploaded: [String] = []
        var stateAfterUpload: RemoteState = .queued
        var states: [String: RemoteState] = [:]
        var transcripts: [String: String] = [:]
        var closes = 0
        /// > 0: uploads take this many steps of `stepDelay` and, like
        /// Network.framework I/O, ignore task cancellation — only closing
        /// the session stops them.
        var uploadSteps = 0
        var stepDelay: TimeInterval = 0.05
    }

    let macID: String
    let name: String
    private let lock = NSLock()
    private var state = State()

    init(_ name: String, macID: String = UUID().uuidString) {
        self.name = name
        self.macID = macID
    }

    func with<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    var connects: Int { with { $0.connects } }
    var uploaded: [String] { with { $0.uploaded } }

    var pairing: PairedMac {
        PairedMac(macID: macID, macName: name, deviceID: "device-\(macID)",
                  key: Data(repeating: 7, count: 32), pairedAt: Date())
    }

    var invite: PairingInvite {
        invite(deviceID: "device-\(macID)")
    }

    /// A new pairing code from this Mac (its own PSK identity).
    func invite(deviceID: String) -> PairingInvite {
        PairingInvite(macID: macID, macName: name, deviceID: deviceID,
                      key: Data(repeating: 9, count: 32), expiresAt: Date().addingTimeInterval(600))
    }
}

struct FakeConnector: MacConnecting {
    let mac: FakeMac?
    /// The PSK identity this connector presents (nil: never refused).
    var deviceID: String?

    func connect(timeout: TimeInterval) async throws -> any MacSession {
        try await open(nil)
    }

    func connect(to endpoint: NWEndpoint, timeout: TimeInterval) async throws -> any MacSession {
        try await open(endpoint)
    }

    private func open(_ endpoint: NWEndpoint?) async throws -> any MacSession {
        guard let mac else { throw SyncError.macNotFound }
        let step = mac.with { state -> FakeMac.ConnectStep in
            state.connects += 1
            if let endpoint { state.endpoints.append(endpoint) } else { state.browses += 1 }
            if let deviceID, state.rejectedDeviceIDs.contains(deviceID) {
                return .fail(SyncError.handshakeFailed("TLS error -9864"))
            }
            return state.connectScript.isEmpty ? state.defaultConnect : state.connectScript.removeFirst()
        }
        switch step {
        case .succeed: break
        case let .fail(error): throw error
        case .hangUntilCancelled: try await Task.sleep(for: .seconds(3600))
        case let .succeedAfter(delay): try await Task.sleep(for: delay)
        }
        return FakeSession(mac: mac)
    }
}

struct FakeSession: MacSession {
    final class Link: @unchecked Sendable {
        private let lock = NSLock()
        private var closed = false
        var isClosed: Bool { lock.withLock { closed } }
        func close() { lock.withLock { closed = true } }
    }

    let mac: FakeMac
    let link = Link()

    var welcome: Welcome {
        Welcome(protocolVersion: 1, macID: mac.macID, macName: mac.name, serverVersion: "test",
                engineAvailable: mac.with { $0.engineAvailable })
    }

    var route: SyncRoute { mac.with { $0.route } }

    func upload(manifest: RecordingManifest, fileURL: URL,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> RemoteStatus {
        if let error = mac.with({ $0.uploadError }) { throw error }
        // An offer for something the Mac already holds is answered "skip" —
        // after queueing it again, if it had failed there and the Mac retries.
        let held = mac.with { state -> RemoteState? in
            state.offered.append(manifest.id)
            guard let known = state.states[manifest.id], ![.unknown, .receiving].contains(known) else { return nil }
            if known == .failed, state.requeuesFailedOnOffer { state.states[manifest.id] = .queued }
            return state.states[manifest.id]
        }
        if let held { return RemoteStatus(recordingID: manifest.id, state: held) }
        let (steps, delay, stoppable) = mac.with { ($0.uploadSteps, $0.stepDelay, $0.uploadStopsWhenCancelled) }
        for step in 0..<steps {
            if link.isClosed { throw SyncError.connectionClosed }
            if stoppable {
                try Task.checkCancellation()
                progress(manifest.byteCount * Int64(step) / Int64(steps), manifest.byteCount)
            }
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { continuation.resume() }
            }
        }
        if stoppable { try Task.checkCancellation() }
        progress(manifest.byteCount, manifest.byteCount)
        let state = mac.with { state -> RemoteState in
            state.uploaded.append(manifest.id)
            state.states[manifest.id] = state.stateAfterUpload
            return state.stateAfterUpload
        }
        return RemoteStatus(recordingID: manifest.id, state: state)
    }

    func status(_ recordingIDs: [String]) async throws -> [RemoteStatus] {
        mac.with { state in
            recordingIDs.map { RemoteStatus(recordingID: $0, state: state.states[$0] ?? .unknown) }
        }
    }

    func transcript(_ recordingID: String) async throws -> String? {
        mac.with { $0.transcripts[recordingID] }
    }

    func close() async {
        link.close()
        mac.with { $0.closes += 1 }
    }
}

/// Models `MacPresenceMonitor`: reports the Mac (at `endpoint`) only while
/// browsing, and nothing while the browser has an issue.
final class FakePresence: PresenceSource, @unchecked Sendable {
    /// Where this fake sees the Mac.
    static let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 4242)

    private let lock = NSLock()
    private var continuations: [AsyncStream<MacPresence>.Continuation] = []
    private var macVisible: Bool
    private var routes: [SyncRoute] = [.wifi]
    private var issue: DiscoveryIssue?
    private var browsing = false
    private var reported = MacPresence()
    private var startCount = 0

    init(reachable: Bool) {
        macVisible = reachable
    }

    var presenceUpdates: AsyncStream<MacPresence> {
        AsyncStream { continuation in
            lock.lock()
            continuations.append(continuation)
            continuation.yield(reported)
            lock.unlock()
        }
    }

    var starts: Int { lock.withLock { startCount } }
    var isBrowsing: Bool { lock.withLock { browsing } }
    private var refreshCount = 0
    /// A Mac that only a fresh browse finds again (peer-to-peer after the
    /// iPhone left Wi-Fi): the next `refresh()` makes it visible.
    private var appearsOnRefresh = false
    var refreshes: Int { lock.withLock { refreshCount } }

    func refresh() {
        let appear: Bool = lock.withLock {
            guard browsing else { return false }
            refreshCount += 1
            return appearsOnRefresh
        }
        if appear { set(true) }
    }

    func appearOnNextRefresh() {
        lock.withLock { appearsOnRefresh = true }
    }

    func start() {
        lock.withLock {
            startCount += 1
            browsing = true
        }
        publish()
    }

    func stop() {
        lock.withLock { browsing = false }
        publish()
    }

    func set(_ reachable: Bool) {
        lock.withLock { macVisible = reachable }
        publish()
    }

    /// Still there, but seen another way (Wi-Fi ↔ direct).
    func set(routes: [SyncRoute]) {
        lock.withLock { self.routes = routes }
        publish()
    }

    /// What keeps the browser from looking (nil = it works again).
    func set(issue: DiscoveryIssue?) {
        lock.withLock { self.issue = issue }
        publish()
    }

    private func publish() {
        lock.lock()
        let visible = browsing && macVisible && issue == nil
        let value = MacPresence(
            isBrowsing: browsing, issue: browsing ? issue : nil,
            endpoint: visible ? Self.endpoint : nil, routes: visible ? routes : [])
        guard value != reported else {
            lock.unlock()
            return
        }
        reported = value
        let targets = continuations
        lock.unlock()
        for continuation in targets { continuation.yield(value) }
    }
}

// MARK: - tests

@MainActor
final class SyncManagerTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var library: LibraryStore!
    private var managers: [SyncManager] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncManagerTests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "SyncManagerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        library = LibraryStore(rootDirectory: directory)
    }

    override func tearDown() async throws {
        for manager in managers { manager.forgetMac() }
        managers = []
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: helpers

    private func makeManager(
        paired: FakeMac?, macs: [FakeMac] = [], presence: FakePresence? = nil, confirmed: Bool = true,
        retryDelay: @escaping (Int) -> Duration = { _ in .milliseconds(50) },
        backgroundPollingWindow: TimeInterval = 20,
        applicationIsInBackground: @escaping @MainActor () -> Bool = { false }
    ) -> SyncManager {
        if let paired, confirmed { defaults.set(paired.macID, forKey: "sync.confirmedMacID") }
        let known = macs + (paired.map { [$0] } ?? [])
        let manager = SyncManager(
            library: library,
            pairingStore: InMemoryPairingStore(paired?.pairing),
            defaults: defaults,
            defaultDeviceName: "Test iPhone",
            makeConnector: { pairing, _ in FakeConnector(mac: known.first { $0.macID == pairing.macID }) },
            makePresence: { _ in presence },
            retryDelay: retryDelay,
            backgroundPollingWindow: backgroundPollingWindow,
            applicationIsInBackground: applicationIsInBackground,
            makePathSource: { nil })
        managers.append(manager)
        return manager
    }

    /// A finished recording with a small audio file on disk.
    @discardableResult
    private func addRecording(_ id: String, minutesAgo: Double, writeFile: Bool = true,
                              sync: SyncRecord = SyncRecord()) -> Recording {
        let recording = Recording(
            id: id, title: "Recording \(id)", startedAt: Date().addingTimeInterval(-minutesAgo * 60),
            duration: 12, fileName: "\(id).m4a", byteCount: 16, capture: .complete, sync: sync)
        if writeFile {
            try? Data("synthetic audio \(id)".utf8).write(to: library.audioURL(for: recording))
        }
        library.insert(recording)
        return recording
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Whether `task` ends within `seconds` (without hanging the test if not).
    private func finishes(_ task: Task<Void, Never>?, within seconds: TimeInterval) async -> Bool {
        guard let task else { return true }
        final class Flag { var done = false }
        let flag = Flag()
        Task { @MainActor in
            await task.value
            flag.done = true
        }
        return await waitUntil(timeout: seconds) { flag.done }
    }

    /// `pair(with:)`, giving up (and unblocking it) after `seconds`.
    private func pair(_ sync: SyncManager, with mac: FakeMac,
                      within seconds: TimeInterval = 3) async -> SyncManager.PairingResult? {
        final class Box { var result: SyncManager.PairingResult? }
        let box = Box()
        Task { @MainActor in box.result = await sync.pair(with: mac.invite) }
        _ = await waitUntil(timeout: seconds) { box.result != nil }
        if box.result == nil { sync.cancelRun() }
        return box.result
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
    }

    // MARK: happy path

    func testUploadsPollsAndFetchesTranscript() async {
        let mac = FakeMac("Studio")
        mac.with { $0.stateAfterUpload = .transcribed; $0.transcripts["a"] = "[10:00:00 · mic] hello" }
        addRecording("a", minutesAgo: 5)
        let sync = makeManager(paired: mac)

        await sync.syncNow(.manual)?.value

        XCTAssertEqual(mac.uploaded, ["a"])
        XCTAssertEqual(library.recording(id: "a")?.transcript?.markdown, "[10:00:00 · mic] hello")
        XCTAssertNil(sync.lastError)
        XCTAssertFalse(sync.isRunning)
    }

    // MARK: failures that belong to the connection, not the recording

    /// A Wi-Fi drop mid-upload surfaces from Network.framework as
    /// `SyncError.network(…)`. That is the connection's problem: it must not
    /// leave every queued recording permanently "Couldn't send".
    func testNetworkErrorMidUploadDoesNotFailTheRecordings() async {
        let mac = FakeMac("Studio")
        mac.with {
            $0.uploadError = SyncError.network(.unreachable("Network is down, errno 50"))
            $0.stateAfterUpload = .transcribed
        }
        addRecording("old", minutesAgo: 10)
        addRecording("new", minutesAgo: 5)
        let sync = makeManager(paired: mac)

        await sync.syncNow(.manual)?.value

        XCTAssertNil(library.recording(id: "old")?.sync.failure, "a dropped network is not this recording's fault")
        XCTAssertNil(library.recording(id: "new")?.sync.failure)
        XCTAssertEqual(sync.pendingUploadCount, 2, "both stay queued for the next attempt")
        XCTAssertNotNil(sync.lastError, "the run reports the connection problem instead")

        // Once the network is back, both go out without anyone pressing Retry.
        mac.with { $0.uploadError = nil }
        await sync.syncNow(.manual)?.value
        XCTAssertEqual(Set(mac.uploaded), ["old", "new"])
    }

    /// A recording whose audio file is gone (deleted while it was being
    /// prepared, lost on disk) can never upload. It must fail on its own,
    /// not stop the run and hold up every newer recording behind it.
    func testMissingAudioFileFailsOnlyThatRecording() async {
        let mac = FakeMac("Studio")
        mac.with { $0.stateAfterUpload = .transcribed }
        addRecording("gone", minutesAgo: 10, writeFile: false)
        addRecording("fine", minutesAgo: 5)
        let sync = makeManager(paired: mac)

        await sync.syncNow(.manual)?.value

        XCTAssertEqual(mac.uploaded, ["fine"], "the newer recording still goes out")
        XCTAssertNotNil(library.recording(id: "gone")?.sync.failure)
        XCTAssertNil(sync.lastError, "nothing is wrong with the connection")
    }

    /// The Mac stays visible on the network but one connection fails (its
    /// listener restarted, a timeout). The app says "Huske will try again" —
    /// so it must, without waiting for the user to leave and come back.
    func testRetriesOnItsOwnWhileTheMacStaysReachable() async {
        let mac = FakeMac("Studio")
        mac.with { $0.connectScript = [.fail(SyncError.connectionClosed)] }
        let presence = FakePresence(reachable: true)
        addRecording("a", minutesAgo: 1)
        // The Mac is visible at launch → a pass starts → its connection drops.
        let sync = makeManager(paired: mac, presence: presence)
        _ = await waitUntil { mac.connects >= 1 && !sync.isRunning }
        XCTAssertEqual(mac.uploaded, [])

        let retried = await waitUntil(timeout: 3) { mac.uploaded == ["a"] }

        XCTAssertTrue(retried, "a transient failure is retried while the Mac is reachable")
        XCTAssertNil(sync.lastError)
    }

    func testDoesNotRetryOnItsOwnWhenTheMacRejectsThisPhone() async {
        let mac = FakeMac("Studio")
        mac.with { $0.defaultConnect = .fail(SyncError.handshakeFailed("unknown PSK identity")) }
        let presence = FakePresence(reachable: true)
        addRecording("a", minutesAgo: 1)
        let sync = makeManager(paired: mac, presence: presence)
        _ = await waitUntil { mac.connects >= 1 && !sync.isRunning }

        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(mac.connects, 1, "only re-pairing fixes a rejected key; don't hammer the Mac")
        XCTAssertNotNil(sync.lastError)
    }

    // MARK: polling

    /// Without an engine the Mac keeps an upload at "received" forever.
    /// Polling for it would keep a connection open and "Sync now" spinning
    /// for as long as the app is on screen.
    func testStopsPollingWhenTheMacHasNoEngine() async {
        let mac = FakeMac("Studio")
        mac.with { $0.engineAvailable = false; $0.stateAfterUpload = .received }
        addRecording("a", minutesAgo: 1)
        let sync = makeManager(paired: mac)

        let run = sync.syncNow(.manual)
        let ended = await finishes(run, within: 4)
        if !ended { sync.cancelRun() }

        XCTAssertTrue(ended, "the run ends instead of polling a Mac that can't transcribe")
        XCTAssertEqual(mac.uploaded, ["a"])
        XCTAssertEqual(library.recording(id: "a")?.sync.remote?.stage, .received)
    }

    // MARK: background

    /// BGTaskScheduler's expiration handler cancels the task that awaits the
    /// pass. The sync run underneath must end with it, or the BGTask is never
    /// completed in time and iOS kills the app (and throttles future tasks).
    func testBackgroundPassEndsWhenItsTaskIsCancelled() async {
        let mac = FakeMac("Studio")
        mac.with { $0.defaultConnect = .hangUntilCancelled }
        addRecording("a", minutesAgo: 1)
        let sync = makeManager(paired: mac)

        let pass = Task { @MainActor in await sync.runBackgroundPass() }
        _ = await waitUntil { mac.connects == 1 }
        pass.cancel()
        let ended = await finishes(pass, within: 2)
        if !ended { sync.cancelRun() }

        XCTAssertTrue(ended, "cancelling the background pass cancels the run")
        _ = await waitUntil { !sync.isRunning }
        XCTAssertFalse(sync.isRunning)
    }

    /// A BGTask launches the app straight into the background: SwiftUI never
    /// reports a scene phase, so the pass must not poll as if on screen.
    func testBackgroundLaunchPollsOnlyForTheBackgroundWindow() async {
        let mac = FakeMac("Studio")
        let uploaded = SyncRecord(macID: mac.macID, uploadedAt: Date(),
                                  remote: RemoteSnapshot(stage: .queued, updatedAt: Date()))
        addRecording("a", minutesAgo: 1, sync: uploaded)
        mac.with { $0.states["a"] = .queued }
        let sync = makeManager(paired: mac, backgroundPollingWindow: 0.5,
                               applicationIsInBackground: { true })

        let pass = Task { @MainActor in await sync.runBackgroundPass() }
        let ended = await finishes(pass, within: 6)
        if !ended { sync.cancelRun() }

        XCTAssertTrue(ended, "a background pass stops polling once its window is over")
    }

    // MARK: presence (peer-to-peer browsing costs battery)

    func testBrowsesForTheMacOnlyWhileOnScreen() async {
        let presence = FakePresence(reachable: false)
        let sync = makeManager(paired: FakeMac("Studio"), presence: presence)
        await settle()
        XCTAssertTrue(presence.isBrowsing, "on screen: watch for the Mac")

        sync.scenePhaseChanged(isActive: false)
        XCTAssertFalse(presence.isBrowsing, "in the background (e.g. a long recording): stop browsing")

        sync.scenePhaseChanged(isActive: true)
        XCTAssertTrue(presence.isBrowsing)
    }

    func testBrowsesInTheBackgroundOnlyWhileASyncRunsThere() async {
        let mac = FakeMac("Studio")
        mac.with { $0.connectScript = [.hangUntilCancelled] }
        // Visible, because a pass no longer tries to connect to a Mac the
        // browse can't see (it would wait for it instead).
        let presence = FakePresence(reachable: true)
        let sync = makeManager(paired: mac, presence: presence)
        await settle()
        sync.scenePhaseChanged(isActive: false)
        addRecording("a", minutesAgo: 1)

        sync.recordingSaved("a")  // stopped from the Lock Screen
        XCTAssertTrue(presence.isBrowsing, "a run is in flight")
        _ = await waitUntil { mac.connects == 1 }
        sync.cancelRun()
        _ = await waitUntil { !sync.isRunning }

        XCTAssertFalse(presence.isBrowsing, "the run is over and the app is still in the background")
    }

    func testDoesNotBrowseWhenLaunchedIntoTheBackground() async {
        let presence = FakePresence(reachable: false)
        _ = makeManager(paired: FakeMac("Studio"), presence: presence, applicationIsInBackground: { true })
        await settle()

        XCTAssertFalse(presence.isBrowsing, "an App Intent or BGTask launch reports no scene phase")
    }

    // MARK: pairing

    /// Re-pairing to another Mac while a pass is running and another is queued
    /// (the app came back from the Camera with the pairing link) must not
    /// let the queued pass talk to the *old* Mac and mark the new pairing
    /// confirmed — the new Mac's pending slot would never be claimed.
    func testPairingANewMacIsConfirmedOnlyByThatMac() async {
        let oldMac = FakeMac("Old Mac")
        // First pass hangs (e.g. a slow browse); the queued rerun connects.
        oldMac.with { $0.connectScript = [.hangUntilCancelled, .succeedAfter(.milliseconds(100))] }
        let newMac = FakeMac("New Mac")
        let sync = makeManager(paired: oldMac, macs: [newMac], confirmed: false)

        sync.syncNow(.manual)
        _ = await waitUntil { oldMac.connects == 1 }
        sync.syncNow(.appActive)  // queues another pass

        let result = await pair(sync, with: newMac)
        await settle()

        XCTAssertEqual(sync.pairedMac?.macID, newMac.macID)
        if result == .paired {
            XCTAssertEqual(newMac.connects, 1, "reported paired, so the new Mac must have been contacted")
        }
        XCTAssertEqual(result, .paired, "the new Mac answers right away")
        XCTAssertEqual(newMac.connects, 1)
    }

    /// HuskeSync's I/O doesn't observe task cancellation, so cancelling a
    /// pass mid-upload let the whole file finish first. Re-pairing must not
    /// sit on "Connecting to …" until an upload to the old Mac is done.
    func testPairingDoesNotWaitForAnUploadToTheOldMacToFinish() async {
        let oldMac = FakeMac("Old Mac")
        oldMac.with { $0.uploadSteps = 100 }  // ~5 s
        let newMac = FakeMac("New Mac")
        addRecording("a", minutesAgo: 1)
        let sync = makeManager(paired: oldMac, macs: [newMac])
        sync.syncNow(.manual)
        _ = await waitUntil { sync.uploadFraction(for: "a") != nil }
        try? await Task.sleep(for: .milliseconds(150))

        let result = await pair(sync, with: newMac, within: 2)

        XCTAssertEqual(result, .paired)
        XCTAssertEqual(oldMac.uploaded, [], "the upload to the old Mac was abandoned")
        XCTAssertNil(library.recording(id: "a")?.sync.failure, "abandoning an upload is not a failure")
    }

    /// "Forget this Mac", then pair another one: recordings the old Mac held
    /// but never transcribed now go to the new Mac, and must not keep showing
    /// the old Mac's state ("Queued on your Mac") while they wait.
    func testPairingAnotherMacAfterForgetResetsWhatTheOldMacHeld() async {
        let oldMac = FakeMac("Old Mac")
        let newMac = FakeMac("New Mac")
        newMac.with { $0.defaultConnect = .fail(SyncError.macNotFound) }
        let queuedOnOld = SyncRecord(macID: oldMac.macID, uploadedAt: Date(),
                                     remote: RemoteSnapshot(stage: .queued, updatedAt: Date()))
        addRecording("a", minutesAgo: 3, sync: queuedOnOld)
        let sync = makeManager(paired: oldMac, macs: [newMac])

        sync.forgetMac()
        _ = await pair(sync, with: newMac)

        let recording = library.recording(id: "a")
        XCTAssertNil(recording?.sync.remote, "the old Mac's state no longer applies")
        XCTAssertEqual(recording.map(sync.badge(for:)), .waitingForMac)
        XCTAssertEqual(sync.pendingUploadCount, 1)
    }

    func testRePairingTheSameMacKeepsWhatItHolds() async {
        let mac = FakeMac("Studio")
        mac.with { $0.states["a"] = .queued }
        let queued = SyncRecord(macID: mac.macID, uploadedAt: Date(),
                                remote: RemoteSnapshot(stage: .queued, updatedAt: Date()))
        addRecording("a", minutesAgo: 3, sync: queued)
        let sync = makeManager(paired: mac)

        sync.forgetMac()
        let result = await pair(sync, with: mac)

        XCTAssertEqual(result, .paired)
        XCTAssertEqual(mac.uploaded, [], "the Mac already has it; nothing is sent twice")
        XCTAssertEqual(library.recording(id: "a")?.sync.remote?.stage, .queued)
    }

    // MARK: naming the Mac

    /// Two Macs that both call themselves "MacBook Pro": the name given on
    /// this iPhone is what shows, and the Mac's own name (re-sent in every
    /// `welcome`) must not overwrite it.
    func testTheNameGivenOnThisIPhoneSurvivesTheMacAnswering() async {
        let mac = FakeMac("MacBook Pro")
        let sync = makeManager(paired: mac)

        sync.macNickname = "Office"
        await sync.syncNow(.manual)?.value

        XCTAssertEqual(mac.connects, 1)
        XCTAssertEqual(sync.macName, "Office")
        XCTAssertEqual(sync.macOwnName, "MacBook Pro", "the Mac's own name is still known")
    }

    func testAnEmptyNameMeansTheMacsOwnName() {
        let mac = FakeMac("MacBook Pro")
        let sync = makeManager(paired: mac)

        sync.macNickname = "Office "
        XCTAssertEqual(sync.macNickname, "Office ", "the field keeps what is being typed")
        XCTAssertEqual(sync.macName, "Office", "surrounding spaces are not part of the name")

        sync.macNickname = "   "
        XCTAssertEqual(sync.macNickname, "")
        XCTAssertEqual(sync.macName, "MacBook Pro")
    }

    func testTheNameBelongsToThatMac() async {
        let home = FakeMac("MacBook Pro")
        let office = FakeMac("MacBook Pro")
        let sync = makeManager(paired: home, macs: [office])
        sync.macNickname = "Home"

        XCTAssertEqual(makeManager(paired: home).macName, "Home", "kept across launches")

        sync.forgetMac()
        _ = await pair(sync, with: office)
        XCTAssertEqual(sync.macName, "MacBook Pro", "another Mac has its own name")

        sync.forgetMac()
        _ = await pair(sync, with: home)
        XCTAssertEqual(sync.macName, "Home", "pairing the same Mac again keeps the name")
    }

    func testNamingNeedsAPairedMac() {
        let sync = makeManager(paired: nil)
        sync.macNickname = "Office"
        XCTAssertEqual(sync.macNickname, "")
        XCTAssertEqual(sync.macName, "your Mac")
    }

    /// Pairing is done when the Mac answers. The pairing screen must not sit
    /// on "Connecting to …" while the whole backlog uploads and transcribes.
    func testPairingReturnsWhenTheMacAnswersNotWhenTheBacklogIsDone() async {
        let mac = FakeMac("Studio")
        mac.with { $0.stateAfterUpload = .transcribing }  // a long transcription
        addRecording("a", minutesAgo: 30)
        addRecording("b", minutesAgo: 20)
        let sync = makeManager(paired: nil, macs: [mac])

        let result = await pair(sync, with: mac, within: 3)

        XCTAssertEqual(result, .paired)
        XCTAssertTrue(sync.hasConfirmedPairing)
        let uploaded = await waitUntil { Set(mac.uploaded) == ["a", "b"] }
        XCTAssertTrue(uploaded, "the backlog keeps going after pairing returns")
    }
}
