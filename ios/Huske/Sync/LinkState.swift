// The way to the paired Mac as this iPhone sees it right now: one typed state
// that the Mac screen and the home header render, so "why isn't it syncing"
// always has an answer — Local Network is off, there is no Wi-Fi, still
// looking, the Mac is nearby, connecting, connected (over Wi-Fi or directly),
// or trying again in N s. Pure: derived from what SyncManager observes.

import Foundation
import HuskeSync

enum LinkState: Equatable {
    /// Local Network access is off for Huske, so it cannot look for the Mac
    /// at all. Only the user can change that (Settings).
    case localNetworkOff
    /// Not on Wi-Fi, and the Mac isn't in direct range either.
    case noWiFi
    /// Looking; the Mac hasn't shown up.
    case searching
    /// The Mac is on the network or nearby. Nothing is in flight.
    case visible
    case connecting
    /// A session is open. The route says how.
    case connected(SyncRoute)
    /// The last attempt failed with the Mac still visible; the next one is
    /// scheduled for `at`.
    case retrying(at: Date)
    /// Paired, but not looking (the app is in the background and no sync is
    /// running).
    case paused
    /// The Mac answered and refused this iPhone's key: it was unpaired there.
    /// Trying again won't help; pairing again will.
    case rejected

    /// - Parameters:
    ///   - presence: what the Bonjour browse knows.
    ///   - hasLocalNetwork: on Wi-Fi or Ethernet (nil = not known yet).
    ///   - isConnecting: a pass is opening a connection.
    ///   - route: set while a session is open.
    ///   - retryAt: when the backoff timer fires, if one is running.
    ///   - isRejected: the Mac refused this iPhone's key at the last attempt.
    init(presence: MacPresence, hasLocalNetwork: Bool?, isConnecting: Bool, route: SyncRoute?, retryAt: Date?,
         isRejected: Bool = false) {
        if let route {
            self = .connected(route)
        } else if presence.issue == .localNetworkDenied {
            self = .localNetworkOff
        } else if isRejected, !isConnecting {
            self = .rejected
        } else if presence.isVisible {
            if isConnecting {
                self = .connecting
            } else if let retryAt {
                self = .retrying(at: retryAt)
            } else {
                self = .visible
            }
        } else if isConnecting, !presence.isBrowsing {
            // No browse of our own (demo, tests): the connector finds the Mac.
            self = .connecting
        } else if hasLocalNetwork == false {
            self = .noWiFi
        } else {
            self = presence.isBrowsing ? .searching : .paused
        }
    }

    /// A few plain words for beside the glyph: sentence case, the user's
    /// terms, never the protocol's.
    func label(now: Date = Date()) -> String {
        switch self {
        case .localNetworkOff: return "Local Network access is off"
        case .noWiFi: return "Not on Wi-Fi"
        case .searching: return "Looking for your Mac…"
        case .visible: return "Nearby"
        case .connecting: return "Connecting…"
        case .connected(.wifi): return "Connected over Wi-Fi"
        case .connected(.peerToPeer): return "Connected directly"
        case .connected: return "Connected"
        case let .retrying(at):
            let seconds = Int(at.timeIntervalSince(now).rounded(.up))
            return seconds > 0 ? "Couldn't connect · trying again in \(seconds) s" : "Trying again…"
        case .paused: return "Not looking right now"
        case .rejected: return "Your Mac didn't accept this iPhone"
        }
    }

    /// Shorter words for the home header, where the Mac's name normally
    /// stands; nil when the name itself is the right thing to show.
    var headline: String? {
        switch self {
        case .localNetworkOff: return "Local Network off"
        case .noWiFi: return "Not on Wi-Fi"
        case .rejected: return "Pair again"
        default: return nil
        }
    }

    /// Why nothing is syncing and the way out — nil when the link is fine or
    /// is sorting itself out.
    func explanation(macName: String) -> String? {
        switch self {
        case .localNetworkOff:
            return "Huske can't look for \(macName) while Local Network access is off. Turn it on for Huske in Settings."
        case .noWiFi:
            return "Join the same Wi-Fi as \(macName), or turn Wi-Fi on and keep the two close together. Recordings wait on this iPhone until then."
        case .searching:
            return "Open Huske on \(macName) and keep this iPhone near it."
        case .rejected:
            return "\(macName) didn't accept this iPhone. In Huske on your Mac, open iPhone › Pair iPhone and scan the new code."
        default:
            return nil
        }
    }

    /// The fix is a switch in the Settings app.
    var needsSettings: Bool { self == .localNetworkOff }

    /// The fix is a new pairing code from the Mac.
    var needsPairing: Bool { self == .rejected }

    /// Something the user has to act on (as opposed to waiting).
    var isBlocked: Bool {
        switch self {
        case .localNetworkOff, .noWiFi, .rejected: return true
        default: return false
        }
    }

    /// The Mac can be reached right now.
    var isReachable: Bool {
        switch self {
        case .visible, .connecting, .connected, .retrying: return true
        default: return false
        }
    }

    /// For the support journal: stable, no names.
    var journalText: String {
        switch self {
        case .localNetworkOff: return "local network off"
        case .noWiFi: return "no wifi"
        case .searching: return "searching"
        case .visible: return "mac visible"
        case .connecting: return "connecting"
        case let .connected(route): return "connected (\(route.rawValue))"
        case .retrying: return "retrying"
        case .paused: return "paused"
        case .rejected: return "rejected by the mac"
        }
    }

    func accessibilityLabel(macName: String, now: Date = Date()) -> String {
        switch self {
        case .visible: return "\(macName), nearby"
        case .searching: return "\(macName), not nearby"
        default: return "\(macName), \(label(now: now))"
        }
    }
}

/// How long to wait before trying the Mac again after `failures` attempts in a
/// row failed: 2, 4, 8, 16, 32, then 60 s — each ±20 % so retries don't fall
/// into step with anything else. The count starts over whenever something
/// happens that can cure the link (the Mac appears or changes on Bonjour, the
/// network path changes, the app comes to the front).
enum LinkBackoff {
    static let first: TimeInterval = 2
    static let ceiling: TimeInterval = 60

    /// - Parameter unit: 0…1, where in the ±20 % band to land (injected in tests).
    static func delay(afterFailures failures: Int, jitter unit: Double = .random(in: 0...1)) -> Duration {
        let exponent = Double(min(max(failures - 1, 0), 16))
        let base = min(first * pow(2, exponent), ceiling)
        let jittered = base * (0.8 + 0.4 * min(max(unit, 0), 1))
        return .milliseconds(Int((min(jittered, ceiling) * 1000).rounded()))
    }
}
