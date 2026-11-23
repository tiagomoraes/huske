// Whether paired iPhones can find and reach this Mac right now.
//
// `SyncServerEvent` says what happened; this says where things stand. A
// listener bound to its port is not enough: without a registered advert no
// phone can discover it, which used to read "Ready" while nothing could
// connect. `SyncServer` keeps this state honest by itself — it restarts a
// failed listener with backoff, re-announces an advert the system never
// confirmed or withdrew, and checks again on `recheck(reason:)` (the Mac
// woke, the network changed).

import Foundation
import Network

public enum SyncServerHealth: Sendable, Equatable {
    /// Not started, or stopped.
    case stopped
    /// Binding the port and announcing the Mac. Nothing is wrong (yet).
    case starting
    /// Bound, and — when advertising — the system confirmed the advert, so a
    /// paired phone can discover this Mac.
    case listening(port: UInt16)
    /// The listener is alive but phones cannot discover the Mac.
    case notAdvertising(Reason)
    /// The listener failed and is being rebuilt, with backoff (1 → 30 s).
    case recovering(Reason)

    public enum Reason: Sendable, Equatable {
        /// Local Network access is off for this app (System Settings ›
        /// Privacy & Security › Local Network).
        case localNetworkDenied
        /// There is no network to listen on.
        case noNetwork
        /// The system has not confirmed the advert, or withdrew it.
        case advertNotRegistered
        /// Anything else, as the system reported it. For logs, not people.
        case other(String)

        init(_ error: NWError) {
            if DiscoveryIssue(error) == .localNetworkDenied {
                self = .localNetworkDenied
                return
            }
            if case .posix(let code) = error,
                [.ENETDOWN, .ENETUNREACH, .EHOSTUNREACH, .EADDRNOTAVAIL].contains(code)
            {
                self = .noNetwork
                return
            }
            self = .other("\(error)")
        }
    }

    /// A paired phone can discover and reach this Mac.
    public var isReachable: Bool {
        if case .listening = self { return true }
        return false
    }
}

extension SyncServer {
    /// Looks for this Mac's own advert the way a phone does. true = found,
    /// false = Bonjour answered and it is not there, nil = could not tell
    /// (browsing itself is unavailable), which must not trigger a rebuild.
    static func advertIsVisible(macID: String, timeout: TimeInterval) async -> Bool? {
        do {
            _ = try await BonjourBrowsing.find(macID: macID, timeout: timeout)
            return true
        } catch SyncError.macNotFound {
            return false
        } catch {
            return nil
        }
    }
}
