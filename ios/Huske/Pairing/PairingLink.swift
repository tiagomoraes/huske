// Glue between the three ways a pairing link reaches the app (system Camera →
// `onOpenURL`, the in-app QR scanner, "Paste pairing link") and HuskeSync's
// parser. The format itself (`huske://pair?v=1&mac=…&name=…&id=…&key=…`) is
// owned by HuskeSync's `PairingInvite`.

import Foundation
import HuskeSync

enum PairingLink {
    enum Outcome: Equatable {
        case invite(PairingInvite)
        /// A `huske://pair` link that doesn't parse: truncated, a different
        /// protocol version, or a bad key.
        case invalid
        /// Parses, but the Mac's 10-minute window has passed.
        case expired
        /// Not a pairing link at all.
        case notPairingLink

        var invite: PairingInvite? {
            if case let .invite(invite) = self { return invite }
            return nil
        }
    }

    /// Clocks on the phone and the Mac can disagree a little; only call a
    /// link expired once it is clearly past its window.
    static let clockSkewTolerance: TimeInterval = 120

    static func parse(url: URL, now: Date = .now) -> Outcome {
        guard isPairingURL(url) else { return .notPairingLink }
        return checked(PairingInvite(url: url), now: now)
    }

    private static func checked(_ invite: PairingInvite?, now: Date) -> Outcome {
        guard let invite else { return .invalid }
        if invite.isExpired(now: now.addingTimeInterval(-clockSkewTolerance)) { return .expired }
        return .invite(invite)
    }

    /// Accepts a bare link or one embedded in surrounding text (a message,
    /// a note) — what "Paste pairing link" and the QR scanner hand us.
    static func parse(text: String, now: Date = .now) -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard containsPairingLink(trimmed) else { return .notPairingLink }
        let invite = PairingInvite(string: trimmed)
            ?? linkWithoutTrailingPunctuation(in: trimmed).flatMap(PairingInvite.init(string:))
        return checked(invite, now: now)
    }

    /// A link copied out of a sentence brings the sentence's punctuation
    /// ("…key=AbC.", "…key=AbC”"). The key is the link's last field and is
    /// base64url, so nothing after its last `[A-Za-z0-9_-]` character belongs
    /// to the link. The key must still decode to 32 bytes, so this cannot turn
    /// a damaged key into an accepted one.
    private static func linkWithoutTrailingPunctuation(in text: String) -> String? {
        guard let start = text.range(of: "\(SyncConstants.urlScheme)://pair", options: .caseInsensitive)
        else { return nil }
        var link = text[start.lowerBound...].prefix { !$0.isWhitespace }
        while let last = link.last, !isBase64URLCharacter(last) {
            link = link.dropLast()
        }
        return String(link)
    }

    private static func isBase64URLCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
    }

    static func isPairingURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == SyncConstants.urlScheme && url.host?.lowercased() == "pair"
    }

    static func containsPairingLink(_ text: String) -> Bool {
        text.lowercased().contains("\(SyncConstants.urlScheme)://pair")
    }

    static func message(for outcome: Outcome) -> String? {
        switch outcome {
        case .invite: return nil
        case .invalid:
            return "This pairing link is incomplete or from a different version of Huske. Make a new one on your Mac."
        case .expired:
            return "This pairing code has expired. On your Mac, open Huske → iPhone → Pair iPhone to show a new one."
        case .notPairingLink:
            return "That isn't a Huske pairing link. On your Mac, open Huske → iPhone → Pair iPhone and copy the link."
        }
    }
}
