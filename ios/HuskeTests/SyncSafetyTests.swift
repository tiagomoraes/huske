// Defects the end-to-end run found (a real SyncServer, a real engine, the
// simulator), each pinned here against the scripted Mac:
// - a pairing code the Mac no longer accepts must not cost a working pairing;
// - a Mac that refuses this iPhone is shown as that, not as "trying again";
// - deleting a recording stops its upload;
// - no pointless reconnect once the background poll window is over;
// - Retry on a recording the Mac gave up on asks the Mac to try again;
// - polling stays brisk while the Mac is transcribing and the app is open.

import HuskeSync
import Network
import XCTest
@testable import Huske

@MainActor
final class SyncSafetyTests: SyncScenarioTestCase {
    private func uploaded(to mac: FakeMac, _ stage: RemoteStage, detail: String? = nil) -> SyncRecord {
        SyncRecord(macID: mac.macID, uploadedAt: Date(),
                   remote: RemoteSnapshot(stage: stage, detail: detail, updatedAt: Date()))
    }

    // MARK: pairing must not destroy a pairing that works

    /// Found end to end: scanning a code the Mac had already pruned (any QR
    /// 10–12 minutes old) saved the dead key over the working one. The old
    /// pairing was gone and the phone retried the dead key forever.
    func testACodeTheMacRejectsDoesNotCostTheWorkingPairing() async {
        let mac = FakeMac("Studio")
        mac.with {
            $0.rejectedDeviceIDs = ["pruned-invite"]
            $0.stateAfterUpload = .transcribed
        }
        let sync = makeManager(paired: mac, presence: FakePresence(reachable: true))
        await settle()

        let result = await pair(sync, with: mac.invite(deviceID: "pruned-invite"))

        guard case let .failed(message)? = result else {
            return XCTFail("expected the code to be refused, got \(String(describing: result))")
        }
        XCTAssertTrue(message.contains("This code didn't work — make a new one on your Mac."), message)
        XCTAssertTrue(message.contains("Studio stays paired"), message)
        XCTAssertEqual(sync.pairedMac?.deviceID, mac.pairing.deviceID, "the pairing that works is still the pairing")
        XCTAssertEqual(pairingStore.load()?.deviceID, mac.pairing.deviceID, "also in the Keychain")
        XCTAssertTrue(sync.hasConfirmedPairing)
        XCTAssertFalse(sync.isRejected, "the *old* key was not refused")

        // And it still works.
        addRecording("a")
        sync.recordingSaved("a")
        let uploadedA = await waitUntil { mac.uploaded == ["a"] }
        XCTAssertTrue(uploadedA)
    }

    func testANewCodeFromTheSameMacReplacesTheOldOneOnceAccepted() async {
        let mac = FakeMac("Studio")
        mac.with { $0.states["a"] = .queued }
        addRecording("a", sync: uploaded(to: mac, .queued))
        let sync = makeManager(paired: mac, presence: FakePresence(reachable: true))
        await settle()
        let connectsBefore = mac.connects

        let result = await pair(sync, with: mac.invite(deviceID: "fresh-invite"))

        XCTAssertEqual(result, .paired)
        XCTAssertEqual(sync.pairedMac?.deviceID, "fresh-invite")
        XCTAssertEqual(pairingStore.load()?.deviceID, "fresh-invite")
        XCTAssertTrue(sync.hasConfirmedPairing)
        XCTAssertEqual(library.recording(id: "a")?.sync.remote?.stage, .queued, "what this Mac holds is kept")

        // Let the backlog finish: it rode on the session that confirmed the code.
        mac.with {
            $0.states["a"] = .transcribed
            $0.transcripts["a"] = "[10:00:00 · mic] hello"
        }
        let finished = await waitUntil(timeout: 5) { self.library.recording(id: "a")?.transcript != nil && !sync.isRunning }
        await settle()
        XCTAssertTrue(finished)
        XCTAssertEqual(mac.connects, connectsBefore + 1, "one connection for the new code, none after it")
    }

    func testSwitchingToAnotherMacWaitsForThatMacToAnswer() async {
        let oldMac = FakeMac("Old Mac")
        let newMac = FakeMac("New Mac")
        let oldPresence = FakePresence(reachable: true)
        let newPresence = FakePresence(reachable: true)
        addRecording("a", sync: uploaded(to: oldMac, .queued))
        oldMac.with { $0.states["a"] = .queued }
        newMac.with { $0.stateAfterUpload = .transcribed }
        let sync = makeManager(
            paired: oldMac, macs: [newMac], presence: nil,
            presences: [oldMac.macID: oldPresence, newMac.macID: newPresence])
        await settle()

        let result = await pair(sync, with: newMac.invite)

        XCTAssertEqual(result, .paired)
        XCTAssertEqual(sync.pairedMac?.macID, newMac.macID)
        XCTAssertEqual(pairingStore.load()?.macID, newMac.macID)
        XCTAssertFalse(oldPresence.isBrowsing, "nobody watches the old Mac any more")
        XCTAssertTrue(newPresence.isBrowsing)
        let moved = await waitUntil { newMac.uploaded == ["a"] && !sync.isRunning }
        XCTAssertTrue(moved, "what the old Mac held but never transcribed goes to the new one")
        XCTAssertEqual(newMac.with { $0.endpoints }, [FakePresence.endpoint],
                       "found on a browse of its own, and the backlog used that connection")
    }

    func testACodeForAMacThatIsNotThereChangesNothing() async {
        let oldMac = FakeMac("Old Mac")
        let newMac = FakeMac("New Mac")
        let oldPresence = FakePresence(reachable: true)
        addRecording("a", sync: uploaded(to: oldMac, .queued))
        oldMac.with { $0.states["a"] = .queued }
        let sync = makeManager(
            paired: oldMac, macs: [newMac], presence: nil,
            presences: [oldMac.macID: oldPresence, newMac.macID: FakePresence(reachable: false)],
            discoveryWait: .milliseconds(200))
        await settle()

        let result = await pair(sync, with: newMac.invite)
        sync.cancelRun()

        guard case let .failed(message)? = result else {
            return XCTFail("expected nothing to change, got \(String(describing: result))")
        }
        XCTAssertTrue(message.contains("Couldn't reach New Mac"), message)
        XCTAssertTrue(message.contains("Old Mac stays paired"), message)
        XCTAssertEqual(sync.pairedMac?.macID, oldMac.macID)
        XCTAssertEqual(pairingStore.load()?.macID, oldMac.macID)
        XCTAssertEqual(newMac.connects, 0)
        XCTAssertEqual(library.recording(id: "a")?.sync.remote?.stage, .queued, "the old Mac's state still applies")
        XCTAssertTrue(oldPresence.isBrowsing, "still watching the Mac that is paired")
    }

    /// The very first code: there is no pairing to protect, but a key the Mac
    /// refuses is no use keeping (it would be retried for ever).
    func testAFirstCodeTheMacRejectsIsNotKept() async {
        let mac = FakeMac("Studio")
        mac.with { $0.rejectedDeviceIDs = ["pruned-invite"] }
        let sync = makeManager(paired: nil, macs: [mac], presence: FakePresence(reachable: true))

        let result = await pair(sync, with: mac.invite(deviceID: "pruned-invite"))
        await settle()

        XCTAssertEqual(result, .failed(SyncManager.codeRejectedMessage))
        XCTAssertFalse(sync.isPaired)
        XCTAssertNil(pairingStore.load())
        XCTAssertEqual(mac.connects, 1, "refused once; never tried again")
    }

    /// The pass queued behind a cancelled one must not reach the *old* Mac
    /// and confirm the *new* pairing with its answer (the rerun path).
    func testAQueuedPassCannotConfirmANewPairingWithTheOldMac() async {
        let oldMac = FakeMac("Old Mac")
        oldMac.with { $0.connectScript = [.hangUntilCancelled, .succeedAfter(.milliseconds(50))] }
        let newMac = FakeMac("New Mac")
        newMac.with { $0.defaultConnect = .fail(SyncError.timeout) }
        addRecording("a")
        let sync = makeManager(paired: oldMac, macs: [newMac], presence: nil)
        sync.syncNow(.manual)
        _ = await waitUntil { oldMac.connects == 1 }
        sync.syncNow(.appActive)  // queued behind the hanging pass

        let result = await pair(sync, with: newMac.invite)
        await settle()

        guard case .failed? = result else {
            return XCTFail("the new Mac never answered, got \(String(describing: result))")
        }
        XCTAssertEqual(sync.pairedMac?.macID, oldMac.macID, "the old pairing stays, and stays the confirmed one")
        XCTAssertEqual(defaults.string(forKey: "sync.confirmedMacID"), oldMac.macID)
    }

    // MARK: a Mac that refuses this iPhone

    /// A refused key is not a hiccup: no clock, and words that say what to do.
    func testAMacThatRefusesThisPhoneIsShownAsThat() async {
        let mac = FakeMac("Studio")
        mac.with { $0.rejectedDeviceIDs = ["device-\(mac.macID)"] }
        addRecording("a")
        let sync = makeManager(paired: mac, presence: FakePresence(reachable: true))

        let refused = await waitUntil { sync.isRejected && !sync.isRunning }
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(refused)
        XCTAssertEqual(sync.link, .rejected)
        XCTAssertEqual(mac.connects, 1, "no retry clock for a key the Mac refuses")
        XCTAssertNil(sync.retryAt)
        XCTAssertEqual(sync.lastError, "Studio didn't accept this iPhone. Pair again from Huske on your Mac.")
        XCTAssertEqual(sync.link.explanation(macName: "Studio")?.contains("Pair iPhone"), true)
        XCTAssertTrue(journal.entries.contains { $0.text == "rejected by the mac" })

        // Accepted again (re-paired on the Mac): the state clears by itself.
        mac.with {
            $0.rejectedDeviceIDs = []
            $0.stateAfterUpload = .transcribed
        }
        sync.syncNow(.manual)
        let recovered = await waitUntil { !sync.isRejected && !sync.isRunning }
        XCTAssertTrue(recovered)
        XCTAssertEqual(sync.link, .visible)
    }

    /// Seen end to end: the browse reported the Mac twice in a row (first on
    /// one interface, then on two), the second report queued another pass,
    /// and the refused key was offered to the Mac again 12 ms later.
    func testARefusedKeyIsNotOfferedAgainByAPassThatWasQueued() async {
        let mac = FakeMac("Studio")
        mac.with { $0.rejectedDeviceIDs = ["device-\(mac.macID)"] }
        addRecording("a")
        let sync = makeManager(paired: mac, presence: nil)

        sync.syncNow(.recordingSaved)
        sync.syncNow(.macChanged)  // queued behind the first
        _ = await waitUntil { sync.isRejected && !sync.isRunning }
        await settle()

        XCTAssertEqual(mac.connects, 1)
        XCTAssertFalse(sync.isRunning)
    }

    // MARK: deleting a recording that is being sent

    /// Found end to end: the upload of a deleted recording ran to 100 % and
    /// the Mac transcribed it.
    func testDeletingARecordingStopsItsUploadAndThePassGoesOn() async {
        let mac = FakeMac("Studio")
        mac.with {
            $0.uploadSteps = 40  // ~2 s if nobody stops it
            $0.uploadStopsWhenCancelled = true
            $0.stateAfterUpload = .transcribed
        }
        addRecording("doomed", minutesAgo: 10)
        addRecording("kept", minutesAgo: 5)
        let sync = makeManager(paired: mac, presence: FakePresence(reachable: true))
        _ = await waitUntil { sync.uploadFraction(for: "doomed") != nil }

        library.delete("doomed")
        let moved = await waitUntil(timeout: 1.5) { mac.with { $0.offered }.contains("kept") }

        XCTAssertTrue(moved, "the pass went on to the next recording instead of finishing the deleted one")
        XCTAssertFalse(mac.uploaded.contains("doomed"), "the Mac never got the whole file")
        let done = await waitUntil(timeout: 4) { mac.uploaded == ["kept"] && !sync.isRunning }
        XCTAssertTrue(done)
        XCTAssertNil(sync.lastError, "deleting is not a sync problem")
        XCTAssertEqual(mac.with { $0.offered }.filter { $0 == "doomed" }.count, 1, "and it is never offered again")
    }

    // MARK: background

    /// Found end to end: when the 20 s background poll window ended, a queued
    /// pass connected, asked nothing and hung up.
    func testNoPassOnceTheBackgroundPollWindowIsOver() async {
        let mac = FakeMac("Studio")
        mac.with { $0.states["a"] = .queued }
        addRecording("a", sync: uploaded(to: mac, .queued))
        let sync = makeManager(paired: mac, presence: FakePresence(reachable: true), backgroundPollingWindow: 0.1)
        _ = await waitUntil { mac.connects == 1 }  // on screen: polling
        sync.scenePhaseChanged(isActive: false)
        _ = await waitUntil(timeout: 4) { !sync.isRunning }
        let connectsBefore = mac.connects
        try? await Task.sleep(for: .milliseconds(150))

        sync.syncNow(.retry)
        await settle()

        XCTAssertEqual(mac.connects, connectsBefore, "nothing to send or fetch, and not polling: don't connect")
        XCTAssertFalse(sync.isRunning)

        // Something to send is a different matter.
        addRecording("b")
        mac.with { $0.stateAfterUpload = .transcribed }
        await sync.runBackgroundPass()
        XCTAssertTrue(mac.uploaded.contains("b"))
    }

    // MARK: Retry

    /// "Try again" on a recording the Mac gave up on used to clear the label
    /// and ask for the same status again. Offering it again is the request to
    /// retry: the Mac queues it and polling resumes.
    func testRetryAsksTheMacToTryAgain() async {
        let mac = FakeMac("Studio")
        mac.with {
            $0.states["a"] = .failed
            $0.requeuesFailedOnOffer = true
        }
        addRecording("a", sync: uploaded(to: mac, .failed, detail: "decode failed"))
        let sync = makeManager(paired: mac, presence: FakePresence(reachable: true))
        await settle()
        XCTAssertEqual(mac.connects, 0, "a failed recording is not work")
        XCTAssertEqual(library.recording(id: "a").map(sync.badge(for:)), .failed(reason: "decode failed"))

        sync.retry("a")
        let queuedAgain = await waitUntil { self.library.recording(id: "a")?.sync.remote?.stage == .queued }

        XCTAssertTrue(queuedAgain, "the Mac queued it again and the phone knows")
        XCTAssertEqual(mac.with { $0.offered }, ["a"], "offered again…")
        XCTAssertEqual(mac.uploaded, [], "…but not sent again: the Mac still has the audio")

        // Polling resumed: the transcript comes back when the retry works.
        mac.with {
            $0.states["a"] = .transcribed
            $0.transcripts["a"] = "[10:00:00 · mic] second time lucky"
        }
        let fetched = await waitUntil(timeout: 5) { self.library.recording(id: "a")?.transcript != nil }
        XCTAssertTrue(fetched)
    }

    /// A Mac that doesn't retry leaves it failed: the phone says so again
    /// instead of pretending, and doesn't loop.
    func testRetryAgainstAMacThatWillNotRetryStaysFailed() async {
        let mac = FakeMac("Studio")
        mac.with { $0.states["a"] = .failed }
        addRecording("a", sync: uploaded(to: mac, .failed, detail: "decode failed"))
        let sync = makeManager(paired: mac, presence: FakePresence(reachable: true))
        await settle()

        sync.retry("a")
        let asked = await waitUntil { mac.with { $0.offered } == ["a"] && !sync.isRunning }
        await settle()

        XCTAssertTrue(asked)
        XCTAssertEqual(library.recording(id: "a")?.sync.remote?.stage, .failed)
        XCTAssertEqual(mac.with { $0.offered }, ["a"], "asked once, not in a loop")
        XCTAssertEqual(mac.connects, 1)
    }

    func testRetryOnASendFailureSendsItAgain() async {
        let mac = FakeMac("Studio")
        mac.with { $0.stateAfterUpload = .transcribed }
        var failed = SyncRecord()
        failed.failure = "This recording is too large to send to Studio."
        addRecording("a", sync: failed)
        let sync = makeManager(paired: mac, presence: FakePresence(reachable: true))
        await settle()
        XCTAssertEqual(library.recording(id: "a").map(sync.badge(for:)),
                       .sendFailed(reason: "This recording is too large to send to Studio."))
        XCTAssertEqual(mac.connects, 0)

        sync.retry("a")
        let sent = await waitUntil { mac.uploaded == ["a"] }

        XCTAssertTrue(sent)
        XCTAssertNil(library.recording(id: "a")?.sync.failure)
    }

    // MARK: polling

    /// The steady 2 → 3 → 4.5 … 10 s back-off added seconds to a short
    /// recording's round trip. While the Mac is transcribing and the app is
    /// open, the answer is moments away.
    func testPollingStaysBriskWhileTheMacTranscribesOnScreen() {
        var delay = 0.0
        var waits: [Double] = []
        for _ in 0..<6 {
            delay = SyncManager.pollDelay(after: delay, transcribingOnScreen: true)
            waits.append(delay)
        }
        XCTAssertEqual(waits, [2, 2, 2, 2, 2, 2])
    }

    func testPollingEasesOffWhileRecordingsOnlyWaitInLine() {
        var delay = 0.0
        var waits: [Double] = []
        for _ in 0..<7 {
            delay = SyncManager.pollDelay(after: delay, transcribingOnScreen: false)
            waits.append(delay)
        }
        XCTAssertEqual(waits, [2, 3, 4.5, 6.75, 10, 10, 10])
        XCTAssertEqual(SyncManager.pollDelay(after: 10, transcribingOnScreen: true), 2, "brisk again once it starts")
    }

    // MARK: words

    func testTheWaitingLineSaysWhyNothingIsBeingSent() async {
        let mac = FakeMac("Studio")
        let presence = FakePresence(reachable: false)
        let path = FakePath()
        let sync = makeManager(paired: mac, presence: presence, path: path)
        await settle()
        XCTAssertEqual(sync.waitingLine, "Waiting for Studio. Open Huske on your Mac.")

        path.set(FakePath.offline)
        await settle()
        XCTAssertEqual(sync.waitingLine, LinkState.noWiFi.explanation(macName: "Studio"))

        presence.set(issue: .localNetworkDenied)
        await settle()
        XCTAssertEqual(sync.waitingLine, LinkState.localNetworkOff.explanation(macName: "Studio"))

        presence.set(issue: nil)
        path.set(FakePath.wifi)
        presence.set(true)
        await settle()
        XCTAssertEqual(sync.waitingLine, "Ready to send to Studio.")
    }
}
