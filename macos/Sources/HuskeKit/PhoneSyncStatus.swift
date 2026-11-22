// "Why isn't it syncing?", Mac side — the words and decisions behind the
// iPhone pane, kept here (not in the view) so tests can pin them:
//
// - whether a paired iPhone can reach this Mac right now, in the user's terms
//   (DESIGN.md § Quiet instrument: never "Bonjour" or "TLS");
// - when each phone was last in contact;
// - which paired entries are leftovers of a phone that paired again;
// - what to do with a row that still says "Receiving" after the upload went
//   quiet;
// - the text "Copy details" puts on the pasteboard;
// - when to offer "Open Huske at login".

import Foundation
import HuskeSync

// MARK: - can the phone reach this Mac?

public enum PhoneReachability {
    public enum Tone: Sendable, Equatable {
        /// Reachable.
        case ok
        /// Getting there by itself.
        case working
        /// Not reachable until something changes (often something the user does).
        case problem
        /// Receiving is turned off.
        case off
    }

    public struct Line: Sendable, Equatable {
        public var text: String
        /// The reason and the way out, when there is one.
        public var detail: String?
        public var tone: Tone

        public init(text: String, detail: String? = nil, tone: Tone) {
            self.text = text
            self.detail = detail
            self.tone = tone
        }
    }

    static let localNetworkAdvice =
        "Huske isn't allowed on your local network. Turn it on in System Settings › Privacy & Security › Local Network."
    static let noNetworkAdvice =
        "This Mac isn't connected to a network. Your iPhone will find it again as soon as it is."

    /// - Parameters:
    ///   - startError: receiving could not be started at all (the app keeps trying).
    ///   - hasPairedPhone: with none paired there is no "your iPhone" yet.
    public static func line(
        enabled: Bool, health: SyncServerHealth, macName: String,
        hasPairedPhone: Bool = true, startError: String? = nil
    ) -> Line {
        guard enabled else { return Line(text: "Off", tone: .off) }
        let cannotFind = hasPairedPhone ? "Your iPhone can't find this Mac right now" : "An iPhone can't find this Mac right now"
        switch health {
        case .stopped:
            if let startError, !startError.isEmpty {
                return Line(
                    text: "Receiving couldn't start",
                    detail: "\(startError) Huske keeps trying.", tone: .problem)
            }
            return Line(text: "Getting ready…", tone: .working)
        case .starting:
            return Line(text: "Getting ready…", tone: .working)
        case .listening:
            return Line(
                text: hasPairedPhone
                    ? "Your iPhone can reach this Mac as “\(macName)”"
                    : "Ready to pair. An iPhone will find this Mac as “\(macName)”",
                tone: .ok)
        case .notAdvertising(let reason):
            switch reason {
            case .localNetworkDenied:
                return Line(text: cannotFind, detail: localNetworkAdvice, tone: .problem)
            case .noNetwork:
                return Line(text: cannotFind, detail: noNetworkAdvice, tone: .problem)
            case .advertNotRegistered, .other:
                return Line(
                    text: cannotFind,
                    detail: "This Mac isn't showing up on the network yet. Huske keeps announcing it.",
                    tone: .problem)
            }
        case .recovering(let reason):
            switch reason {
            case .localNetworkDenied:
                return Line(text: cannotFind, detail: localNetworkAdvice, tone: .problem)
            case .noNetwork:
                return Line(text: "Getting ready again…", detail: noNetworkAdvice, tone: .working)
            case .advertNotRegistered, .other:
                return Line(
                    text: "Getting ready again…",
                    detail: "Receiving stopped unexpectedly. Huske is starting it again.",
                    tone: .working)
            }
        }
    }

    /// The same state for the diagnostics text, where the technical detail
    /// (the port, the system's own error) is the point.
    public static func technical(_ health: SyncServerHealth) -> String {
        switch health {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .listening(let port): return "listening on port \(port), advert confirmed"
        case .notAdvertising(let reason): return "not advertising (\(technical(reason)))"
        case .recovering(let reason): return "listener down, restarting (\(technical(reason)))"
        }
    }

    private static func technical(_ reason: SyncServerHealth.Reason) -> String {
        switch reason {
        case .localNetworkDenied: return "Local Network access denied"
        case .noNetwork: return "no network"
        case .advertNotRegistered: return "advert not registered"
        case .other(let why): return why
        }
    }
}

// MARK: - paired phones

public enum PhoneContact {
    /// "Connected", "Last seen 2 minutes ago", "Never connected".
    public static func line(lastSeen: Date?, connected: Bool, now: Date = Date()) -> String {
        if connected { return "Connected" }
        guard let lastSeen else { return "Never connected" }
        if now.timeIntervalSince(lastSeen) < 60 { return "Last seen just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        // The interface is English; a localized "há 2 minutos" in the middle
        // of it reads as a bug.
        formatter.locale = Locale(identifier: "en_US")
        return "Last seen " + formatter.localizedString(for: lastSeen, relativeTo: now)
    }

    /// Paired entries that are leftovers of an iPhone that has paired again.
    ///
    /// Nothing in the protocol names "the same phone": every pairing mints a
    /// new device ID and key, and the phone forgets the old ones. So an entry
    /// counts as superseded only on evidence — a newer pairing with the same
    /// name and model, and no contact from the older one ever since. Two
    /// different iPhones that share a name and model both keep talking, and
    /// the older is flagged only until it next connects. So this is a hint,
    /// worded as one: the app says "looks like" and offers Remove; it never
    /// removes a key by guesswork.
    public static func supersededPairings(_ devices: [PairedDevice]) -> Set<String> {
        let paired = devices.filter(\.isPaired)
        var superseded: Set<String> = []
        for older in paired {
            guard let name = older.name, let model = older.model, let olderPairedAt = older.pairedAt
            else { continue }
            let replaced = paired.contains { newer in
                guard newer.deviceID != older.deviceID, newer.name == name, newer.model == model,
                    let newerPairedAt = newer.pairedAt, newerPairedAt > olderPairedAt
                else { return false }
                return (older.lastSeenAt ?? olderPairedAt) < newerPairedAt
            }
            if replaced { superseded.insert(older.deviceID) }
        }
        return superseded
    }
}

// MARK: - uploads that went quiet

/// A row that says "Receiving" is only true while bytes arrive. If the phone
/// walks away, deletes the recording, or Huske relaunches, nothing ever told
/// the row — it sat at "Receiving · 42%" and the menu bar said "arriving"
/// for good.
public enum StaleUpload {
    /// No chunk for this long: not arriving any more.
    public static let quietAfter: TimeInterval = 30

    public enum Verdict: Equatable, Sendable {
        /// Bytes arrived recently; leave the row alone.
        case arriving
        /// The Mac still holds part of it and is waiting for the phone to
        /// come back and resume.
        case waitingForPhone(progress: Double?)
        /// The Mac holds nothing of it any more; the row is a ghost.
        case gone
        /// It finished and moved on while nobody was looking.
        case moved(RemoteStatus)
    }

    /// - Parameters:
    ///   - lastProgress: when its last chunk (or its offer) arrived in this
    ///     run of the app; nil for a row restored from the saved list.
    ///   - server: what `SyncServer.statuses(for:)` says about it now. nil
    ///     when it was not asked (the row is still arriving).
    public static func isQuiet(lastProgress: Date?, now: Date = Date()) -> Bool {
        guard let lastProgress else { return true }
        return now.timeIntervalSince(lastProgress) >= quietAfter
    }

    public static func verdict(lastProgress: Date?, now: Date = Date(), server: RemoteStatus?) -> Verdict {
        guard isQuiet(lastProgress: lastProgress, now: now), let server else { return .arriving }
        switch server.state {
        case .unknown: return .gone
        case .receiving: return .waitingForPhone(progress: server.progress)
        default: return .moved(server)
        }
    }
}

// MARK: - Copy details

public enum PhoneSyncReport {
    public struct Phone: Sendable, Equatable {
        public var name: String
        public var model: String?
        public var lastSeen: Date?
        public var connected: Bool
        public var superseded: Bool

        public init(name: String, model: String?, lastSeen: Date?, connected: Bool, superseded: Bool = false) {
            self.name = name
            self.model = model
            self.lastSeen = lastSeen
            self.connected = connected
            self.superseded = superseded
        }
    }

    /// What "Copy details" puts on the pasteboard: the state of receiving and
    /// the recent log. States and counts only — no recording titles, no
    /// transcript text, no keys.
    public static func text(
        now: Date = Date(), appVersion: String, engineVersion: String?, engineTakesRecordings: Bool,
        enabled: Bool, health: SyncServerHealth, macName: String, openAtLogin: Bool,
        keepingAwake: Bool, phones: [Phone], recordingStates: [RemoteState],
        logTail: String, timeZone: TimeZone = .current
    ) -> String {
        var lines: [String] = []
        lines.append("Huske iPhone sync — \(SyncLog.timestamp(now, timeZone: timeZone))")
        lines.append("App \(appVersion) · engine \(engineVersion ?? "not found")"
            + " · \(engineTakesRecordings ? "takes phone recordings" : "cannot take phone recordings")")
        let reach = PhoneReachability.line(
            enabled: enabled, health: health, macName: macName, hasPairedPhone: !phones.isEmpty)
        lines.append("Receiving: \(enabled ? "on" : "off") · \(reach.text)")
        lines.append("Listener: \(PhoneReachability.technical(health))")
        lines.append("Open at login: \(openAtLogin ? "on" : "off") · keeping the Mac awake: \(keepingAwake ? "yes" : "no")")
        if phones.isEmpty {
            lines.append("Paired iPhones: none")
        } else {
            lines.append("Paired iPhones:")
            for phone in phones {
                let contact = PhoneContact.line(lastSeen: phone.lastSeen, connected: phone.connected, now: now)
                let model = phone.model.map { " (\($0))" } ?? ""
                let note = phone.superseded ? " · looks like an earlier pairing, unused since it paired again" : ""
                lines.append("  \(phone.name)\(model) — \(contact.prefix(1).lowercased() + contact.dropFirst())\(note)")
            }
        }
        lines.append("Recordings: \(summary(of: recordingStates))")
        lines.append("")
        lines.append("Recent activity:")
        let tail = logTail.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(tail.isEmpty ? "(nothing logged yet)" : tail)
        return lines.joined(separator: "\n") + "\n"
    }

    static func summary(of states: [RemoteState]) -> String {
        guard !states.isEmpty else { return "none" }
        let order: [RemoteState] = [.receiving, .received, .queued, .transcribing, .transcribed, .failed, .unknown]
        let parts = order.compactMap { state -> String? in
            let count = states.filter { $0 == state }.count
            return count > 0 ? "\(count) \(state.rawValue)" : nil
        }
        return "\(states.count) (\(parts.joined(separator: ", ")))"
    }
}

// MARK: - Open at login

/// A paired iPhone can only reach this Mac while Huske runs. So once a phone
/// is paired, Huske *offers* to open at login. It never turns it on by
/// itself, and it does not ask again once it is on or the user said no.
public enum LoginItemOffer {
    public static let declinedKey = "huskePhoneLoginOfferDeclined"

    public static func shouldOffer(
        hasPairedPhone: Bool, openAtLogin: Bool, canManageLoginItem: Bool, declined: Bool
    ) -> Bool {
        hasPairedPhone && canManageLoginItem && !openAtLogin && !declined
    }
}

// MARK: - recordings the engine gave up on

/// The iPhone pane's words for a recording the engine gave up on. Some of
/// those still have something to read: a long recording is transcribed in
/// parts, and the parts that worked are kept (`RemoteStatus.partsDone` /
/// `partsTotal`, from `PhoneInbox.remoteStatus`).
public enum PhoneRecordingWords {
    /// Some parts were transcribed, and not all: there is a transcript to
    /// open next to the failure.
    public static func isPartlyTranscribed(partsDone: Int?, partsTotal: Int?) -> Bool {
        guard let partsDone, let partsTotal else { return false }
        return partsDone > 0 && partsDone < partsTotal
    }

    /// "Partly transcribed · 2 of 3 parts", or "Couldn't transcribe" when
    /// nothing of it was (or the engine did not say how much).
    public static func failed(partsDone: Int?, partsTotal: Int?) -> String {
        guard isPartlyTranscribed(partsDone: partsDone, partsTotal: partsTotal),
            let partsDone, let partsTotal
        else { return "Couldn't transcribe" }
        return "Partly transcribed · \(partsDone) of \(partsTotal) parts"
    }

    /// The parts of `status` to keep with the pane's row: both counts for a
    /// partly transcribed recording, nothing otherwise (a retry that works
    /// must not leave "2 of 3" behind).
    public static func parts(of status: RemoteStatus) -> (done: Int, total: Int)? {
        guard status.state == .failed, status.partial == true,
            isPartlyTranscribed(partsDone: status.partsDone, partsTotal: status.partsTotal),
            let done = status.partsDone, let total = status.partsTotal
        else { return nil }
        return (done, total)
    }
}
