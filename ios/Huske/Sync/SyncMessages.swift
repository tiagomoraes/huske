// Human sentences for sync failures. Short, specific, and always saying what
// happens next.

import Foundation
import HuskeSync

enum SyncMessages {
    static func text(for error: Error, macName: String) -> String? {
        if error is CancellationError { return nil }
        if let issue = error as? DiscoveryIssue {
            switch issue {
            case .localNetworkDenied:
                return LinkState.localNetworkOff.explanation(macName: macName)
            case .browsingUnavailable:
                return "Can't look for \(macName) right now. Huske will try again."
            }
        }
        guard let syncError = error as? SyncError else {
            return "Sync stopped: \(error.localizedDescription)"
        }
        switch syncError {
        case .macNotFound:
            return "Waiting for \(macName) — open Huske on your Mac."
        case .handshakeFailed:
            return "\(macName) didn't accept this iPhone. Pair again from Huske on your Mac."
        case .connectionClosed:
            return "Lost the connection to \(macName). Huske will try again."
        case .timeout:
            return "\(macName) took too long to answer. Huske will try again."
        case .checksumMismatch:
            return "An upload arrived damaged on \(macName); it will restart from the beginning."
        case .io:
            // Local: the recording's file, not the way to the Mac.
            return "The audio for a recording couldn't be read on this iPhone."
        case .network(.refused):
            // The Mac is there, Huske on it is not listening.
            return "\(macName) isn't accepting connections — open Huske on your Mac."
        case .network:
            return "Couldn't reach \(macName). Huske will try again."
        case let .protocolError(code, message):
            switch code {
            case "version_mismatch":
                return "Huske on \(macName) uses a different sync version. Update Huske on both devices."
            case "wrong_mac":
                return "A different Mac answered than the one you paired. Pair again from Huske on your Mac."
            case "too_large":
                return "This recording is too large to send to \(macName)."
            default:
                return "\(macName) reported a problem: \(message)"
            }
        }
    }

    /// The same for a failure while opening the connection. (Network failures
    /// have their own case now, `SyncError.network`, so this no longer has to
    /// guess what an I/O error meant.)
    static func connectText(for error: Error, macName: String) -> String? {
        text(for: error, macName: macName)
    }

    /// Errors that are about one recording (move on to the next one) rather
    /// than the connection (stop and retry later): the Mac refused this
    /// recording, or its file can't be read here (`.io`). A network failure is
    /// `.network` — never per recording, or one Wi-Fi drop would mark the
    /// whole queue "Couldn't send".
    static func isPerRecording(_ error: Error) -> Bool {
        guard let syncError = error as? SyncError else { return false }
        switch syncError {
        case .io:
            return true
        case let .protocolError(code, _):
            return ["too_large", "bad_request", "unknown_recording"].contains(code)
        case .macNotFound, .handshakeFailed, .connectionClosed, .checksumMismatch, .timeout, .network:
            return false
        }
    }

    /// The Mac answered and refused this iPhone: its key isn't (or is no
    /// longer) accepted there, or it is a different Mac. Pairing again is the
    /// only way out.
    static func isRejection(_ error: Error) -> Bool {
        guard let syncError = error as? SyncError else { return false }
        switch syncError {
        case .handshakeFailed:
            return true
        case let .protocolError(code, _):
            return code == "wrong_mac"
        default:
            return false
        }
    }

    /// Whether trying the same connection again later can help. A rejected
    /// key, a different Mac or a protocol mismatch needs the user instead.
    static func isWorthRetrying(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        guard let syncError = error as? SyncError else { return true }
        switch syncError {
        case .handshakeFailed:
            return false
        case let .protocolError(code, _):
            return !["version_mismatch", "wrong_mac"].contains(code)
        default:
            return true
        }
    }
}
