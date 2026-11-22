// Pairing security on the iPhone: key rotation right after pairing, telling
// the Mac when it is forgotten, and saying which install this is so a phone
// that pairs again replaces its earlier entry (sync-protocol.md § Key
// rotation, § Unpairing, § Pairing again).
//
// SyncManager runs against `KeyedMac`, a Mac that keeps its registry the way
// Huske.app does — which keys it takes, what `rekey` issues, when a key is
// retired — with one fault per interruption point: a lost answer, a lost
// `welcome`, a crash between two steps, an older app on either side. The
// invariant every test ends on: the iPhone still holds a key the Mac takes.

import HuskeSync
import Network
import Security
import XCTest
@testable import Huske

// MARK: - a Mac with a registry

final class KeyedMac: @unchecked Sendable {
    struct Device: Equatable {
        var deviceID: String
        var key: Data
        var successor: DeviceCredential?
        var installID: String?
    }

    struct State {
        var devices: [Device] = []
        /// What this Mac announces. `[]` = a Huske.app from before all of it.
        var capabilities = SyncConstants.capabilities
        /// Every `hello` the Mac processed, in order.
        var hellos: [(deviceID: String, installID: String?)] = []
        /// Identities turned away at the handshake.
        var refused: [String] = []
        var connects = 0
        var rekeys = 0
        var unpairs = 0
        var uploaded: [(recordingID: String, deviceID: String)] = []
        var uploadErrors: [String: Error] = [:]

        // Faults, each consumed by its first use.
        /// The Mac issues and stores the key; the phone never hears.
        var loseRekeyReply = false
        /// For this identity: `hello` is processed (a promotion included),
        /// then the connection drops before `welcome`.
        var loseWelcomeFor: String?
        /// The same for whichever key `rekey` issues: its first `hello` is
        /// processed (the old key retired), and the answer is lost.
        var loseWelcomeOfNextPromotion = false
        /// For this identity: the connection drops before the Mac reads
        /// `hello`. Nothing is processed; to the phone it reads as a refusal.
        var dropBeforeHelloFor: String?
        /// `rekey` answers "not now" (no spare slot).
        var rekeyUnavailable = false
        /// Every connect fails with this (the Mac is not there).
        var unreachable: Error?
    }

    /// What `SyncClient` reports when the connection closes after TLS and
    /// before `welcome` — the same error as a refused key.
    static let droppedBeforeWelcome = SyncError.handshakeFailed(
        "the Mac closed the connection before accepting this iPhone — it may have been unpaired")

    let macID = UUID().uuidString
    let name: String
    private let lock = NSLock()
    private var state = State()

    init(_ name: String = "Studio") {
        self.name = name
    }

    func with<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    var devices: [Device] { with { $0.devices } }

    /// A pairing code: the Mac knows its key from now on.
    func makeInvite() -> PairingInvite {
        let invite = PairingInvite.mint(macID: macID, macName: name)
        with { $0.devices.append(Device(deviceID: invite.deviceID, key: invite.key)) }
        return invite
    }

    /// Whether the Mac would take this identity and key right now.
    func accepts(deviceID: String, key: Data) -> Bool {
        with { state in
            state.devices.contains {
                ($0.deviceID == deviceID && $0.key == key)
                    || ($0.successor?.deviceID == deviceID && $0.successor?.key == key)
            }
        }
    }

    func accepts(_ mac: PairedMac) -> Bool { accepts(deviceID: mac.deviceID, key: mac.key) }

    /// TLS handshake + `hello`, as the Mac's side of `SyncClient.connect`.
    fileprivate func hello(deviceID: String, key: Data, installID: String?) throws {
        try with { state in
            if let error = state.unreachable { throw error }
            state.connects += 1
            if state.dropBeforeHelloFor == deviceID {
                state.dropBeforeHelloFor = nil
                throw Self.droppedBeforeWelcome
            }
            guard let index = state.devices.firstIndex(where: {
                ($0.deviceID == deviceID && $0.key == key)
                    || ($0.successor?.deviceID == deviceID && $0.successor?.key == key)
            }) else {
                state.refused.append(deviceID)
                throw SyncError.handshakeFailed("TLS error -9864")
            }
            var promoted = false
            if let successor = state.devices[index].successor, successor.deviceID == deviceID {
                // The new key was used: it is the device's only one now.
                state.devices[index].deviceID = successor.deviceID
                state.devices[index].key = successor.key
                state.devices[index].successor = nil
                promoted = true
            }
            if let installID {
                state.devices[index].installID = installID
                state.devices.removeAll { $0.installID == installID && $0.deviceID != deviceID }
            }
            state.hellos.append((deviceID, installID))
            if state.loseWelcomeFor == deviceID || (promoted && state.loseWelcomeOfNextPromotion) {
                state.loseWelcomeFor = nil
                state.loseWelcomeOfNextPromotion = false
                throw Self.droppedBeforeWelcome
            }
        }
    }
}

struct KeyedConnector: MacConnecting {
    let mac: KeyedMac
    let pairing: PairedMac
    var installID: String?
    /// What the phone announces. `[]` = an iPhone app from before all of it.
    var announces = SyncConstants.capabilities

    var asCandidate: any MacConnecting {
        KeyedConnector(mac: mac, pairing: pairing, installID: nil, announces: announces)
    }

    func connect(timeout: TimeInterval) async throws -> any MacSession {
        try mac.hello(deviceID: pairing.deviceID, key: pairing.key, installID: installID)
        return KeyedSession(mac: mac, deviceID: pairing.deviceID, announces: announces)
    }
}

struct KeyedSession: MacSession {
    let mac: KeyedMac
    /// The identity this session authenticated as.
    let deviceID: String
    let announces: [String]

    var welcome: Welcome {
        Welcome(protocolVersion: 1, macID: mac.macID, macName: mac.name, serverVersion: "test",
                engineAvailable: true, capabilities: mac.with { $0.capabilities })
    }

    func supports(_ capability: String) -> Bool {
        announces.contains(capability) && mac.with { $0.capabilities.contains(capability) }
    }

    /// The device this session belongs to — gone once its key was retired
    /// (the Mac closes such connections) or the device removed.
    private func device(_ state: inout KeyedMac.State) throws -> Int {
        guard let index = state.devices.firstIndex(where: { $0.deviceID == deviceID }) else {
            throw SyncError.connectionClosed
        }
        return index
    }

    func rekey() async throws -> DeviceCredential {
        // An older Mac hangs up on a message type it does not know.
        guard supports(SyncCapability.rekey) else { throw SyncError.connectionClosed }
        return try mac.with { state in
            let index = try device(&state)
            state.rekeys += 1
            if state.rekeyUnavailable {
                throw SyncError.protocolError(code: "unavailable", message: "no spare key slot right now")
            }
            let credential = state.devices[index].successor
                ?? DeviceCredential(deviceID: UUID().uuidString, key: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
            state.devices[index].successor = credential
            if state.loseRekeyReply {
                state.loseRekeyReply = false
                throw SyncError.connectionClosed
            }
            return credential
        }
    }

    func unpair() async throws {
        guard supports(SyncCapability.unpair) else { throw SyncError.connectionClosed }
        try mac.with { state in
            let index = try device(&state)
            state.unpairs += 1
            state.devices.remove(at: index)
        }
    }

    func upload(manifest: RecordingManifest, fileURL: URL,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> RemoteStatus {
        try mac.with { state in
            _ = try device(&state)
            if let error = state.uploadErrors[manifest.id] { throw error }
            state.uploaded.append((manifest.id, deviceID))
        }
        progress(manifest.byteCount, manifest.byteCount)
        return RemoteStatus(recordingID: manifest.id, state: .transcribed)
    }

    func status(_ recordingIDs: [String]) async throws -> [RemoteStatus] {
        try mac.with { state in
            _ = try device(&state)
            return recordingIDs.map { RemoteStatus(recordingID: $0, state: .transcribed) }
        }
    }

    func transcript(_ recordingID: String) async throws -> String? {
        try mac.with { state in
            _ = try device(&state)
            return "[10:00:00 · mic] synthetic"
        }
    }

    func close() async {}
}

/// A Keychain that can refuse to store.
final class FlakyPairingStore: PairingStoring {
    private var mac: PairedMac?
    var failsSaves = false
    private(set) var saves: [PairedMac] = []

    init(_ mac: PairedMac? = nil) {
        self.mac = mac
    }

    struct Refused: Error {}

    func load() -> PairedMac? { mac }

    func save(_ mac: PairedMac) throws {
        if failsSaves { throw Refused() }
        self.mac = mac
        saves.append(mac)
    }

    func clear() { mac = nil }
}

// MARK: - tests

@MainActor
final class PairingSecurityTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var library: LibraryStore!
    private var store: FlakyPairingStore!
    private var journal: SyncJournal!
    private var managers: [SyncManager] = []
    private let installID = "INSTALL-1"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PairingSecurityTests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "PairingSecurityTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        library = LibraryStore(rootDirectory: directory)
        store = FlakyPairingStore()
        journal = SyncJournal()
    }

    override func tearDown() async throws {
        for manager in managers {
            manager.forgetMac(tellingMac: false)
        }
        managers = []
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: helpers

    /// - Parameters:
    ///   - stored: the pairing already in the Keychain (nil = not paired).
    ///   - announces: what this iPhone app announces (`[]` = an older build).
    private func makeManager(
        _ mac: KeyedMac, stored: PairedMac? = nil, confirmed: Bool = true,
        announces: [String] = SyncConstants.capabilities, presence: FakePresence? = nil
    ) -> SyncManager {
        if let stored {
            store = FlakyPairingStore(stored)
            if confirmed { defaults.set(stored.macID, forKey: "sync.confirmedMacID") }
        }
        let installID = self.installID
        let manager = SyncManager(
            library: library,
            pairingStore: store,
            defaults: defaults,
            defaultDeviceName: "Test iPhone",
            makeConnector: { pairing, _ in
                KeyedConnector(mac: mac, pairing: pairing, installID: installID, announces: announces)
            },
            makePresence: { _ in presence },
            retryDelay: { _ in .seconds(3600) },
            makePathSource: { nil },
            journal: journal)
        managers.append(manager)
        return manager
    }

    @discardableResult
    private func addRecording(_ id: String, minutesAgo: Double = 5, writeFile: Bool = true) -> Recording {
        let recording = Recording(
            id: id, title: "Recording \(id)", startedAt: Date().addingTimeInterval(-minutesAgo * 60),
            duration: 12, fileName: "\(id).m4a", byteCount: 16, capture: .complete, sync: SyncRecord())
        if writeFile {
            try? Data("synthetic audio \(id)".utf8).write(to: library.audioURL(for: recording))
        }
        library.insert(recording)
        return recording
    }

    private func settle(_ sync: SyncManager) async {
        let deadline = Date().addingTimeInterval(3)
        while sync.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// A pairing whose rotation stopped half-way: the Mac issued a key and
    /// this iPhone stored it, but has not connected with it yet.
    private func midRotation(_ mac: KeyedMac) -> (stored: PairedMac, pending: DeviceCredential) {
        let invite = mac.makeInvite()
        let pending = DeviceCredential(deviceID: UUID().uuidString, key: Data(repeating: 5, count: 32))
        mac.with { $0.devices[$0.devices.count - 1].successor = pending }
        var stored = PairedMac(invite: invite)
        stored.pending = pending
        return (stored, pending)
    }

    private func journalText() -> String {
        journal.entries.map(\.text).joined(separator: "\n")
    }

    /// The invariant: whatever happened, this iPhone can still get in.
    private func assertNotLockedOut(_ mac: KeyedMac, file: StaticString = #filePath, line: UInt = #line) {
        guard let stored = store.load() else { return XCTFail("no pairing stored", file: file, line: line) }
        let current = mac.accepts(stored)
        let pending = stored.pending.map { mac.accepts(deviceID: $0.deviceID, key: $0.key) } ?? false
        XCTAssertTrue(current || pending, "locked out: the Mac takes neither stored key", file: file, line: line)
    }

    // MARK: rotation

    /// Pairing ends with a key that was never in the QR code, and the one
    /// that was opens nothing.
    func testPairingRotatesTheKeyAtOnce() async {
        let mac = KeyedMac()
        let invite = mac.makeInvite()
        let sync = makeManager(mac)

        let result = await sync.pair(with: invite)
        await settle(sync)

        XCTAssertEqual(result, .paired)
        let stored = try? XCTUnwrap(store.load())
        XCTAssertNotEqual(stored?.deviceID, invite.deviceID)
        XCTAssertNotEqual(stored?.key, invite.key)
        XCTAssertNil(stored?.pending)
        XCTAssertNotNil(stored?.rotatedAt)
        XCTAssertEqual(sync.pairedMac, stored)
        XCTAssertEqual(mac.devices.count, 1)
        XCTAssertEqual(mac.devices.first?.deviceID, stored?.deviceID)
        XCTAssertNil(mac.devices.first?.successor)
        XCTAssertFalse(mac.accepts(deviceID: invite.deviceID, key: invite.key), "the code's key still opens the Mac")
        XCTAssertEqual(mac.with { $0.rekeys }, 1)
        XCTAssertFalse(sync.isRejected)
        XCTAssertNil(sync.lastError)
    }

    /// Recordings go out over the session made with the new key.
    func testUploadsContinueOverTheRotatedSession() async {
        let mac = KeyedMac()
        let invite = mac.makeInvite()
        addRecording("a")
        let sync = makeManager(mac)

        _ = await sync.pair(with: invite)
        await settle(sync)

        let uploaded = mac.with { $0.uploaded }
        XCTAssertEqual(uploaded.map(\.recordingID), ["a"], "sent once")
        XCTAssertEqual(uploaded.first?.deviceID, store.load()?.deviceID)
        XCTAssertNotEqual(uploaded.first?.deviceID, invite.deviceID)
        XCTAssertNotNil(library.recording(id: "a")?.transcript)
    }

    /// A pairing made before rotation existed (the key from its link, still
    /// valid for good) is rotated the first time both sides can.
    func testAnExistingPairingIsRotatedAtItsNextSync() async {
        let mac = KeyedMac()
        let old = PairedMac(invite: mac.makeInvite())
        let sync = makeManager(mac, stored: old)

        await sync.syncNow(.manual)?.value

        XCTAssertNotNil(store.load()?.rotatedAt)
        XCTAssertFalse(mac.accepts(old))
        assertNotLockedOut(mac)
        // Once is enough.
        await sync.syncNow(.manual)?.value
        XCTAssertEqual(mac.with { $0.rekeys }, 1)
    }

    /// Huske.app from before rotation: never asked (it hangs up on a message
    /// it does not know), and the pairing works exactly as it did.
    func testAnOlderMacIsNeverAskedToRotate() async {
        let mac = KeyedMac()
        mac.with { $0.capabilities = [] }
        let invite = mac.makeInvite()
        addRecording("a")
        let sync = makeManager(mac)

        let result = await sync.pair(with: invite)
        await settle(sync)
        await sync.syncNow(.manual)?.value

        XCTAssertEqual(result, .paired)
        XCTAssertEqual(mac.with { $0.rekeys }, 0)
        XCTAssertEqual(store.load()?.deviceID, invite.deviceID)
        XCTAssertNil(store.load()?.rotatedAt)
        XCTAssertNil(store.load()?.pending)
        XCTAssertEqual(mac.with { $0.uploaded }.map(\.recordingID), ["a"])
        XCTAssertNil(sync.lastError)
    }

    /// The iPhone app from before rotation, against a Mac that has it.
    func testAnOlderPhoneNeverAsks() async {
        let mac = KeyedMac()
        let invite = mac.makeInvite()
        let sync = makeManager(mac, announces: [])

        let result = await sync.pair(with: invite)
        await settle(sync)

        XCTAssertEqual(result, .paired)
        XCTAssertEqual(mac.with { $0.rekeys }, 0)
        XCTAssertEqual(store.load()?.deviceID, invite.deviceID)
        XCTAssertTrue(mac.accepts(deviceID: invite.deviceID, key: invite.key))
    }

    // MARK: rotation, interrupted

    /// The Mac issued the key; its answer never arrived. Nothing is stored,
    /// the old key still works, and asking again gets the same key.
    func testALostAnswerToRekeyCostsNothing() async {
        let mac = KeyedMac()
        let old = PairedMac(invite: mac.makeInvite())
        mac.with { $0.loseRekeyReply = true }
        let sync = makeManager(mac, stored: old)

        await sync.syncNow(.manual)?.value

        XCTAssertEqual(store.load(), old, "nothing was received, so nothing changed")
        XCTAssertTrue(mac.accepts(old))
        let issued = mac.devices.first?.successor
        XCTAssertNotNil(issued)
        XCTAssertFalse(sync.isRejected)

        await sync.syncNow(.manual)?.value

        XCTAssertEqual(store.load()?.deviceID, issued?.deviceID, "the same key, not a second one")
        XCTAssertNotNil(store.load()?.rotatedAt)
        XCTAssertFalse(mac.accepts(old))
    }

    /// The app quit after storing the new key and before using it.
    func testQuittingBeforeTheNewKeyIsProvenResumesAtTheNextSync() async {
        let mac = KeyedMac()
        let (stored, pending) = midRotation(mac)
        let sync = makeManager(mac, stored: stored)

        await sync.syncNow(.manual)?.value

        XCTAssertEqual(store.load()?.deviceID, pending.deviceID)
        XCTAssertEqual(store.load()?.key, pending.key)
        XCTAssertNil(store.load()?.pending)
        XCTAssertNotNil(store.load()?.rotatedAt)
        XCTAssertEqual(mac.with { $0.connects }, 1, "the new key first, and it worked")
        XCTAssertEqual(mac.with { $0.rekeys }, 0)
        XCTAssertFalse(mac.accepts(deviceID: stored.deviceID, key: stored.key))
    }

    /// While proving the new key the Mac saw it (and retired the old one) but
    /// its `welcome` was lost. The iPhone holds both keys, so the next pass
    /// gets in with the new one — and nobody is told to pair again.
    func testALostWelcomeWhileProvingTheNewKey() async {
        let mac = KeyedMac()
        let invite = mac.makeInvite()
        mac.with { $0.loseWelcomeOfNextPromotion = true }
        let sync = makeManager(mac)

        let result = await sync.pair(with: invite)
        await settle(sync)

        XCTAssertEqual(result, .paired)
        // Retired on the Mac, not yet known to be proven on the phone.
        XCTAssertFalse(mac.accepts(deviceID: invite.deviceID, key: invite.key))
        XCTAssertEqual(store.load()?.deviceID, invite.deviceID)
        XCTAssertNotNil(store.load()?.pending)
        assertNotLockedOut(mac)
        XCTAssertFalse(sync.isRejected)

        await sync.syncNow(.manual)?.value

        XCTAssertNotNil(store.load()?.rotatedAt)
        XCTAssertNil(store.load()?.pending)
        XCTAssertTrue(store.load().map(mac.accepts) ?? false)
        XCTAssertFalse(sync.isRejected, "a lost answer was taken for being unpaired")
        XCTAssertNil(sync.lastError)
    }

    /// The same loss on a later pass, where the old key gets its turn: the
    /// Mac refuses it (retired), and that must not read as "unpaired".
    func testALostWelcomeIsNotMistakenForBeingUnpaired() async {
        let mac = KeyedMac()
        let (stored, pending) = midRotation(mac)
        mac.with { $0.loseWelcomeFor = pending.deviceID }
        let sync = makeManager(mac, stored: stored)

        await sync.syncNow(.manual)?.value

        XCTAssertFalse(sync.isRejected, "told the user to pair again while holding a key that works")
        XCTAssertEqual(store.load()?.deviceID, pending.deviceID)
        XCTAssertNotNil(store.load()?.rotatedAt)
        XCTAssertEqual(mac.with { $0.refused }, [stored.deviceID], "the retired key was tried once, in between")
        XCTAssertEqual(mac.with { $0.connects }, 3)
        XCTAssertNil(sync.lastError)
    }

    /// The connection dropped before the Mac read the new key's `hello`. To
    /// the phone that reads like a refusal, and the old key still works — but
    /// the unproven key is the one the Mac may yet require, so it is kept.
    func testADroppedConnectionNeverCostsTheUnprovenKey() async {
        let mac = KeyedMac()
        let (stored, pending) = midRotation(mac)
        mac.with { $0.dropBeforeHelloFor = pending.deviceID }
        let sync = makeManager(mac, stored: stored)

        await sync.syncNow(.manual)?.value

        XCTAssertTrue(store.saves.allSatisfy { $0.pending != nil || $0.rotatedAt != nil },
                      "the unproven key was dropped at some point: \(store.saves)")
        XCTAssertEqual(store.load()?.deviceID, pending.deviceID, "asked the Mac, got the same key, proved it")
        XCTAssertNotNil(store.load()?.rotatedAt)
        XCTAssertEqual(mac.with { $0.rekeys }, 1)
        assertNotLockedOut(mac)
    }

    /// The Mac no longer knows the key it issued (its registry was rewritten
    /// by an older Huske.app). The old key still works; the Mac's next answer
    /// replaces the dead one.
    func testAKeyTheMacForgotIsReplacedByItsNextAnswer() async {
        let mac = KeyedMac()
        let (stored, pending) = midRotation(mac)
        mac.with { $0.devices[0].successor = nil }
        let sync = makeManager(mac, stored: stored)

        await sync.syncNow(.manual)?.value

        let now = store.load()
        XCTAssertNotNil(now?.rotatedAt)
        XCTAssertNotEqual(now?.deviceID, pending.deviceID)
        XCTAssertNotEqual(now?.deviceID, stored.deviceID)
        XCTAssertTrue(now.map(mac.accepts) ?? false)
        XCTAssertFalse(sync.isRejected)
    }

    /// Both keys refused, twice over for the new one: this iPhone really was
    /// removed on the Mac. Nothing stored is thrown away for it.
    func testBothKeysRefusedIsBeingUnpaired() async {
        let mac = KeyedMac()
        let (stored, _) = midRotation(mac)
        mac.with { $0.devices = [] }
        let sync = makeManager(mac, stored: stored)

        await sync.syncNow(.manual)?.value

        XCTAssertTrue(sync.isRejected)
        XCTAssertEqual(store.load(), stored)
        XCTAssertEqual(mac.with { $0.connects }, 3)
    }

    /// No way to the Mac says nothing about keys: no fallback, nothing
    /// dropped, and words that say what to do.
    func testANetworkFailureMidRotationTouchesNothing() async {
        let mac = KeyedMac("Studio")
        let (stored, _) = midRotation(mac)
        mac.with { $0.unreachable = SyncError.network(.refused) }
        let sync = makeManager(mac, stored: stored)

        await sync.syncNow(.manual)?.value

        XCTAssertEqual(store.load(), stored)
        XCTAssertFalse(sync.isRejected)
        XCTAssertEqual(sync.lastError, "Studio isn't accepting connections — open Huske on your Mac.")
        assertNotLockedOut(mac)
    }

    /// A key that could not be stored is never used: using it would make the
    /// Mac retire the only key this iPhone still has on disk.
    func testAKeyTheKeychainRefusedIsNeverUsed() async {
        let mac = KeyedMac()
        let old = PairedMac(invite: mac.makeInvite())
        let sync = makeManager(mac, stored: old)
        store.failsSaves = true

        await sync.syncNow(.manual)?.value

        XCTAssertEqual(store.load(), old)
        XCTAssertTrue(mac.accepts(old), "the Mac retired a key the phone still depends on")
        XCTAssertEqual(mac.with { $0.hellos }.map(\.deviceID), [old.deviceID], "the unstored key was used")
        XCTAssertEqual(sync.pairedMac, old)
        assertNotLockedOut(mac)

        // The Keychain works again: the same key is issued and adopted.
        store.failsSaves = false
        await sync.syncNow(.manual)?.value
        XCTAssertNotNil(store.load()?.rotatedAt)
    }

    /// "Not now" from the Mac is not an error to show; the next pass asks again.
    func testAMacWithNoKeyToGiveIsAskedAgainLater() async {
        let mac = KeyedMac()
        let old = PairedMac(invite: mac.makeInvite())
        mac.with { $0.rekeyUnavailable = true }
        addRecording("a")
        let sync = makeManager(mac, stored: old)

        await sync.syncNow(.manual)?.value

        XCTAssertEqual(store.load(), old)
        XCTAssertNil(sync.lastError)
        XCTAssertEqual(mac.with { $0.uploaded }.map(\.recordingID), ["a"], "the pass went on with the key it had")

        mac.with { $0.rekeyUnavailable = false }
        await sync.syncNow(.manual)?.value
        XCTAssertNotNil(store.load()?.rotatedAt)
    }

    // MARK: rotation needs no recording

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// The Mac quit between issuing the key and seeing it used (found
    /// end to end: the pass that would have proven it ended with the Mac).
    /// The next time the Mac is seen the key is proven, with nothing to send:
    /// the link's key must not keep working until the next recording.
    func testAnUnprovenKeyIsProvenWhenTheMacNextAppears() async {
        let mac = KeyedMac()
        let (stored, pending) = midRotation(mac)
        defaults.set(mac.with { $0.capabilities }, forKey: "sync.macCapabilities")
        let presence = FakePresence(reachable: false)
        let sync = makeManager(mac, stored: stored, presence: presence)
        await settle(sync)
        XCTAssertEqual(mac.with { $0.connects }, 0, "nothing to connect to yet")

        presence.set(true)

        let proven = await waitUntil { self.store.load()?.rotatedAt != nil && !sync.isRunning }
        XCTAssertTrue(proven, "seeing the Mac is reason enough to connect")
        XCTAssertEqual(store.load()?.deviceID, pending.deviceID)
        XCTAssertFalse(mac.accepts(stored), "the link's key still works")
        XCTAssertEqual(mac.with { $0.rekeys }, 0, "proven, not asked for again")
    }

    /// A pairing an older build of the app made (nothing known yet about
    /// what the Mac takes) is rotated the first time the Mac is seen — and
    /// once that is done, seeing the Mac with nothing to send connects no more.
    func testAPairingFromAnOlderBuildIsRotatedWhenTheMacAppears() async {
        let mac = KeyedMac()
        let old = PairedMac(invite: mac.makeInvite())
        let presence = FakePresence(reachable: false)
        let sync = makeManager(mac, stored: old, presence: presence)
        await settle(sync)

        presence.set(true)

        let rotated = await waitUntil { self.store.load()?.rotatedAt != nil && !sync.isRunning }
        XCTAssertTrue(rotated)
        XCTAssertFalse(mac.accepts(old))
        XCTAssertEqual(mac.with { $0.hellos }.last?.installID, installID, "the kept pairing says which install it is")
        let connects = mac.with { $0.connects }

        presence.set(false)
        presence.set(true)
        try? await Task.sleep(for: .milliseconds(200))
        await settle(sync)
        XCTAssertEqual(mac.with { $0.connects }, connects, "nothing owed any more")
    }

    /// A Mac from before rotation is asked once (the pass that learns what it
    /// takes) and never again just for this: no connection each time it is
    /// seen with nothing to send.
    func testAMacThatDoesNotRotateIsNotContactedForIt() async {
        let mac = KeyedMac()
        mac.with { $0.capabilities = [] }
        let old = PairedMac(invite: mac.makeInvite())
        let presence = FakePresence(reachable: false)
        let sync = makeManager(mac, stored: old, presence: presence)
        await settle(sync)

        presence.set(true)
        _ = await waitUntil { mac.with { $0.connects } == 1 && !sync.isRunning }
        presence.set(false)
        presence.set(true)
        sync.scenePhaseChanged(isActive: true)
        try? await Task.sleep(for: .milliseconds(200))
        await settle(sync)

        XCTAssertEqual(mac.with { $0.connects }, 1, "once to learn what it takes, then never for this")
        XCTAssertEqual(mac.with { $0.rekeys }, 0)
        XCTAssertEqual(store.load(), old)
    }

    /// An iPhone build that does not rotate (or a pairing already rotated)
    /// owes nothing: seeing the Mac with nothing to send does not connect.
    func testNothingOwedMeansNoConnection() async {
        let mac = KeyedMac()
        let presence = FakePresence(reachable: false)
        let old = PairedMac(invite: mac.makeInvite())
        let sync = makeManager(mac, stored: old, announces: [], presence: presence)
        await settle(sync)

        presence.set(true)
        try? await Task.sleep(for: .milliseconds(200))
        await settle(sync)

        XCTAssertEqual(mac.with { $0.connects }, 0)
    }

    /// The Mac refused this iPhone: only pairing again helps, so seeing the
    /// Mac is no reason to knock again for a rotation.
    func testARefusedPairingDoesNotKnockToRotate() async {
        let mac = KeyedMac()
        let old = PairedMac(invite: mac.makeInvite())
        mac.with { $0.devices = [] }
        let presence = FakePresence(reachable: true)
        let sync = makeManager(mac, stored: old, presence: presence)
        await sync.syncNow(.manual)?.value
        XCTAssertTrue(sync.isRejected)
        let connects = mac.with { $0.connects }

        presence.set(false)
        presence.set(true)
        try? await Task.sleep(for: .milliseconds(200))
        await settle(sync)

        XCTAssertEqual(mac.with { $0.connects }, connects)
    }

    // MARK: forgetting the Mac

    /// "Forget this Mac" with the Mac nearby: it stops listing this iPhone.
    func testForgettingTellsTheMac() async {
        let mac = KeyedMac()
        let sync = makeManager(mac)
        _ = await sync.pair(with: mac.makeInvite())
        await settle(sync)
        XCTAssertEqual(mac.devices.count, 1)

        sync.forgetMac()
        XCTAssertNil(store.load(), "forgotten at once, whatever the Mac says")
        XCTAssertFalse(sync.isPaired)
        await sync.goodbye?.value

        XCTAssertEqual(mac.devices, [], "the Mac still lists the iPhone")
        XCTAssertEqual(mac.with { $0.unpairs }, 1)
        XCTAssertTrue(journalText().contains("the mac removed this iphone too"), journalText())
        // The goodbye did not say "this is the pairing I keep".
        XCTAssertNil(mac.with { $0.hellos }.last?.installID)
    }

    /// The Mac is not there: the iPhone forgets anyway, and the Mac keeps its
    /// entry (and its Remove button).
    func testForgettingWithTheMacAwayStillForgets() async {
        let mac = KeyedMac()
        let sync = makeManager(mac)
        _ = await sync.pair(with: mac.makeInvite())
        await settle(sync)
        mac.with { $0.unreachable = SyncError.network(.unreachable("No route to host, errno 65")) }

        sync.forgetMac()
        await sync.goodbye?.value

        XCTAssertNil(store.load())
        XCTAssertFalse(sync.isPaired)
        XCTAssertEqual(mac.devices.count, 1)
        XCTAssertEqual(mac.with { $0.unpairs }, 0)
        XCTAssertTrue(journalText().contains("couldn't tell the mac"), journalText())
        XCTAssertNil(sync.lastError, "forgetting is not an error")
    }

    /// With a browse that does not see the Mac, nothing is even attempted.
    func testForgettingDoesNotGoLookingForAMacThatIsNotVisible() async {
        let mac = KeyedMac()
        let presence = FakePresence(reachable: true)
        let sync = makeManager(mac, presence: presence)
        _ = await sync.pair(with: mac.makeInvite())
        await settle(sync)
        presence.set(false)
        try? await Task.sleep(for: .milliseconds(100))
        let connects = mac.with { $0.connects }

        sync.forgetMac()
        await sync.goodbye?.value

        XCTAssertNil(store.load())
        XCTAssertEqual(mac.with { $0.connects }, connects)
        XCTAssertEqual(mac.devices.count, 1)
        XCTAssertTrue(journalText().contains("isn't nearby"), journalText())
    }

    /// Huske.app from before `unpair`: it is not sent a message it would hang
    /// up on, and not even connected to.
    func testAnOlderMacIsNotToldAndNothingBreaks() async {
        let mac = KeyedMac()
        mac.with { $0.capabilities = [] }
        let sync = makeManager(mac)
        _ = await sync.pair(with: mac.makeInvite())
        await settle(sync)
        let connects = mac.with { $0.connects }

        sync.forgetMac()
        await sync.goodbye?.value

        XCTAssertNil(store.load())
        XCTAssertEqual(mac.with { $0.connects }, connects, "connected to say something it cannot hear")
        XCTAssertEqual(mac.devices.count, 1, "its pane keeps the manual Remove")
    }

    /// Forgetting half-way through a rotation: whichever key the Mac takes
    /// carries the goodbye, and both are gone there afterwards.
    func testForgettingMidRotationReachesTheMacWithEitherKey() async {
        for promotedOnMac in [false, true] {
            let mac = KeyedMac()
            let (stored, pending) = midRotation(mac)
            if promotedOnMac {
                mac.with {
                    $0.devices[0] = KeyedMac.Device(deviceID: pending.deviceID, key: pending.key)
                }
            }
            defaults.set(SyncConstants.capabilities, forKey: "sync.macCapabilities")
            let sync = makeManager(mac, stored: stored)

            sync.forgetMac()
            await sync.goodbye?.value

            XCTAssertEqual(mac.devices, [], "promoted on the Mac: \(promotedOnMac)")
            XCTAssertFalse(mac.accepts(deviceID: pending.deviceID, key: pending.key))
        }
    }

    /// A code the Mac refuses is discarded without a goodbye: there is no
    /// entry to remove, and no key to say it with.
    func testARefusedFirstCodeSaysNoGoodbye() async {
        let mac = KeyedMac()
        let stranger = PairingInvite.mint(macID: mac.macID, macName: mac.name)
        let sync = makeManager(mac)

        let result = await sync.pair(with: stranger)

        XCTAssertEqual(result, .failed(SyncManager.codeRejectedMessage))
        XCTAssertNil(sync.goodbye)
        XCTAssertEqual(mac.with { $0.unpairs }, 0)
    }

    // MARK: pairing again

    /// A first pairing says which install this is from its first `hello`: the
    /// iPhone holds no other pairing that could be lost.
    func testAFirstPairingAnnouncesTheInstall() async {
        let mac = KeyedMac()
        let sync = makeManager(mac)

        _ = await sync.pair(with: mac.makeInvite())
        await settle(sync)

        XCTAssertEqual(mac.with { $0.hellos }.map(\.installID), [installID, installID])
        XCTAssertEqual(mac.devices.first?.installID, installID)
    }

    /// Pairing again with the same Mac leaves one entry there, not two.
    func testPairingAgainReplacesTheEarlierEntryOnTheMac() async {
        let mac = KeyedMac()
        let sync = makeManager(mac)
        _ = await sync.pair(with: mac.makeInvite())
        await settle(sync)
        let first = store.load()

        let result = await sync.pair(with: mac.makeInvite())
        await settle(sync)

        XCTAssertEqual(result, .paired)
        XCTAssertEqual(mac.devices.count, 1, "the earlier pairing is still listed on the Mac")
        XCTAssertEqual(mac.devices.first?.deviceID, store.load()?.deviceID)
        XCTAssertFalse(first.map(mac.accepts) ?? true, "the earlier pairing's key still works")
        assertNotLockedOut(mac)
    }

    /// Trying a new code next to a pairing that works does not say which
    /// install this is: the Mac would drop the working pairing's entry before
    /// the iPhone has decided to keep the new one.
    func testTryingANewCodeDoesNotAnnounceTheInstall() async {
        let mac = KeyedMac()
        let sync = makeManager(mac)
        _ = await sync.pair(with: mac.makeInvite())
        await settle(sync)
        let hellosBefore = mac.with { $0.hellos.count }
        let second = mac.makeInvite()

        _ = await sync.pair(with: second)
        await settle(sync)

        let hellos = mac.with { Array($0.hellos.dropFirst(hellosBefore)) }
        XCTAssertEqual(hellos.first?.deviceID, second.deviceID)
        XCTAssertNil(hellos.first?.installID, "the try announced the install")
        XCTAssertEqual(hellos.last?.installID, installID, "the kept pairing never did")
    }

    /// The Mac accepted the new code but its answer was lost: the iPhone
    /// keeps the pairing it had, and that pairing must still work.
    func testANewCodeWhoseAnswerIsLostLeavesTheWorkingPairingAlone() async {
        let mac = KeyedMac()
        let sync = makeManager(mac)
        _ = await sync.pair(with: mac.makeInvite())
        await settle(sync)
        let working = store.load()
        let second = mac.makeInvite()
        mac.with { $0.loseWelcomeFor = second.deviceID }

        let result = await sync.pair(with: second)
        await settle(sync)

        guard case .failed = result else { return XCTFail("expected a failure, got \(result)") }
        XCTAssertEqual(store.load(), working, "the working pairing was replaced by one that never answered")
        XCTAssertTrue(working.map(mac.accepts) ?? false, "the Mac dropped the pairing the iPhone still uses")
        await sync.syncNow(.manual)?.value
        XCTAssertFalse(sync.isRejected)
    }

    func testTheInstallIDIsStableAndPerKeychainItem() throws {
        try Self.skipWithoutKeychain()
        let service = "cloud.tiagomoraes.huske.ios.tests.install-\(UUID().uuidString)"
        defer { InstallIdentity.remove(service: service) }
        let first = InstallIdentity.load(service: service)
        XCTAssertNotNil(first)
        XCTAssertTrue(first.map(SyncConstants.isValidID) ?? false)
        XCTAssertEqual(InstallIdentity.load(service: service), first, "minted again instead of read back")
        let other = "\(service)-other"
        defer { InstallIdentity.remove(service: other) }
        XCTAssertNotEqual(InstallIdentity.load(service: other), first)
    }

    /// CI builds the test host with `CODE_SIGNING_ALLOWED=NO`, and an unsigned
    /// app has no Keychain (`errSecMissingEntitlement`). Locally signed runs
    /// and real devices do have one.
    private static func skipWithoutKeychain() throws {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "cloud.tiagomoraes.huske.ios.tests.keychain-probe-\(UUID().uuidString)",
            kSecAttrAccount as String: "probe",
            kSecValueData as String: Data([1]),
        ]
        let status = SecItemAdd(probe as CFDictionary, nil)
        SecItemDelete(probe as CFDictionary)
        if status == errSecMissingEntitlement {
            throw XCTSkip("No Keychain in this unsigned test host (CI builds with CODE_SIGNING_ALLOWED=NO)")
        }
    }

    // MARK: the network or the file

    func testNetworkFailuresHaveWordsOfTheirOwn() {
        XCTAssertEqual(
            SyncMessages.text(for: SyncError.network(.refused), macName: "Studio"),
            "Studio isn't accepting connections — open Huske on your Mac.")
        XCTAssertEqual(
            SyncMessages.connectText(for: SyncError.network(.refused), macName: "Studio"),
            "Studio isn't accepting connections — open Huske on your Mac.")
        for failure in [NetworkFailure.unreachable("No route to host, errno 65"),
                        .nameNotResolved("DNS error -65554"), .other("Protocol error, errno 100")] {
            let text = SyncMessages.text(for: SyncError.network(failure), macName: "Studio") ?? ""
            XCTAssertEqual(text, "Couldn't reach Studio. Huske will try again.")
            XCTAssertFalse(text.contains("errno"), "a POSIX code reached the user: \(text)")
        }
        // The network is the connection's problem; a file is the recording's.
        XCTAssertFalse(SyncMessages.isPerRecording(SyncError.network(.refused)))
        XCTAssertTrue(SyncMessages.isWorthRetrying(SyncError.network(.refused)))
        XCTAssertFalse(SyncMessages.isRejection(SyncError.network(.refused)))
        XCTAssertTrue(SyncMessages.isPerRecording(SyncError.io("cannot read a.m4a")))
        XCTAssertEqual(
            SyncMessages.text(for: SyncError.io("cannot read a.m4a"), macName: "Studio"),
            "The audio for a recording couldn't be read on this iPhone.")
    }

    /// A file that exists but cannot be read used to be taken for a network
    /// failure (both were `.io`), ending the pass for every recording behind
    /// it. It is that recording's problem only.
    func testAnUnreadableRecordingFailsAloneAndTheRestGoOut() async {
        let mac = KeyedMac()
        let stored = PairedMac(invite: mac.makeInvite())
        mac.with { $0.uploadErrors["bad"] = SyncError.io("read failed: Input/output error") }
        addRecording("bad", minutesAgo: 10)
        addRecording("fine", minutesAgo: 5)
        let sync = makeManager(mac, stored: stored)

        await sync.syncNow(.manual)?.value

        XCTAssertEqual(library.recording(id: "bad")?.sync.failure,
                       "The audio for this recording couldn't be read on this iPhone.")
        XCTAssertEqual(mac.with { $0.uploaded }.map(\.recordingID), ["fine"])
        XCTAssertNil(sync.lastError, "nothing is wrong with the connection")
    }

    /// The mirror image: a network failure mid-upload marks nothing failed.
    func testANetworkFailureMidUploadFailsNoRecording() async {
        let mac = KeyedMac("Studio")
        let stored = PairedMac(invite: mac.makeInvite())
        mac.with { $0.uploadErrors["a"] = SyncError.network(.unreachable("Network is down, errno 50")) }
        addRecording("a")
        let sync = makeManager(mac, stored: stored)

        await sync.syncNow(.manual)?.value

        XCTAssertNil(library.recording(id: "a")?.sync.failure)
        XCTAssertEqual(sync.lastError, "Couldn't reach Studio. Huske will try again.")
    }
}
