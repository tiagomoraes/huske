import CryptoKit
import XCTest

@testable import HuskeSync

final class PairingTests: XCTestCase {
    private func invite(name: String = "MacBook de Tiago") -> PairingInvite {
        PairingInvite.mint(macID: UUID().uuidString, macName: name, now: Date())
    }

    func testMintProducesFreshKeyAndTenMinuteExpiry() {
        let now = Date()
        let a = PairingInvite.mint(macID: "M", macName: "Mac", now: now)
        let b = PairingInvite.mint(macID: "M", macName: "Mac", now: now)
        XCTAssertEqual(a.key.count, 32)
        XCTAssertNotEqual(a.key, b.key)
        XCTAssertNotEqual(a.deviceID, b.deviceID)
        XCTAssertTrue(SyncConstants.isValidID(a.deviceID))
        XCTAssertEqual(a.expiresAt.timeIntervalSince(now), 600, accuracy: 0.001)
    }

    func testURLShape() throws {
        let inv = invite()
        let url = inv.url
        XCTAssertEqual(url.scheme, "huske")
        XCTAssertEqual(url.host, "pair")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.map(\.name), ["v", "mac", "name", "id", "exp", "key"])
        let key = try XCTUnwrap(items.first { $0.name == "key" }?.value)
        XCTAssertEqual(key.count, 43, "32 bytes base64url without padding")
        XCTAssertFalse(key.contains("="))
        XCTAssertFalse(key.contains("+") || key.contains("/"))
    }

    func testURLRoundTrip() throws {
        for name in ["MacBook de Tiago", "Tiago’s Mac & Ana = 1?", "Mac+Studio/#1", "Ünïcødé 🎙️"] {
            let inv = invite(name: name)
            let parsed = try XCTUnwrap(PairingInvite(url: inv.url), name)
            XCTAssertEqual(parsed.macID, inv.macID)
            XCTAssertEqual(parsed.macName, name)
            XCTAssertEqual(parsed.deviceID, inv.deviceID)
            XCTAssertEqual(parsed.key, inv.key)
        }
    }

    func testParsesURLEmbeddedInText() throws {
        let inv = invite()
        let link = inv.url.absoluteString
        let samples = [
            "Pair your iPhone: \(link) (expires in 10 minutes)",
            "<\(link)>",
            "\"\(link)\"",
            "line one\n\(link)\nline three",
            link.replacingOccurrences(of: "huske://", with: "HUSKE://"),
        ]
        for text in samples {
            let parsed = try XCTUnwrap(PairingInvite(string: text), text)
            XCTAssertEqual(parsed.deviceID, inv.deviceID)
            XCTAssertEqual(parsed.key, inv.key)
        }
    }

    func testRejectsMalformedLinks() {
        let inv = invite()
        let good = inv.url.absoluteString
        XCTAssertNil(PairingInvite(string: "no link here"))
        XCTAssertNil(PairingInvite(string: good.replacingOccurrences(of: "huske://pair", with: "https://pair")))
        XCTAssertNil(PairingInvite(string: good.replacingOccurrences(of: "v=1", with: "v=2")))
        XCTAssertNil(PairingInvite(string: good.replacingOccurrences(of: "key=", with: "kee=")))
        // A truncated key is not a 32-byte key.
        let truncated = String(good.dropLast(4))
        XCTAssertNil(PairingInvite(string: truncated))
    }

    func testPairedMacFromInvite() {
        let inv = invite()
        let paired = PairedMac(invite: inv, pairedAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(paired.macID, inv.macID)
        XCTAssertEqual(paired.deviceID, inv.deviceID)
        XCTAssertEqual(paired.key, inv.key)
        XCTAssertEqual(paired.pairedAt, Date(timeIntervalSince1970: 1_000))
    }

    func testIDValidation() {
        XCTAssertTrue(SyncConstants.isValidID("4E1C0A5B-0F7E-4C67-9C0B-3C8F3A1B2D11"))
        XCTAssertTrue(SyncConstants.isValidID("a.b_c-1"))
        XCTAssertFalse(SyncConstants.isValidID(""))
        XCTAssertFalse(SyncConstants.isValidID("../etc"))
        XCTAssertFalse(SyncConstants.isValidID("with space"))
        XCTAssertFalse(SyncConstants.isValidID(String(repeating: "a", count: 65)))
    }

    func testManifestMakeHashesStreaming() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("huske-sync-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Larger than one 1 MiB read so the streaming path is exercised.
        var bytes = Data(count: 3 * 1024 * 1024 + 17)
        for i in 0..<bytes.count { bytes[i] = UInt8(truncatingIfNeeded: i &* 31) }
        let file = dir.appendingPathComponent("memo.M4A")
        try bytes.write(to: file)
        let manifest = try RecordingManifest.make(
            id: "rec-1", title: "Memo", startedAt: Date(timeIntervalSince1970: 1_763_571_780),
            durationSeconds: 12.5, fileURL: file, sampleRate: 48_000, channels: 1,
            timeZone: TimeZone(identifier: "America/Sao_Paulo")!, deviceName: "iPhone")
        XCTAssertEqual(manifest.byteCount, Int64(bytes.count))
        XCTAssertEqual(manifest.sha256, SHA256.hash(data: bytes).hexString)
        XCTAssertEqual(manifest.fileExtension, "m4a")
        XCTAssertEqual(manifest.contentType, "audio/mp4")
        XCTAssertEqual(manifest.timeZone, "America/Sao_Paulo")
        XCTAssertNil(manifest.validationError())
    }

    func testRemoteStateTerminalAndForwardCompatible() throws {
        XCTAssertTrue(RemoteState.transcribed.isTerminal)
        XCTAssertTrue(RemoteState.failed.isTerminal)
        XCTAssertFalse(RemoteState.transcribing.isTerminal)
        let decoded = try JSONDecoder().decode([RemoteState].self, from: Data(#"["queued","exploded"]"#.utf8))
        XCTAssertEqual(decoded, [.queued, .unknown])
    }
}

final class DeviceRegistryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("huske-sync-registry-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMacIDIsStableAndFileIsPrivate() throws {
        let file = dir.appendingPathComponent("PhoneSync/devices.json")
        let first = DeviceRegistry(fileURL: file)
        let macID = first.macID
        XCTAssertEqual(DeviceRegistry(fileURL: file).macID, macID)
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testPendingPairedRemoveAndPrune() throws {
        let file = dir.appendingPathComponent("devices.json")
        let registry = DeviceRegistry(fileURL: file)
        let now = Date()
        let live = PairingInvite.mint(macID: registry.macID, macName: "Mac", now: now)
        let stale = PairingInvite.mint(macID: registry.macID, macName: "Mac", now: now.addingTimeInterval(-3600))
        registry.addPending(live)
        registry.addPending(stale)
        XCTAssertEqual(registry.devices().count, 2)
        XCTAssertFalse(registry.device(id: live.deviceID)!.isPaired)
        XCTAssertEqual(Set(registry.activeKeys(now: now).keys), [live.deviceID])

        XCTAssertEqual(registry.pruneExpired(now: now), [stale.deviceID])
        XCTAssertTrue(registry.markPaired(deviceID: live.deviceID, name: "iPhone de Tiago", model: "iPhone17,1"))
        let paired = try XCTUnwrap(registry.device(id: live.deviceID))
        XCTAssertTrue(paired.isPaired)
        XCTAssertNil(paired.expiresAt)
        XCTAssertEqual(paired.name, "iPhone de Tiago")
        // Paired devices never expire.
        XCTAssertTrue(registry.pruneExpired(now: now.addingTimeInterval(86_400)).isEmpty)

        // Survives a reload, key included.
        let reloaded = DeviceRegistry(fileURL: file)
        XCTAssertEqual(reloaded.device(id: live.deviceID)?.key, live.key)
        XCTAssertEqual(reloaded.device(id: live.deviceID)?.name, "iPhone de Tiago")

        reloaded.remove(deviceID: live.deviceID)
        XCTAssertTrue(DeviceRegistry(fileURL: file).devices().isEmpty)
    }

    func testExpiredPendingCannotPair() {
        let registry = DeviceRegistry(fileURL: dir.appendingPathComponent("devices.json"))
        let stale = PairingInvite.mint(macID: registry.macID, macName: "Mac", now: Date().addingTimeInterval(-3600))
        registry.addPending(stale)
        XCTAssertFalse(registry.markPaired(deviceID: stale.deviceID, name: "x", model: nil))
    }
}

final class IDRuleTests: XCTestCase {
    func testLeadingDotIDsAreRefused() {
        XCTAssertTrue(SyncConstants.isValidID("4E1C0A5B-0F7E.v2_x"))
        XCTAssertFalse(SyncConstants.isValidID(".."))
        XCTAssertFalse(SyncConstants.isValidID("."))
        XCTAssertFalse(SyncConstants.isValidID(".lock"))
        XCTAssertFalse(SyncConstants.isValidID("a/b"))
        XCTAssertFalse(SyncConstants.isValidID(""))
    }
}

final class InviteExpiryTests: XCTestCase {
    func testURLCarriesExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let invite = PairingInvite.mint(macID: "MAC", macName: "Mac", now: now)
        XCTAssertTrue(invite.url.absoluteString.contains("exp=\(1_800_000_000 + Int(SyncConstants.inviteLifetime))"))
        let parsed = try XCTUnwrap(PairingInvite(url: invite.url))
        XCTAssertEqual(parsed.expiresAt.timeIntervalSince1970, invite.expiresAt.timeIntervalSince1970.rounded(.down))
        XCTAssertTrue(parsed.isExpired(now: now.addingTimeInterval(SyncConstants.inviteLifetime + 1)))
    }

    func testLinksWithoutExpiryStillParse() throws {
        let invite = PairingInvite.mint(macID: "MAC", macName: "Mac")
        let legacy = invite.url.absoluteString.replacingOccurrences(
            of: #"&exp=\d+"#, with: "", options: .regularExpression)
        let parsed = try XCTUnwrap(PairingInvite(string: legacy))
        XCTAssertFalse(parsed.isExpired())
    }
}
