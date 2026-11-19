// A thin seam over HuskeSync's client so SyncManager can run against a fake
// Mac (DEBUG demo mode, tests). The real implementation is HuskeSync itself:
// `SyncSession` and `MacPresenceMonitor` conform as-is.

import Foundation
import HuskeSync
import UIKit

protocol MacConnecting: Sendable {
    func connect(timeout: TimeInterval) async throws -> any MacSession
}

protocol MacSession: Sendable {
    var welcome: Welcome { get }
    func upload(manifest: RecordingManifest, fileURL: URL,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> RemoteStatus
    func status(_ recordingIDs: [String]) async throws -> [RemoteStatus]
    func transcript(_ recordingID: String) async throws -> String?
    func close() async
}

protocol PresenceSource: AnyObject, Sendable {
    var updates: AsyncStream<Bool> { get }
    func start()
    func stop()
}

extension SyncSession: MacSession {}
extension MacPresenceMonitor: PresenceSource {}

/// The production connector: Bonjour + TLS-PSK via HuskeSync.
struct HuskeSyncConnector: MacConnecting {
    let client: SyncClient

    init(pairing: PairedMac, deviceName: String) {
        client = SyncClient(
            pairing: pairing,
            deviceName: deviceName,
            deviceModel: DeviceInfo.modelIdentifier,
            appVersion: DeviceInfo.appVersion)
    }

    func connect(timeout: TimeInterval) async throws -> any MacSession {
        try await client.connect(timeout: timeout)
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
