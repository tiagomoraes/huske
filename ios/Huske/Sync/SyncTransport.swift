// A thin seam over HuskeSync's client so SyncManager can run against a fake
// Mac (DEBUG demo mode, tests). The real implementation is HuskeSync itself:
// `SyncSession` and `MacPresenceMonitor` conform as-is.

import Foundation
import HuskeSync
import Network
import UIKit

protocol MacConnecting: Sendable {
    /// Finds the Mac itself (its own Bonjour browse). Only used when there is
    /// no presence source to say where the Mac is.
    func connect(timeout: TimeInterval) async throws -> any MacSession
    /// Connects to where the presence source saw the Mac: no second browse.
    func connect(to endpoint: NWEndpoint, timeout: TimeInterval) async throws -> any MacSession
    /// The same connector for a pairing this iPhone has not decided to keep
    /// (a new code tried next to one that works, a goodbye): it must not say
    /// which install it is, because the Mac takes that as "this is the
    /// pairing I keep" and removes the install's other entries.
    var asCandidate: any MacConnecting { get }
    /// The additive features this iPhone announces in `hello`.
    var announces: [String] { get }
}

extension MacConnecting {
    func connect(to endpoint: NWEndpoint, timeout: TimeInterval) async throws -> any MacSession {
        try await connect(timeout: timeout)
    }

    /// A connector that never says which install it is.
    var asCandidate: any MacConnecting { self }

    /// A connector that does not say announces nothing.
    var announces: [String] { [] }
}

protocol MacSession: Sendable {
    var welcome: Welcome { get }
    /// How the session reaches the Mac (Wi-Fi, directly…).
    var route: SyncRoute { get }
    func upload(manifest: RecordingManifest, fileURL: URL,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> RemoteStatus
    func status(_ recordingIDs: [String]) async throws -> [RemoteStatus]
    func transcript(_ recordingID: String) async throws -> String?
    /// What the Mac has to read for a recording: its transcript, or — from a
    /// Mac that offers them — the parts it could transcribe (`isPartial`).
    func fetchTranscript(_ recordingID: String) async throws -> FetchedTranscript?
    func close() async
    /// Whether both sides announced `capability` (`SyncCapability`).
    func supports(_ capability: String) -> Bool
    /// Asks the Mac for a key to replace the one this session used
    /// (`SyncCapability.rekey`).
    func rekey() async throws -> DeviceCredential
    /// Tells the Mac to forget this iPhone (`SyncCapability.unpair`).
    func unpair() async throws
}

extension MacSession {
    var route: SyncRoute { .other }

    /// A session that predates capabilities offers none.
    func supports(_ capability: String) -> Bool { false }

    func rekey() async throws -> DeviceCredential {
        throw SyncError.protocolError(code: "unsupported", message: "this session cannot rotate keys")
    }

    func unpair() async throws {
        throw SyncError.protocolError(code: "unsupported", message: "this session cannot unpair")
    }

    /// A session that only knows whole transcripts.
    func fetchTranscript(_ recordingID: String) async throws -> FetchedTranscript? {
        try await transcript(recordingID).map { FetchedTranscript(text: $0) }
    }
}

protocol PresenceSource: AnyObject, Sendable {
    /// Whether it is looking, why it can't, and where the Mac is — the
    /// current value first, then every change.
    var presenceUpdates: AsyncStream<MacPresence> { get }
    func start()
    func stop()
    /// Starts the browse over (fresh queries on every interface); nothing
    /// unless browsing. How a Mac whose peer-to-peer result dropped is found
    /// again.
    func refresh()
}

extension SyncSession: MacSession {}
extension MacPresenceMonitor: PresenceSource {}

/// The production connector: Bonjour + TLS-PSK via HuskeSync.
struct HuskeSyncConnector: MacConnecting {
    let client: SyncClient
    private let pairing: PairedMac
    private let deviceName: String
    private let capabilities: [String]

    /// - Parameters:
    ///   - installID: which install of the app this is (`InstallIdentity`);
    ///     nil announces none.
    ///   - capabilities: the additive features to announce.
    init(pairing: PairedMac, deviceName: String, installID: String? = InstallIdentity.current,
         capabilities: [String] = HuskeSyncConnector.announcedCapabilities) {
        self.pairing = pairing
        self.deviceName = deviceName
        self.capabilities = capabilities
        client = SyncClient(
            pairing: pairing,
            deviceName: deviceName,
            deviceModel: DeviceInfo.modelIdentifier,
            appVersion: DeviceInfo.appVersion,
            installID: installID,
            capabilities: capabilities)
    }

    var asCandidate: any MacConnecting {
        HuskeSyncConnector(pairing: pairing, deviceName: deviceName, installID: nil, capabilities: capabilities)
    }

    var announces: [String] { capabilities }

    /// What this build announces. DEBUG builds can stand in for the app as it
    /// was before a feature, to test against it:
    /// `-HuskeLegacyPeer YES` announces nothing and sends no install ID.
    static var announcedCapabilities: [String] {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HuskeLegacyPeer") { return [] }
        #endif
        return SyncConstants.capabilities
    }

    func connect(timeout: TimeInterval) async throws -> any MacSession {
        try await client.connect(timeout: timeout)
    }

    func connect(to endpoint: NWEndpoint, timeout: TimeInterval) async throws -> any MacSession {
        try await client.connect(to: endpoint, timeout: timeout)
    }
}

enum DeviceInfo {
    /// "iPhone17,1" — the hardware model, for the Mac's device list.
    static let modelIdentifier: String = {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        // The simulator reports the host CPU; use the simulated model instead.
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine
    }()

    static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }()

    /// iOS only reveals the user-assigned name with a special entitlement, so
    /// this is usually the generic "iPhone"; the user can rename it in Settings.
    @MainActor static var systemName: String { UIDevice.current.name }
}
