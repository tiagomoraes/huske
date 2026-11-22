// Pairing security after the first connection (sync-protocol.md § Key
// rotation, § Unpairing, § Pairing again):
//
// - `rekey`: the key a QR code or a copied link carried is replaced by one
//   that never left the two devices, and stops working once the new one is
//   used — without ever leaving a phone with no key that works;
// - `unpair`: "Forget this Mac" also removes the iPhone on the Mac;
// - `hello.installID`: a phone that pairs again replaces its earlier entry.
//
// All three are additive: each test of a new message has a sibling where one
// side does not announce it, and the pair behaves exactly as before.

import CryptoKit
import Network
import XCTest

@_spi(Testing) @testable import HuskeSync

private func rawFrame(_ json: String) -> Data {
    let header = Data(json.utf8)
    var length = UInt32(header.count).bigEndian
    return withUnsafeBytes(of: &length) { Data($0) } + header
}

private func sendRaw(_ json: String, on framed: FramedConnection) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        framed.connection.send(
            content: rawFrame(json),
            completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
    }
}

extension SyncHarness {
    /// Whether a `hello` with this credential is answered (`true`), or the
    /// Mac turns it away at the handshake (`false`).
    func accepts(_ pairing: PairedMac, file: StaticString = #filePath, line: UInt = #line) async throws -> Bool {
        let client = try await self.client(pairing)
        let (_, result) = await outcome { () -> Void in
            let session = try await client.connect(timeout: 5)
            _ = try await session.status(["a"])
            await session.close()
        }
        switch result {
        case .success: return true
        case .failure(SyncError.handshakeFailed): return false
        case .failure(let error):
            XCTFail("neither accepted nor refused: \(error)", file: file, line: line)
            return false
        }
    }

    /// What the phone does once `rekey` answered: store the credential as
    /// pending, connect with it, and keep it once the Mac said `welcome`.
    func confirm(_ pairing: PairedMac, _ credential: DeviceCredential) async throws -> PairedMac {
        var stored = pairing
        stored.pending = credential
        let session = try await client(try XCTUnwrap(stored.usingPending)).connect(timeout: 5)
        await session.close()
        return stored.promotingPending()
    }

    /// Pair, rotate, confirm: a phone as it is a second after pairing.
    func rotatedPhone(installID: String? = nil) async throws -> PairedMac {
        let pairing = PairedMac(invite: server.makeInvite())
        let session = try await client(pairing, installID: installID).connect(timeout: 5)
        let credential = try await session.rekey()
        await session.close()
        var stored = pairing
        stored.pending = credential
        let again = try await client(try XCTUnwrap(stored.usingPending), installID: installID).connect(timeout: 5)
        await again.close()
        return stored.promotingPending()
    }
}

// MARK: - rotation

final class KeyRotationTests: XCTestCase {
    private var mac: SyncHarness!

    override func setUp() async throws {
        mac = try await SyncHarness()
    }

    override func tearDown() async throws {
        mac?.tearDown()
    }

    /// The whole dance, and what it is for: after it, the key that was in the
    /// QR code opens nothing.
    func testRotationReplacesTheLinkKeyAndRetiresIt() async throws {
        let invite = mac.server.makeInvite()
        let link = PairedMac(invite: invite)
        let epoch = mac.server.listenerEpoch

        let session = try await mac.client(link).connect(timeout: 5)
        XCTAssertTrue(session.supports(SyncCapability.rekey))
        let credential = try await session.rekey()
        await session.close()
        XCTAssertEqual(credential.key.count, 32)
        XCTAssertNotEqual(credential.key, invite.key)
        XCTAssertNotEqual(credential.deviceID, invite.deviceID)
        let before = try XCTUnwrap(mac.registry.device(id: invite.deviceID))
        XCTAssertEqual(before.successor?.key, credential.key, "the Mac remembers what it issued")
        XCTAssertNil(before.rotatedAt, "nothing is retired until the new key is used")

        let rotated = try await mac.confirm(link, credential)
        XCTAssertEqual(rotated.deviceID, credential.deviceID)
        XCTAssertEqual(rotated.key, credential.key)
        XCTAssertNil(rotated.pending)
        XCTAssertNotNil(rotated.rotatedAt)
        XCTAssertFalse(rotated.needsRekey)

        // One device on the Mac, the same one, under its new credential.
        let devices = mac.registry.devices()
        XCTAssertEqual(devices.count, 1)
        let after = try XCTUnwrap(devices.first)
        XCTAssertEqual(after.deviceID, credential.deviceID)
        XCTAssertEqual(after.key, credential.key)
        XCTAssertNil(after.successor)
        XCTAssertNotNil(after.rotatedAt)
        XCTAssertEqual(after.pairedAt, before.pairedAt, "still the same pairing")
        XCTAssertEqual(after.name, "iPhone de Teste")
        XCTAssertNil(mac.registry.device(id: invite.deviceID))

        // The point of it all.
        let linkStillWorks = try await mac.accepts(link)
        XCTAssertFalse(linkStillWorks, "the pairing link's key still opens the Mac after rotation")
        let newWorks = try await mac.accepts(rotated)
        XCTAssertTrue(newWorks)
        XCTAssertEqual(mac.server.listenerEpoch, epoch, "rotating a key replaced the listener (the advert flapped)")
    }

    /// What the Mac's pairing sheet relies on: `devicePaired` names the
    /// identity of the code on screen, once — before the phone swaps that
    /// identity for a new one, which is a rotation and not a second pairing.
    func testRotationIsNotASecondPairingEvent() async throws {
        let invite = mac.server.makeInvite()
        let link = PairedMac(invite: invite)
        let session = try await mac.client(link).connect(timeout: 5)
        let credential = try await session.rekey()
        await session.close()
        let rotated = try await mac.confirm(link, credential)

        let paired = mac.events.values.compactMap { event -> String? in
            if case .devicePaired(let device) = event { return device.deviceID } else { return nil }
        }
        XCTAssertEqual(paired, [invite.deviceID])
        let connected = mac.events.values.compactMap { event -> String? in
            if case .deviceConnected(let device) = event { return device.deviceID } else { return nil }
        }
        XCTAssertEqual(connected, [invite.deviceID, rotated.deviceID])
        XCTAssertGreaterThan(mac.delegate.devicesChanged, 1, "the pane was not told the entry changed")
    }

    /// Between `rekeyed` and the first use of the new key both work: whatever
    /// happens to the phone in that window, it still has a key the Mac takes.
    func testBothKeysWorkUntilTheNewOneIsUsed() async throws {
        let link = PairedMac(invite: mac.server.makeInvite())
        let session = try await mac.client(link).connect(timeout: 5)
        let credential = try await session.rekey()
        await session.close()

        for _ in 0..<3 {
            let oldWorks = try await mac.accepts(link)
            XCTAssertTrue(oldWorks, "the old key stopped working before the new one was used")
        }
        XCTAssertNotNil(mac.registry.device(id: link.deviceID)?.successor)
        var stored = link
        stored.pending = credential
        let newWorks = try await mac.accepts(try XCTUnwrap(stored.usingPending))
        XCTAssertTrue(newWorks)
    }

    /// The reply never arrives (or the phone quits before storing it). The
    /// phone still has its old key, asks again, and gets the same credential:
    /// retries do not eat the spare slots.
    func testALostReplyIsRepeatedNotReminted() async throws {
        let link = PairedMac(invite: mac.server.makeInvite())
        // Ask by hand and hang up without reading the answer.
        let raw = try await mac.rawConnection(link)
        try await raw.send(
            .hello(
                HelloMessage(
                    protocolVersion: 1, deviceID: link.deviceID, deviceName: "p", deviceModel: "m",
                    appVersion: "1", capabilities: SyncConstants.capabilities)))
        guard case .welcome? = try await raw.receive(timeout: 5) else { return XCTFail("no welcome") }
        try await raw.send(.rekey(RekeyExchange.Request().message))
        let registry = mac.registry
        let issued = await eventually(3) { registry.device(id: link.deviceID)?.successor != nil }
        XCTAssertTrue(issued)
        raw.cancel()
        let first = try XCTUnwrap(mac.registry.device(id: link.deviceID)?.successor)
        let spares = mac.server.spareSlotCount

        let session = try await mac.client(link).connect(timeout: 5)
        let second = try await session.rekey()
        let third = try await session.rekey()
        await session.close()
        XCTAssertEqual(second.deviceID, first.deviceID)
        XCTAssertEqual(second.key, first.key)
        XCTAssertEqual(third.key, first.key)
        XCTAssertEqual(mac.server.spareSlotCount, spares, "asking again took another spare slot")

        let rotated = try await mac.confirm(link, second)
        let works = try await mac.accepts(rotated)
        XCTAssertTrue(works)
    }

    /// The Mac quits between issuing the key and seeing it used. The pending
    /// credential is in the registry, so the next listener carries it.
    func testAPendingKeySurvivesARelaunchOfTheMac() async throws {
        let link = PairedMac(invite: mac.server.makeInvite())
        let session = try await mac.client(link).connect(timeout: 5)
        let credential = try await session.rekey()
        await session.close()
        mac.server.stop()

        let registry = DeviceRegistry(fileURL: mac.dir.appendingPathComponent("devices.json"))
        XCTAssertEqual(registry.device(id: link.deviceID)?.successor?.key, credential.key)
        let relaunched = SyncServer(
            registry: registry, stagingDirectory: mac.dir.appendingPathComponent("staging"),
            macName: "Test Mac", serverVersion: "test")
        relaunched.delegate = mac.delegate
        relaunched.advertisesService = false
        try relaunched.start()
        defer { relaunched.stop() }
        let ready = await relaunched.waitUntilReady()
        let port = try XCTUnwrap(ready)

        // The old key first: nothing was promoted by the relaunch.
        let old = try await mac.client(link, port: port).connect(timeout: 5)
        await old.close()
        var stored = link
        stored.pending = credential
        let new = try await mac.client(try XCTUnwrap(stored.usingPending), port: port).connect(timeout: 5)
        await new.close()
        XCTAssertEqual(registry.devices().map(\.deviceID), [credential.deviceID])
        let retiredClient = try await mac.client(link, port: port)
        let (_, result) = await outcome { try await retiredClient.connect(timeout: 5) }
        guard case .handshakeFailed? = result.syncError else {
            return XCTFail("the old key survived the rotation: \(result)")
        }
    }

    /// The Mac saw the new key used but its `welcome` never reached the phone
    /// (the Mac quit, the link dropped). The phone still holds the pending
    /// credential, tries it first next time, and is let in.
    func testAPhoneThatMissedTheWelcomeGetsInWithThePendingKey() async throws {
        let link = PairedMac(invite: mac.server.makeInvite())
        let session = try await mac.client(link).connect(timeout: 5)
        let credential = try await session.rekey()
        await session.close()
        var stored = link
        stored.pending = credential
        let pending = try XCTUnwrap(stored.usingPending)

        // Handshake and hello with the new key; the answer is never read.
        let raw = try await mac.rawConnection(pending)
        try await raw.send(
            .hello(
                HelloMessage(
                    protocolVersion: 1, deviceID: pending.deviceID, deviceName: "p", deviceModel: "m",
                    appVersion: "1", capabilities: SyncConstants.capabilities)))
        let registry = mac.registry
        let promoted = await eventually(3) { registry.device(id: pending.deviceID) != nil }
        XCTAssertTrue(promoted)
        raw.cancel()

        // The phone's stored state is unchanged: old key + pending.
        let oldWorks = try await mac.accepts(link)
        XCTAssertFalse(oldWorks, "retired on the Mac")
        let pendingWorks = try await mac.accepts(pending)
        XCTAssertTrue(pendingWorks, "the phone was locked out: neither of its keys works")
    }

    /// A pending key the Mac no longer knows (its registry was restored, or
    /// rewritten by an older Huske.app) is refused — and the old one still
    /// works, so the phone falls back and asks again.
    func testAPendingKeyTheMacForgotIsRefusedAndTheOldOneStillWorks() async throws {
        let link = PairedMac(invite: mac.server.makeInvite())
        let session = try await mac.client(link).connect(timeout: 5)
        let credential = try await session.rekey()
        await session.close()
        // What an older Huske.app does to the file: it rewrites it without
        // the field it does not know.
        XCTAssertTrue(mac.registry.setSuccessor(nil, forDevice: link.deviceID))

        var stored = link
        stored.pending = credential
        let pendingWorks = try await mac.accepts(try XCTUnwrap(stored.usingPending))
        XCTAssertFalse(pendingWorks)
        let oldWorks = try await mac.accepts(link)
        XCTAssertTrue(oldWorks)

        // Asking again gets a fresh credential that does work.
        let again = try await mac.client(link).connect(timeout: 5)
        let fresh = try await again.rekey()
        await again.close()
        XCTAssertNotEqual(fresh.key, credential.key)
        let rotated = try await mac.confirm(link, fresh)
        let works = try await mac.accepts(rotated)
        XCTAssertTrue(works)
    }

    /// A recorded successor the running listener has no key for cannot be
    /// handed out again: nobody could connect with it.
    func testASuccessorTheListenerDoesNotCarryIsReplaced() async throws {
        let link = try await mac.pairedPhone()
        let orphan = DeviceCredential.mint()
        XCTAssertTrue(mac.registry.setSuccessor(orphan, forDevice: link.deviceID))

        let session = try await mac.client(link).connect(timeout: 5)
        let credential = try await session.rekey()
        await session.close()
        XCTAssertNotEqual(credential.deviceID, orphan.deviceID)
        let rotated = try await mac.confirm(link, credential)
        let works = try await mac.accepts(rotated)
        XCTAssertTrue(works)
    }

    /// A session still open under the old key ends when the new one is used:
    /// whoever holds only the old key is out at once, not at its next connect.
    func testUsingTheNewKeyClosesSessionsOpenUnderTheOldOne() async throws {
        let link = PairedMac(invite: mac.server.makeInvite())
        let session = try await mac.client(link).connect(timeout: 5)
        let credential = try await session.rekey()
        let lingering = try await mac.client(link).connect(timeout: 5)
        _ = try await lingering.status(["a"])
        await session.close()

        _ = try await mac.confirm(link, credential)
        let (_, result) = await outcome { try await lingering.status(["a"]) }
        XCTAssertNotNil(result.syncError, "a session under the retired key kept working: \(result)")
        await lingering.close()
    }

    /// The new identity is bound to its key like any other: a hello that
    /// names the old device over a connection made with the new key is
    /// refused, and promotes nothing.
    func testTheNewIdentityCannotSpeakForTheOldOne() async throws {
        let link = PairedMac(invite: mac.server.makeInvite())
        let session = try await mac.client(link).connect(timeout: 5)
        let credential = try await session.rekey()
        await session.close()
        var stored = link
        stored.pending = credential

        let raw = try await mac.rawConnection(try XCTUnwrap(stored.usingPending))
        defer { raw.cancel() }
        try await raw.send(
            .hello(
                HelloMessage(
                    protocolVersion: 1, deviceID: link.deviceID, deviceName: "p", deviceModel: "m",
                    appVersion: "1")))
        guard case .error(let error)? = try await raw.receive(timeout: 5) else {
            return XCTFail("a mismatched hello was accepted")
        }
        XCTAssertEqual(error.code, "bad_request")
        XCTAssertNotNil(mac.registry.device(id: link.deviceID)?.successor, "promoted by a refused hello")
    }

    /// With no spare slot left the Mac says "not now"; nothing else changes,
    /// and the session carries on.
    func testWithNoSpareSlotTheMacSaysNotNowAndNothingBreaks() async throws {
        let link = try await mac.pairedPhone()
        while mac.server.spareSlotCount > 0 { _ = mac.server.makeInvite() }
        let epoch = mac.server.listenerEpoch

        let session = try await mac.client(link).connect(timeout: 5)
        let (_, result) = await outcome { try await session.rekey() }
        guard case .protocolError(let code, _)? = result.syncError else {
            return XCTFail("expected unavailable, got \(result)")
        }
        XCTAssertEqual(code, "unavailable")
        XCTAssertEqual(mac.server.listenerEpoch, epoch, "a rekey replaced the listener")
        XCTAssertNil(mac.registry.device(id: link.deviceID)?.successor)
        _ = try await session.status(["a"])
        await session.close()
    }

    /// A bad request does not cost a spare slot.
    func testAMalformedRekeyIsRefusedWithoutSpendingASlot() async throws {
        let link = try await mac.pairedPhone()
        let spares = mac.server.spareSlotCount
        let raw = try await mac.rawConnection(link)
        defer { raw.cancel() }
        try await raw.send(
            .hello(
                HelloMessage(
                    protocolVersion: 1, deviceID: link.deviceID, deviceName: "p", deviceModel: "m",
                    appVersion: "1", capabilities: SyncConstants.capabilities)))
        _ = try await raw.receive(timeout: 5)
        try await raw.send(.rekey(RekeyMessage(publicKey: "not-a-key")))
        guard case .error(let error)? = try await raw.receive(timeout: 5) else { return XCTFail("accepted") }
        XCTAssertEqual(error.code, "bad_request")
        XCTAssertEqual(mac.server.spareSlotCount, spares)
        XCTAssertNil(mac.registry.device(id: link.deviceID)?.successor)
    }

    // MARK: mixed versions

    /// An iPhone app that predates rotation: it announces nothing, never
    /// asks, and keeps working with its link key exactly as today.
    func testAnOldPhoneNeverRotatesAndKeepsWorking() async throws {
        let link = PairedMac(invite: mac.server.makeInvite())
        let session = try await mac.client(link, capabilities: []).connect(timeout: 5)
        XCTAssertFalse(session.supports(SyncCapability.rekey))
        let (_, result) = await outcome { try await session.rekey() }
        XCTAssertEqual(
            result.syncError,
            .protocolError(code: "unsupported", message: "pairing.rekey is not announced by both sides"))
        // Refused on the phone: the connection was not touched.
        _ = try await session.status(["a"])
        await session.close()
        XCTAssertNil(mac.registry.device(id: link.deviceID)?.successor)
        for _ in 0..<2 {
            let works = try await mac.accepts(link)
            XCTAssertTrue(works)
        }
    }

    /// A phone that did not announce the feature but sends the message anyway
    /// is told so, and keeps its connection.
    func testARekeyThatWasNotAnnouncedIsRefused() async throws {
        let link = try await mac.pairedPhone()
        let raw = try await mac.rawConnection(link)
        defer { raw.cancel() }
        try await sendRaw(
            #"{"type":"hello","protocolVersion":1,"deviceID":"\#(link.deviceID)","deviceName":"p","deviceModel":"m","appVersion":"1"}"#,
            on: raw)
        _ = try await raw.receive(timeout: 5)
        try await raw.send(.rekey(RekeyExchange.Request().message))
        guard case .error(let error)? = try await raw.receive(timeout: 5) else { return XCTFail("served") }
        XCTAssertEqual(error.code, "bad_request")
        XCTAssertNil(mac.registry.device(id: link.deviceID)?.successor)
        try await raw.send(.status(StatusRequestMessage(recordingIDs: ["a"])))
        guard case .statusReply? = try await raw.receive(timeout: 5) else {
            return XCTFail("the connection did not carry on")
        }
    }

    /// A Huske.app that predates rotation announces nothing. The phone must
    /// not send `rekey` at all: that Mac hangs up on a message type it does
    /// not know.
    func testAnOldMacIsNeverAskedToRotate() async throws {
        mac.server.capabilities = []
        let link = PairedMac(invite: mac.server.makeInvite())
        let session = try await mac.client(link).connect(timeout: 5)
        XCTAssertEqual(session.welcome.capabilities, [])
        XCTAssertFalse(session.supports(SyncCapability.rekey))
        XCTAssertFalse(session.supports(SyncCapability.unpair))
        let (_, rekey) = await outcome { try await session.rekey() }
        guard case .protocolError("unsupported", _)? = rekey.syncError else {
            return XCTFail("expected unsupported, got \(rekey)")
        }
        let (_, unpair) = await outcome { try await session.unpair() }
        guard case .protocolError("unsupported", _)? = unpair.syncError else {
            return XCTFail("expected unsupported, got \(unpair)")
        }
        // Nothing went out: the session is intact and the device still paired.
        _ = try await session.status(["a"])
        await session.close()
        XCTAssertEqual(mac.registry.device(id: link.deviceID)?.isPaired, true)
    }

    // MARK: the pieces

    func testTheNewKeyDoesNotTravelUnderTheOldKeyAlone() throws {
        let oldKey = DeviceCredential.randomKey()
        let credential = DeviceCredential.mint()
        let request = RekeyExchange.Request()
        let reply = try RekeyExchange.seal(credential, for: request.message, oldDeviceID: "old", oldKey: oldKey)
        // Not in the clear, in any encoding the header could carry.
        XCTAssertFalse(reply.sealedKey.contains(Base64URL.encode(credential.key)))
        XCTAssertNotEqual(Base64URL.decode(reply.sealedKey), credential.key)

        let opened = try RekeyExchange.open(reply, for: request, oldDeviceID: "old", oldKey: oldKey)
        XCTAssertEqual(opened.deviceID, credential.deviceID)
        XCTAssertEqual(opened.key, credential.key)

        // Someone who recorded the exchange and holds the old key has the two
        // public keys and the sealed box — and no private key.
        XCTAssertThrowsError(
            try RekeyExchange.open(reply, for: RekeyExchange.Request(), oldDeviceID: "old", oldKey: oldKey))
        // Bound to the pairing it was issued for.
        XCTAssertThrowsError(
            try RekeyExchange.open(reply, for: request, oldDeviceID: "another", oldKey: oldKey))
        XCTAssertThrowsError(
            try RekeyExchange.open(
                reply, for: request, oldDeviceID: "old", oldKey: DeviceCredential.randomKey()))
        var renamed = reply
        renamed.deviceID = "someone-else"
        XCTAssertThrowsError(try RekeyExchange.open(renamed, for: request, oldDeviceID: "old", oldKey: oldKey))
        // A credential that is the old identity again is not a rotation.
        let same = try RekeyExchange.seal(
            DeviceCredential(deviceID: "old", key: credential.key), for: request.message,
            oldDeviceID: "old", oldKey: oldKey)
        XCTAssertThrowsError(try RekeyExchange.open(same, for: request, oldDeviceID: "old", oldKey: oldKey))
    }

    func testRandomKeysAre32FreshBytes() {
        let keys = (0..<16).map { _ in DeviceCredential.randomKey() }
        XCTAssertTrue(keys.allSatisfy { $0.count == 32 })
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertFalse(keys.contains(Data(count: 32)))
    }

    /// What the phone keeps in its Keychain, step by step.
    func testThePhonesPairingMovesThroughPendingToRotated() {
        let invite = PairingInvite.mint(macID: "MAC", macName: "Mac")
        var pairing = PairedMac(invite: invite, pairedAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(pairing.needsRekey)
        XCTAssertNil(pairing.usingPending)
        XCTAssertEqual(pairing.promotingPending(), pairing, "nothing pending: nothing to promote")

        let credential = DeviceCredential.mint()
        pairing.pending = credential
        XCTAssertFalse(pairing.needsRekey, "one is on its way")
        XCTAssertEqual(pairing.key, invite.key, "the old key stays the pairing's until the new one is proven")
        XCTAssertEqual(pairing.usingPending?.deviceID, credential.deviceID)
        XCTAssertEqual(pairing.usingPending?.key, credential.key)
        XCTAssertEqual(pairing.usingPending?.macID, "MAC")

        let now = Date(timeIntervalSince1970: 2_000)
        let rotated = pairing.promotingPending(now: now)
        XCTAssertEqual(rotated.deviceID, credential.deviceID)
        XCTAssertEqual(rotated.key, credential.key)
        XCTAssertNil(rotated.pending)
        XCTAssertEqual(rotated.rotatedAt, now)
        XCTAssertEqual(rotated.pairedAt, pairing.pairedAt)
        XCTAssertFalse(rotated.needsRekey)
    }

    /// The Keychain item written by today's app (no `pending`, no
    /// `rotatedAt`) still loads, and today's app still reads what this one
    /// writes — before, during and after a rotation.
    func testStoredPairingsReadAcrossAppVersions() throws {
        struct OldPairedMac: Codable, Equatable {
            let macID: String
            var macName: String
            let deviceID: String
            let key: Data
            let pairedAt: Date
        }
        let old = OldPairedMac(
            macID: "MAC", macName: "Mac", deviceID: "D0", key: Data(repeating: 1, count: 32),
            pairedAt: Date(timeIntervalSince1970: 1_000))
        var pairing = try JSONDecoder().decode(PairedMac.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(pairing.deviceID, "D0")
        XCTAssertNil(pairing.pending)
        XCTAssertTrue(pairing.needsRekey, "a pairing made before rotation existed is rotated at first contact")

        // Mid-rotation, an older app sees the old credential: still valid.
        pairing.pending = DeviceCredential(deviceID: "D1", key: Data(repeating: 2, count: 32))
        let during = try JSONDecoder().decode(OldPairedMac.self, from: JSONEncoder().encode(pairing))
        XCTAssertEqual(during.deviceID, "D0")
        XCTAssertEqual(during.key, Data(repeating: 1, count: 32))

        // After it, an older app sees the new one as an ordinary pairing.
        let rotated = pairing.promotingPending(now: Date(timeIntervalSince1970: 2_000))
        let after = try JSONDecoder().decode(OldPairedMac.self, from: JSONEncoder().encode(rotated))
        XCTAssertEqual(after.deviceID, "D1")
        XCTAssertEqual(after.key, Data(repeating: 2, count: 32))
        let reread = try JSONDecoder().decode(PairedMac.self, from: JSONEncoder().encode(rotated))
        XCTAssertEqual(reread, rotated)
    }

    /// The Mac's registry file the same way: today's Huske.app reads a file
    /// this one wrote (it ignores the new keys), and this one reads today's.
    func testTheRegistryFileReadsAcrossAppVersions() async throws {
        struct OldDevice: Codable {
            let deviceID: String
            let key: Data
            var name: String?
            var model: String?
            let createdAt: Date
            var pairedAt: Date?
            var lastSeenAt: Date?
            var expiresAt: Date?
        }
        struct OldStored: Codable {
            var macID: String
            var devices: [OldDevice]
        }
        let file = mac.dir.appendingPathComponent("devices.json")
        let link = PairedMac(invite: mac.server.makeInvite())
        let session = try await mac.client(link, installID: "INSTALL-1").connect(timeout: 5)
        let credential = try await session.rekey()
        await session.close()

        // Mid-rotation: an older app knows the device by its old credential.
        var old = try WireJSON.decoder().decode(OldStored.self, from: Data(contentsOf: file))
        XCTAssertEqual(old.devices.map(\.deviceID), [link.deviceID])
        XCTAssertEqual(old.devices.first?.key, link.key)

        _ = try await mac.confirm(link, credential)
        // After it: one ordinary device under the new credential.
        old = try WireJSON.decoder().decode(OldStored.self, from: Data(contentsOf: file))
        XCTAssertEqual(old.devices.map(\.deviceID), [credential.deviceID])
        XCTAssertEqual(old.devices.first?.key, credential.key)
        XCTAssertNotNil(old.devices.first?.pairedAt)

        // And a file an older app wrote loads here, with nothing to rotate to.
        let legacy = mac.dir.appendingPathComponent("legacy.json")
        try WireJSON.encoder().encode(old).write(to: legacy)
        let reloaded = DeviceRegistry(fileURL: legacy)
        XCTAssertEqual(reloaded.devices().first?.deviceID, credential.deviceID)
        XCTAssertNil(reloaded.devices().first?.successor)
        XCTAssertNil(reloaded.devices().first?.installID)
    }

    /// A pending successor is a key the next listener must carry.
    func testThePendingKeyIsAmongTheRegistrysActiveKeys() throws {
        let registry = DeviceRegistry(fileURL: mac.dir.appendingPathComponent("r.json"))
        let invite = PairingInvite.mint(macID: registry.macID, macName: "Mac")
        registry.addPending(invite)
        let credential = DeviceCredential.mint()
        XCTAssertFalse(registry.setSuccessor(credential, forDevice: invite.deviceID), "only a paired device rotates")
        XCTAssertTrue(registry.markPaired(deviceID: invite.deviceID, name: "iPhone", model: "iPhone17,1"))
        XCTAssertTrue(registry.setSuccessor(credential, forDevice: invite.deviceID))
        XCTAssertEqual(registry.activeKeys()[invite.deviceID], invite.key)
        XCTAssertEqual(registry.activeKeys()[credential.deviceID], credential.key)
        XCTAssertEqual(registry.device(forIdentity: credential.deviceID)?.deviceID, invite.deviceID)
        XCTAssertNil(registry.device(id: credential.deviceID), "not a device of its own until it is used")

        let promoted = try XCTUnwrap(registry.promoteSuccessor(identity: credential.deviceID))
        XCTAssertEqual(promoted.retired, invite.deviceID)
        XCTAssertEqual(promoted.device.name, "iPhone")
        XCTAssertEqual(registry.activeKeys(), [credential.deviceID: credential.key])
        XCTAssertNil(registry.promoteSuccessor(identity: credential.deviceID), "promoted once")
        XCTAssertNil(registry.promoteSuccessor(identity: invite.deviceID))
    }
}

// MARK: - unpair

final class UnpairTests: XCTestCase {
    private var mac: SyncHarness!

    override func setUp() async throws {
        mac = try await SyncHarness()
    }

    override func tearDown() async throws {
        mac?.tearDown()
    }

    /// "Forget this Mac" on the phone: the Mac drops the device too, at once
    /// and without touching its listener.
    func testUnpairRemovesThePhoneOnTheMac() async throws {
        let kept = try await mac.pairedPhone()
        let leaving = try await mac.pairedPhone()
        let epoch = mac.server.listenerEpoch
        let changes = mac.delegate.devicesChanged

        let session = try await mac.client(leaving).connect(timeout: 5)
        XCTAssertTrue(session.supports(SyncCapability.unpair))
        try await session.unpair()
        await session.close()

        XCTAssertNil(mac.registry.device(id: leaving.deviceID))
        XCTAssertNotNil(mac.registry.device(id: kept.deviceID), "unpair removed someone else")
        XCTAssertGreaterThan(mac.delegate.devicesChanged, changes, "the pane was not told")
        XCTAssertEqual(mac.server.listenerEpoch, epoch)
        let leavingWorks = try await mac.accepts(leaving)
        XCTAssertFalse(leavingWorks, "an unpaired phone still gets in")
        let keptWorks = try await mac.accepts(kept)
        XCTAssertTrue(keptWorks)
    }

    /// Mid-rotation there are two keys; unpair takes both.
    func testUnpairAlsoDropsAPendingKey() async throws {
        let link = PairedMac(invite: mac.server.makeInvite())
        let session = try await mac.client(link).connect(timeout: 5)
        let credential = try await session.rekey()
        try await session.unpair()
        await session.close()

        var stored = link
        stored.pending = credential
        let oldWorks = try await mac.accepts(link)
        XCTAssertFalse(oldWorks)
        let pendingWorks = try await mac.accepts(try XCTUnwrap(stored.usingPending))
        XCTAssertFalse(pendingWorks, "the issued key outlived the pairing")
        XCTAssertTrue(mac.registry.devices().isEmpty)
    }

    /// Other connections of the same phone end with it.
    func testUnpairClosesThePhonesOtherConnections() async throws {
        let phone = try await mac.pairedPhone()
        let other = try await mac.client(phone).connect(timeout: 5)
        let session = try await mac.client(phone).connect(timeout: 5)
        try await session.unpair()
        let (_, result) = await outcome { try await other.status(["a"]) }
        XCTAssertNotNil(result.syncError, "a connection of an unpaired phone kept working: \(result)")
        await other.close()
    }

    /// An iPhone app that predates `unpair` never sends it; one that sends it
    /// without announcing it is refused and stays paired.
    func testAnOldPhoneIsNotUnpairedByAccident() async throws {
        let phone = try await mac.pairedPhone()
        let session = try await mac.client(phone, capabilities: []).connect(timeout: 5)
        let (_, result) = await outcome { try await session.unpair() }
        guard case .protocolError("unsupported", _)? = result.syncError else {
            return XCTFail("expected unsupported, got \(result)")
        }
        _ = try await session.status(["a"])
        await session.close()

        let raw = try await mac.rawConnection(phone)
        defer { raw.cancel() }
        try await sendRaw(
            #"{"type":"hello","protocolVersion":1,"deviceID":"\#(phone.deviceID)","deviceName":"p","deviceModel":"m","appVersion":"1"}"#,
            on: raw)
        _ = try await raw.receive(timeout: 5)
        try await raw.send(.unpair)
        guard case .error(let error)? = try await raw.receive(timeout: 5) else { return XCTFail("served") }
        XCTAssertEqual(error.code, "bad_request")
        XCTAssertEqual(mac.registry.device(id: phone.deviceID)?.isPaired, true)
    }
}

// MARK: - pairing again

final class RepairingTests: XCTestCase {
    private var mac: SyncHarness!

    override func setUp() async throws {
        mac = try await SyncHarness()
    }

    override func tearDown() async throws {
        mac?.tearDown()
    }

    private func pair(installID: String?, announce: Bool = true) async throws -> PairedMac {
        let pairing = PairedMac(invite: mac.server.makeInvite())
        let before = mac.disconnects
        let session = try await mac.client(pairing, installID: announce ? installID : nil).connect(timeout: 5)
        await session.close()
        let harness = self.mac!
        _ = await eventually(3) { harness.disconnects > before }
        return pairing
    }

    /// The same install pairs twice: the Mac keeps one entry, and the earlier
    /// key — which used to stay valid for good — is refused.
    func testAPhoneThatPairsAgainReplacesItsEarlierEntry() async throws {
        let first = try await pair(installID: "INSTALL-A")
        XCTAssertEqual(mac.registry.device(id: first.deviceID)?.installID, "INSTALL-A")
        let epoch = mac.server.listenerEpoch
        let second = try await pair(installID: "INSTALL-A")

        XCTAssertEqual(mac.registry.devices().filter(\.isPaired).map(\.deviceID), [second.deviceID])
        XCTAssertEqual(mac.server.listenerEpoch, epoch)
        let firstWorks = try await mac.accepts(first)
        XCTAssertFalse(firstWorks, "the earlier pairing's key still works")
        let secondWorks = try await mac.accepts(second)
        XCTAssertTrue(secondWorks)
    }

    /// While the phone only *tries* a new code (its current pairing still in
    /// place) it does not send its install ID, and the Mac removes nothing:
    /// if that attempt is lost, the phone still needs its old key. The entry
    /// goes once the phone comes back with the pairing it kept.
    func testTheEarlierEntryStaysUntilThePhoneKeepsTheNewPairing() async throws {
        let first = try await pair(installID: "INSTALL-A")
        let candidate = try await pair(installID: "INSTALL-A", announce: false)
        XCTAssertEqual(mac.registry.devices().filter(\.isPaired).count, 2, "removed on a pairing the phone may not keep")
        let firstWorks = try await mac.accepts(first)
        XCTAssertTrue(firstWorks, "the phone's working pairing was taken away by an attempt")

        // The phone saved the new pairing and says so.
        let session = try await mac.client(candidate, installID: "INSTALL-A").connect(timeout: 5)
        await session.close()
        XCTAssertEqual(mac.registry.devices().filter(\.isPaired).map(\.deviceID), [candidate.deviceID])
    }

    /// …and if the phone kept the *old* pairing after all, it is the
    /// never-adopted entry that is left alone here (it has no install ID),
    /// not the pairing in use.
    func testAnEntryWithoutAnInstallIDIsNeverRemovedAutomatically() async throws {
        let legacy = try await pair(installID: nil)
        let modern = try await pair(installID: "INSTALL-A")
        XCTAssertEqual(mac.registry.devices().filter(\.isPaired).count, 2)
        let legacyWorks = try await mac.accepts(legacy)
        XCTAssertTrue(legacyWorks, "a phone that sends no install ID keeps the manual Remove")
        let modernWorks = try await mac.accepts(modern)
        XCTAssertTrue(modernWorks)
    }

    func testDifferentPhonesAreLeftAlone() async throws {
        let ana = try await pair(installID: "INSTALL-A")
        let bia = try await pair(installID: "INSTALL-B")
        XCTAssertEqual(mac.registry.devices().filter(\.isPaired).count, 2)
        let anaWorks = try await mac.accepts(ana)
        XCTAssertTrue(anaWorks)
        let biaWorks = try await mac.accepts(bia)
        XCTAssertTrue(biaWorks)
    }

    /// A connection of the replaced entry is closed with it.
    func testReplacingAnEntryClosesItsConnections() async throws {
        let first = try await pair(installID: "INSTALL-A")
        let open = try await mac.client(first).connect(timeout: 5)
        _ = try await pair(installID: "INSTALL-A")
        let (_, result) = await outcome { try await open.status(["a"]) }
        XCTAssertNotNil(result.syncError, "the replaced entry kept its session: \(result)")
        await open.close()
    }

    /// Pairing again and rotating together: one entry, under the rotated key,
    /// with the install ID carried over.
    func testReplacingSurvivesRotation() async throws {
        let first = try await mac.rotatedPhone(installID: "INSTALL-A")
        let second = try await mac.rotatedPhone(installID: "INSTALL-A")
        let devices = mac.registry.devices().filter(\.isPaired)
        XCTAssertEqual(devices.map(\.deviceID), [second.deviceID])
        XCTAssertEqual(devices.first?.installID, "INSTALL-A")
        XCTAssertNotNil(devices.first?.rotatedAt)
        let firstWorks = try await mac.accepts(first)
        XCTAssertFalse(firstWorks)
    }

    /// An install ID that is not a usable ID is "none", not a refused hello.
    func testAnUnusableInstallIDIsIgnored() async throws {
        for bad in ["../../etc", String(repeating: "x", count: 65), ""] {
            let pairing = PairedMac(invite: mac.server.makeInvite())
            let raw = try await mac.rawConnection(pairing)
            defer { raw.cancel() }
            let escaped = bad.replacingOccurrences(of: "/", with: "\\/")
            try await sendRaw(
                #"{"type":"hello","protocolVersion":1,"deviceID":"\#(pairing.deviceID)","deviceName":"p","deviceModel":"m","appVersion":"1","installID":"\#(escaped)"}"#,
                on: raw)
            guard case .welcome? = try await raw.receive(timeout: 5) else { return XCTFail("refused for \(bad)") }
            XCTAssertNil(mac.registry.device(id: pairing.deviceID)?.installID)
        }
        // Not even a string.
        let pairing = PairedMac(invite: mac.server.makeInvite())
        let raw = try await mac.rawConnection(pairing)
        defer { raw.cancel() }
        try await sendRaw(
            #"{"type":"hello","protocolVersion":1,"deviceID":"\#(pairing.deviceID)","deviceName":"p","deviceModel":"m","appVersion":"1","installID":42}"#,
            on: raw)
        guard case .welcome? = try await raw.receive(timeout: 5) else { return XCTFail("refused") }
    }

    /// Today's build decodes `hello` over exactly these fields: it must read
    /// what this one sends, install ID and all.
    func testAnOlderMacReadsAHelloWithAnInstallID() throws {
        struct OldHello: Decodable {
            var protocolVersion: Int
            var deviceID: String
            var deviceName: String
            var deviceModel: String
            var appVersion: String
        }
        let bytes = try WireCodec.encode(
            .hello(
                HelloMessage(
                    protocolVersion: 1, deviceID: "d", deviceName: "n", deviceModel: "m", appVersion: "1",
                    capabilities: SyncConstants.capabilities, installID: "INSTALL-A")))
        let length = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        let header = Data(bytes.dropFirst(4).prefix(length))
        XCTAssertEqual(try JSONDecoder().decode(OldHello.self, from: header).deviceID, "d")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: header) as? [String: Any])
        XCTAssertEqual(json["installID"] as? String, "INSTALL-A")
        // Absent, not null, when there is none.
        let bare = try WireCodec.encode(
            .hello(HelloMessage(protocolVersion: 1, deviceID: "d", deviceName: "n", deviceModel: "m", appVersion: "1")))
        let bareLength = bare.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        let bareJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(bare.dropFirst(4).prefix(bareLength))) as? [String: Any])
        XCTAssertNil(bareJSON["installID"])
    }
}

// MARK: - spare slots

final class SpareSlotTests: XCTestCase {
    private var mac: SyncHarness!

    override func setUp() async throws {
        mac = try await SyncHarness()
    }

    override func tearDown() async throws {
        mac?.tearDown()
    }

    /// Every ninth invite used to replace the listener (8 spares), and with
    /// rotation a pairing takes two slots. Twenty pairings in a row — far
    /// more than anyone does without a pause — never touch it.
    func testManyPairingsInARowNeverReplaceTheListener() async throws {
        let epoch = mac.server.listenerEpoch
        let port = try await mac.port()
        var phones: [PairedMac] = []
        for _ in 0..<20 {
            phones.append(try await mac.rotatedPhone())
            XCTAssertEqual(mac.server.listenerEpoch, epoch, "pairing #\(phones.count) replaced the listener")
        }
        XCTAssertEqual(mac.server.spareSlotCount, SyncServer.spareSlots - 40)
        XCTAssertEqual(mac.server.port, port)
        XCTAssertEqual(
            mac.events.values.filter { if case .listening = $0 { return true } else { return false } }.count, 1,
            "the listener came up once and stayed")
        for phone in [phones[0], phones[19]] {
            let works = try await mac.accepts(phone)
            XCTAssertTrue(works)
        }
    }

    func testAFullPoolIsLeftAlone() async throws {
        mac.server.replenishQuietPeriod = 0
        XCTAssertEqual(mac.server.spareSlotCount, SyncServer.spareSlots)
        XCTAssertFalse(mac.server.replenishSparesIfQuiet())
        // Down to the mark, not below it.
        var invites: [PairingInvite] = []
        while mac.server.spareSlotCount > SyncServer.spareLowWater { invites.append(mac.server.makeInvite()) }
        for invite in invites { mac.registry.remove(deviceID: invite.deviceID) }
        XCTAssertFalse(mac.server.replenishSparesIfQuiet(), "replaced the listener with spares to spare")
    }

    /// Running low, the listener is replaced only when nobody would notice:
    /// not with a connection open, not while a code waits to be scanned, not
    /// right after something happened. Then once — and every key the old
    /// listener honoured still works.
    func testSparesAreReplenishedOnlyAtAQuietMoment() async throws {
        let paired = try await mac.pairedPhone()
        let midRotation = PairedMac(invite: mac.server.makeInvite())
        let asking = try await mac.client(midRotation).connect(timeout: 5)
        let credential = try await asking.rekey()
        await asking.close()

        // Use the pool up to below the mark; the invites themselves are
        // withdrawn again (nobody is about to scan them).
        var used: [PairingInvite] = []
        while mac.server.spareSlotCount >= SyncServer.spareLowWater { used.append(mac.server.makeInvite()) }
        for invite in used { mac.registry.remove(deviceID: invite.deviceID) }
        let epoch = mac.server.listenerEpoch

        // Right after activity: not quiet yet.
        mac.server.replenishQuietPeriod = 3600
        XCTAssertFalse(mac.server.replenishSparesIfQuiet(), "replaced right after activity")
        mac.server.replenishQuietPeriod = 0

        // A phone is connected.
        let open = try await mac.client(paired).connect(timeout: 5)
        XCTAssertFalse(mac.server.replenishSparesIfQuiet(), "replaced under a connected phone")
        let before = mac.disconnects
        await open.close()
        let harness = self.mac!
        _ = await eventually(3) { harness.disconnects > before }

        // A pairing code is on screen.
        let waiting = mac.server.makeInvite()
        XCTAssertFalse(mac.server.replenishSparesIfQuiet(), "replaced while a pairing code waits to be scanned")
        XCTAssertEqual(mac.server.listenerEpoch, epoch)

        // The code expired unused; now it is quiet.
        mac.registry.addPending(
            PairingInvite(
                macID: waiting.macID, macName: waiting.macName, deviceID: waiting.deviceID,
                key: waiting.key, expiresAt: Date().addingTimeInterval(-1)))
        // (The closed connection leaves the server's books a moment after
        // its last event.)
        let replaced = await eventually(3) { harness.server.replenishSparesIfQuiet() }
        XCTAssertTrue(replaced, "never replenished")
        XCTAssertEqual(mac.server.listenerEpoch, epoch + 1)
        _ = try await mac.port()
        let full = await eventually(3) { harness.server.spareSlotCount == SyncServer.spareSlots }
        XCTAssertTrue(full, "the new listener has \(mac.server.spareSlotCount) spares")
        XCTAssertFalse(mac.server.replenishSparesIfQuiet(), "replaced twice")

        // Nothing was lost in the swap: a paired phone, and both keys of one
        // caught mid-rotation.
        let pairedWorks = try await mac.accepts(paired)
        XCTAssertTrue(pairedWorks)
        let oldWorks = try await mac.accepts(midRotation)
        XCTAssertTrue(oldWorks)
        let rotated = try await mac.confirm(midRotation, credential)
        let newWorks = try await mac.accepts(rotated)
        XCTAssertTrue(newWorks, "a key issued before the swap is refused after it")
    }
}
