// Human sentences for sync failures. Short, specific, and always saying what
// happens next.

import Foundation
import HuskeSync

enum SyncMessages {
    static func text(for error: Error, macName: String) -> String? {
        if error is CancellationError { return nil }
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
        case let .io(why):
            return "Couldn't send a recording: \(why)"
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

    /// Errors that are about one recording (move on to the next one) rather
    /// than the connection (stop and retry later).
    static func isPerRecording(_ error: Error) -> Bool {
        guard let syncError = error as? SyncError else { return false }
        switch syncError {
        case .io:
            return true
        case let .protocolError(code, _):
            return ["too_large", "bad_request", "unknown_recording"].contains(code)
        default:
            return false
        }
    }
}
