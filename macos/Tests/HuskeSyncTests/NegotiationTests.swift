// Version negotiation and capabilities (sync-protocol.md § Versioning).
//
// The iPhone app and Huske.app update through different channels, so any pair
// can be a mixed one. The rule under test: `hello` names the highest version
// the phone speaks, the Mac answers with the lower of the two, unknown JSON
// keys are ignored everywhere, and additive features travel as capability
// names — so a version bump is reserved for a breaking change and never
// strands a mixed pair.

import Network
import XCTest

@_spi(Testing) @testable import HuskeSync

/// The frame a peer puts on the wire for `json`: lets a test speak for an app
/// version this build cannot produce.
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

// MARK: - the Mac's side

final class ServerNegotiationTests: XCTestCase {
    private var mac: SyncHarness!
    private var phone: PairedMac!

    override func setUp() async throws {
        mac = try await SyncHarness()
        phone = PairedMac(invite: mac.server.makeInvite())
    }

    override func tearDown() async throws {
        mac?.tearDown()
    }

    /// Sends `hello` exactly as written and returns the Mac's answer.
    private func answer(toHello json: String) async throws -> (WireMessage?, FramedConnection) {
        let framed = try await mac.rawConnection(phone)
        try await sendRaw(json, on: framed)
        return (try await framed.receive(timeout: 5), framed)
    }

    private func assertStillUsable(_ framed: FramedConnection, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await framed.send(.status(StatusRequestMessage(recordingIDs: ["a"])))
        guard case .statusReply(let reply)? = try await framed.receive(timeout: 5) else {
            return XCTFail("the connection did not carry on after hello", file: file, line: line)
        }
        XCTAssertEqual(reply.items.first?.state, .unknown, file: file, line: line)
    }

    /// The first protocol bump must not break phones that updated before the
    /// Mac did: the Mac answers with its own, lower version and carries on.
    func testAHelloFromANewerPhoneIsAnsweredWithTheMacsVersion() async throws {
        let (reply, framed) = try await answer(
            toHello: #"{"type":"hello","protocolVersion":2,"deviceID":"\#(phone.deviceID)","deviceName":"Phone from the future","deviceModel":"iPhone19,1","appVersion":"3.0"}"#)
        defer { framed.cancel() }
        guard case .welcome(let welcome)? = reply else { return XCTFail("expected welcome, got \(String(describing: reply))") }
        XCTAssertEqual(welcome.protocolVersion, 1, "min(phone 2, Mac 1)")
        XCTAssertEqual(welcome.macID, mac.registry.macID)
        XCTAssertEqual(mac.registry.device(id: phone.deviceID)?.name, "Phone from the future")
        try await assertStillUsable(framed)
    }

    func testAnyHigherVersionNegotiatesDown() async throws {
        let (reply, framed) = try await answer(
            toHello: #"{"type":"hello","protocolVersion":9000,"deviceID":"\#(phone.deviceID)","deviceName":"p","deviceModel":"m","appVersion":"9"}"#)
        defer { framed.cancel() }
        guard case .welcome(let welcome)? = reply else { return XCTFail("expected welcome, got \(String(describing: reply))") }
        XCTAssertEqual(welcome.protocolVersion, SyncConstants.protocolVersion)
    }

    /// A newer phone announces features this Mac has never heard of and sends
    /// fields it does not know: both are ignored, not refused.
    func testAHelloWithUnknownFieldsAndCapabilitiesIsAccepted() async throws {
        let (reply, framed) = try await answer(
            toHello: #"""
                {"type":"hello","protocolVersion":1,"deviceID":"\#(phone.deviceID)","deviceName":"Newer phone",
                "deviceModel":"iPhone19,1","appVersion":"2.5","capabilities":["transcript.live","made.up"],
                "locale":"pt-BR","battery":{"level":0.8,"charging":true},"hints":[1,"two",null]}
                """#)
        defer { framed.cancel() }
        guard case .welcome(let welcome)? = reply else { return XCTFail("expected welcome, got \(String(describing: reply))") }
        XCTAssertEqual(welcome.protocolVersion, 1)
        XCTAssertEqual(welcome.capabilities, SyncConstants.capabilities)
        XCTAssertEqual(mac.registry.device(id: phone.deviceID)?.isPaired, true)
        try await assertStillUsable(framed)
    }

    /// Byte for byte what the build without capabilities sends.
    func testAnOldStyleHelloWithoutCapabilitiesIsAccepted() async throws {
        let (reply, framed) = try await answer(
            toHello: #"{"appVersion":"1.0 (1)","deviceID":"\#(phone.deviceID)","deviceModel":"iPhone16,1","deviceName":"iPhone","protocolVersion":1,"type":"hello"}"#)
        defer { framed.cancel() }
        guard case .welcome(let welcome)? = reply else { return XCTFail("expected welcome, got \(String(describing: reply))") }
        XCTAssertEqual(welcome.protocolVersion, 1)
        XCTAssertEqual(mac.registry.device(id: phone.deviceID)?.isPaired, true)
        try await assertStillUsable(framed)
    }

    /// Below the oldest version this Mac speaks there is nothing to fall back
    /// to: say so and hang up, without pairing the device.
    func testAHelloBelowTheOldestVersionIsRefused() async throws {
        let (reply, framed) = try await answer(
            toHello: #"{"type":"hello","protocolVersion":0,"deviceID":"\#(phone.deviceID)","deviceName":"p","deviceModel":"m","appVersion":"0.1"}"#)
        defer { framed.cancel() }
        guard case .error(let error)? = reply else { return XCTFail("expected version_mismatch, got \(String(describing: reply))") }
        XCTAssertEqual(error.code, "version_mismatch")
        XCTAssertEqual(mac.registry.device(id: phone.deviceID)?.isPaired, false)
        let next = try? await framed.receive(timeout: 5)
        XCTAssertNil(next ?? nil, "the Mac closes after refusing")
    }

    /// End to end with this build on both sides: the phone's hello carries its
    /// capabilities and the welcome reports the Mac's.
    func testThisBuildNegotiatesItsOwnVersion() async throws {
        let session = try await mac.client(phone).connect(timeout: 5)
        XCTAssertEqual(session.welcome.protocolVersion, SyncConstants.protocolVersion)
        XCTAssertEqual(session.welcome.capabilities, SyncConstants.capabilities)
        await session.close()
    }
}

// MARK: - the iPhone's side

/// A stand-in Mac: completes the TLS-PSK handshake, reads `hello`, and answers
/// with whatever the test scripted — an older Huske.app, a newer one, one that
/// does not negotiate.
private final class ScriptedMac: @unchecked Sendable {
    let pairing: PairedMac
    private let listener: NWListener
    private let queue = DispatchQueue(label: "huske.test.scripted-mac")
    private let lock = NSLock()
    private var _hello: HelloMessage?
    private var connections: [FramedConnection] = []

    /// `reply` gets the macID the phone is paired with.
    init(reply: @escaping @Sendable (_ macID: String) -> String) throws {
        let invite = PairingInvite.mint(macID: UUID().uuidString, macName: "Scripted Mac")
        pairing = PairedMac(invite: invite)
        let params = TLSPSK.serverParameters(keys: [invite.deviceID: invite.key], queue: queue) { _, _ in true }
        listener = try NWListener(using: params)
        let macID = invite.macID
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            let framed = FramedConnection(connection, label: "scripted-mac")
            self.lock.withLock { self.connections.append(framed) }
            Task {
                do {
                    try await framed.start(timeout: 5)
                    if case .hello(let hello)? = try await framed.receive(timeout: 5) {
                        self.lock.withLock { self._hello = hello }
                    }
                    try await sendRaw(reply(macID), on: framed)
                    // Stay until the phone leaves.
                    while try await framed.receive(timeout: 5) != nil {}
                } catch {}
                framed.cancel()
            }
        }
        listener.start(queue: queue)
    }

    var hello: HelloMessage? { lock.withLock { _hello } }

    func client() async throws -> SyncClient {
        var port: UInt16 = 0
        for _ in 0..<500 where port == 0 {
            port = listener.port?.rawValue ?? 0
            if port == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        return SyncClient(
            pairing: pairing, deviceName: "iPhone de Teste", deviceModel: "iPhone17,1",
            appVersion: "1.0", endpoint: SyncHarness.loopback(port))
    }

    func stop() {
        listener.cancel()
        for connection in lock.withLock({ connections }) { connection.cancel() }
    }
}

final class ClientNegotiationTests: XCTestCase {
    /// Huske.app as it was before capabilities: no such key in `welcome`.
    func testAWelcomeFromAnOlderMacIsAccepted() async throws {
        let oldMac = try ScriptedMac { macID in
            #"{"engineAvailable":true,"macID":"\#(macID)","macName":"Old Mac","protocolVersion":1,"serverVersion":"0.14.0","type":"welcome"}"#
        }
        defer { oldMac.stop() }
        let session = try await oldMac.client().connect(timeout: 5)
        XCTAssertEqual(session.welcome.protocolVersion, 1)
        XCTAssertEqual(session.welcome.macName, "Old Mac")
        XCTAssertEqual(session.welcome.capabilities, [], "no capabilities key = none")
        // What this build put in its hello.
        XCTAssertEqual(oldMac.hello?.protocolVersion, SyncConstants.protocolVersion)
        XCTAssertEqual(oldMac.hello?.capabilities, SyncConstants.capabilities)
        await session.close()
    }

    /// A newer Huske.app: features and fields this phone has never heard of.
    func testAWelcomeWithUnknownFieldsAndCapabilitiesIsAccepted() async throws {
        let newMac = try ScriptedMac { macID in
            #"""
            {"type":"welcome","protocolVersion":1,"macID":"\#(macID)","macName":"Newer Mac","serverVersion":"2.0.0",
            "engineAvailable":false,"capabilities":["transcript.live","made.up"],
            "engine":{"version":"2.0.0","models":["parakeet"]},"motd":null}
            """#
        }
        defer { newMac.stop() }
        let session = try await newMac.client().connect(timeout: 5)
        XCTAssertEqual(session.welcome.capabilities, ["transcript.live", "made.up"])
        XCTAssertFalse(session.welcome.engineAvailable)
        await session.close()
    }

    /// The Mac must answer with a version the phone named or lower. One that
    /// insists on a newer version is speaking something this build cannot.
    func testAWelcomeAboveThePhonesVersionIsAMismatch() async throws {
        for version in [SyncConstants.protocolVersion + 1, 0] {
            let mac = try ScriptedMac { macID in
                #"{"type":"welcome","protocolVersion":\#(version),"macID":"\#(macID)","macName":"Mac","serverVersion":"9","engineAvailable":true}"#
            }
            defer { mac.stop() }
            let client = try await mac.client()
            let (_, result) = await outcome { try await client.connect(timeout: 5) }
            guard case .protocolError(let code, _)? = result.syncError else {
                XCTFail("welcome v\(version) should be a version mismatch, got \(result)")
                continue
            }
            XCTAssertEqual(code, "version_mismatch", "welcome v\(version)")
        }
    }

    /// A Mac that refuses the phone's version says so; the app turns this
    /// code into "update Huske on both devices".
    func testAVersionMismatchFromTheMacIsReportedAsOne() async throws {
        let strict = try ScriptedMac { _ in
            #"{"type":"error","code":"version_mismatch","message":"this Mac speaks protocol v7"}"#
        }
        defer { strict.stop() }
        let client = try await strict.client()
        let (_, result) = await outcome { try await client.connect(timeout: 5) }
        XCTAssertEqual(
            result.syncError, .protocolError(code: "version_mismatch", message: "this Mac speaks protocol v7"))
    }
}

// MARK: - on the wire

final class VersioningWireTests: XCTestCase {
    func testTheConnectionSpeaksTheLowerOfTheTwoVersions() {
        XCTAssertEqual(SyncConstants.protocolVersion, 1, "v1 until a breaking change")
        XCTAssertNil(SyncConstants.negotiatedVersion(withPeer: 0))
        XCTAssertNil(SyncConstants.negotiatedVersion(withPeer: -3))
        XCTAssertEqual(SyncConstants.negotiatedVersion(withPeer: 1), 1)
        XCTAssertEqual(SyncConstants.negotiatedVersion(withPeer: 2), 1)
        XCTAssertEqual(SyncConstants.negotiatedVersion(withPeer: .max), 1)
    }

    /// A protocol bump must not turn pairing links into "not a pairing link"
    /// for the app on the phone: the link has a version of its own.
    func testThePairingLinkVersionIsNotTheProtocolVersion() throws {
        let invite = PairingInvite.mint(macID: "MAC", macName: "Mac")
        let items = try XCTUnwrap(URLComponents(url: invite.url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "v" }?.value, String(SyncConstants.pairingLinkVersion))
        XCTAssertEqual(SyncConstants.pairingLinkVersion, 1)
    }

    private func headerJSON(_ message: WireMessage) throws -> [String: Any] {
        let bytes = try WireCodec.encode(message)
        let length = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes.dropFirst(4).prefix(length)) as? [String: Any])
    }

    func testHelloAndWelcomeCarryCapabilities() throws {
        let hello = try headerJSON(
            .hello(HelloMessage(protocolVersion: 1, deviceID: "d", deviceName: "n", deviceModel: "m", appVersion: "1", capabilities: ["a", "b"])))
        XCTAssertEqual(hello["capabilities"] as? [String], ["a", "b"])
        XCTAssertEqual(hello["protocolVersion"] as? Int, 1)
        let welcome = try headerJSON(
            .welcome(Welcome(protocolVersion: 1, macID: "m", macName: "Mac", serverVersion: "1", engineAvailable: true, capabilities: ["c"])))
        XCTAssertEqual(welcome["capabilities"] as? [String], ["c"])
        // Sent even when empty, so every connection exercises the key.
        let bare = try headerJSON(
            .hello(HelloMessage(protocolVersion: 1, deviceID: "d", deviceName: "n", deviceModel: "m", appVersion: "1")))
        XCTAssertEqual(bare["capabilities"] as? [String], [])
    }

    func testCapabilitiesAreOptionalOnInput() throws {
        let hello = try WireCodec.decode(
            Frame(header: Data(#"{"type":"hello","protocolVersion":1,"deviceID":"d","deviceName":"n","deviceModel":"m","appVersion":"1"}"#.utf8), body: Data()))
        XCTAssertEqual(
            hello, .hello(HelloMessage(protocolVersion: 1, deviceID: "d", deviceName: "n", deviceModel: "m", appVersion: "1", capabilities: [])))
        let welcome = try WireJSON.decoder().decode(
            Welcome.self,
            from: Data(#"{"protocolVersion":1,"macID":"m","macName":"Mac","serverVersion":"1","engineAvailable":true}"#.utf8))
        XCTAssertEqual(welcome.capabilities, [])
    }

    /// The build without capabilities decodes `hello` and `welcome` with
    /// Swift's synthesized `Decodable` over exactly these fields. It must read
    /// what this build sends — proof that old peers ignore the new key.
    func testABuildWithoutCapabilitiesReadsOurHelloAndWelcome() throws {
        struct OldHello: Decodable, Equatable {
            var protocolVersion: Int
            var deviceID: String
            var deviceName: String
            var deviceModel: String
            var appVersion: String
        }
        struct OldWelcome: Decodable, Equatable {
            let protocolVersion: Int
            let macID: String
            let macName: String
            let serverVersion: String
            let engineAvailable: Bool
        }
        func header(_ message: WireMessage) throws -> Data {
            let bytes = try WireCodec.encode(message)
            let length = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            return Data(bytes.dropFirst(4).prefix(length))
        }
        let hello = try header(
            .hello(HelloMessage(protocolVersion: 1, deviceID: "d", deviceName: "n", deviceModel: "m", appVersion: "1", capabilities: ["x"])))
        XCTAssertEqual(
            try JSONDecoder().decode(OldHello.self, from: hello),
            OldHello(protocolVersion: 1, deviceID: "d", deviceName: "n", deviceModel: "m", appVersion: "1"))
        let welcome = try header(
            .welcome(Welcome(protocolVersion: 1, macID: "m", macName: "Mac", serverVersion: "1", engineAvailable: true, capabilities: ["x"])))
        XCTAssertEqual(
            try JSONDecoder().decode(OldWelcome.self, from: welcome),
            OldWelcome(protocolVersion: 1, macID: "m", macName: "Mac", serverVersion: "1", engineAvailable: true))
    }

    /// Additive fields are how the protocol grows, so every message — not
    /// only hello — has to shrug off keys it does not know, at the top level
    /// and inside nested objects, through the real frame parser.
    func testEveryMessageIgnoresUnknownKeys() throws {
        let manifest = RecordingManifest(
            id: "r1", title: "Reunião", startedAt: Date(timeIntervalSince1970: 1_763_571_780),
            durationSeconds: 12, byteCount: 10, sha256: String(repeating: "ab", count: 32),
            fileExtension: "m4a", contentType: "audio/mp4", sampleRate: 48_000, channels: 1,
            timeZone: "UTC", deviceName: "iPhone")
        let status = RemoteStatus(
            recordingID: "r1", state: .transcribing, detail: "1 of 3",
            updatedAt: Date(timeIntervalSince1970: 1_763_573_000), progress: 0.5)
        let messages: [WireMessage] = [
            .hello(HelloMessage(protocolVersion: 1, deviceID: "d", deviceName: "n", deviceModel: "m", appVersion: "1", capabilities: ["a"])),
            .welcome(Welcome(protocolVersion: 1, macID: "m", macName: "Mac", serverVersion: "1", engineAvailable: true, capabilities: ["b"])),
            .offer(OfferMessage(recording: manifest)),
            .offerReply(OfferReplyMessage(recordingID: "r1", action: .send, offset: 5)),
            .chunk(ChunkMessage(recordingID: "r1", offset: 0), body: Data([1, 2, 3])),
            .chunkAck(ChunkAckMessage(recordingID: "r1", received: 3)),
            .commit(CommitMessage(recordingID: "r1")),
            .committed(CommittedMessage(status: status)),
            .status(StatusRequestMessage(recordingIDs: ["r1"])),
            .statusReply(StatusReplyMessage(items: [status])),
            .transcript(TranscriptRequestMessage(recordingID: "r1")),
            .transcriptReply(TranscriptReplyMessage(recordingID: "r1", available: true), body: Data("# Olá".utf8)),
            .bye,
            .error(ErrorMessage(code: .offsetMismatch, message: "expected 3", received: 3)),
        ]
        /// Adds a key nobody knows to every JSON object, however deep.
        func sprinkle(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                for (key, inner) in object { object[key] = sprinkle(inner) }
                object["x-from-the-future"] = ["nested": [1, "two"], "flag": true] as [String: Any]
                return object
            }
            if let array = value as? [Any] { return array.map(sprinkle) }
            return value
        }
        for message in messages {
            let bytes = try WireCodec.encode(message)
            let length = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            let body = Data(bytes.dropFirst(4 + length))
            let original = try JSONSerialization.jsonObject(with: bytes.dropFirst(4).prefix(length))
            let header = try JSONSerialization.data(withJSONObject: sprinkle(original))
            var frameLength = UInt32(header.count).bigEndian
            var decoder = FrameDecoder()
            decoder.append(withUnsafeBytes(of: &frameLength) { Data($0) } + header + body)
            let frame = try XCTUnwrap(try decoder.nextFrame(), message.type)
            XCTAssertEqual(try WireCodec.decode(frame), message, message.type)
        }
    }
}
