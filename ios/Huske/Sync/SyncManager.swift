// Moves finished recordings to the paired Mac and brings transcripts back.
//
// One run = connect → upload pending recordings one at a time, oldest first →
// poll `status` for uploaded ones until terminal → fetch each transcript once.
// Runs are serialized; a trigger during a run just asks for another pass.
//
// The link to the Mac is supervised by events, not by a timer. One Bonjour
// browse (the presence source) says where the Mac is; a pass connects straight
// to that endpoint, and is not attempted at all while the Mac isn't visible.
// A browse that can't see the Mac is started over every 15 s while it runs:
// a peer-to-peer result that dropped (iPhone off Wi-Fi) only comes back on a
// fresh one. What starts sync again: the Mac appears or is seen another way, the network
// path changes, the app comes to the front. Only a failure with the Mac still
// visible is retried on a clock — 2 s doubling to 60 s, with jitter — and
// each of those events resets it. `link` is that state for the UI; `journal`
// keeps the last ~200 events for support.
//
// Triggers: a recording was saved, the events above, "Sync now", pairing, and
// BGTaskScheduler tasks. A recording still being recorded is never uploaded
// (only `.complete` captures qualify). Bonjour (with peer-to-peer) and the
// network path are watched only while the app is on screen or a pass is
// running.

import Foundation
import HuskeSync
import Network
import Observation
import OSLog
import UIKit

private let log = Logger(subsystem: "cloud.tiagomoraes.huske.ios", category: "sync")

@MainActor
@Observable
final class SyncManager {
    enum Activity: Equatable {
        case idle
        case connecting
        case uploading(recordingID: String, fraction: Double)
        case checking
    }

    enum Trigger: String {
        case recordingSaved, macAppeared, appActive, manual, pairing, background, retry
        /// The Mac is still visible, but seen another way (Wi-Fi ↔ direct).
        case macChanged
        /// The network path changed (joined or left Wi-Fi).
        case networkChanged
        /// The backoff timer after a failed pass (keeps the last error shown).
        case scheduledRetry
    }

    // MARK: observable state

    private(set) var pairedMac: PairedMac?
    private(set) var isMacReachable = false
    private(set) var activity: Activity = .idle { didSet { linkInputsChanged() } }
    private(set) var lastSyncAt: Date?
    /// The latest connection-level problem, phrased for people. Cleared by
    /// the next successful contact.
    private(set) var lastError: String?
    /// From `welcome`: whether the Mac has a transcription engine set up.
    private(set) var engineAvailable: Bool?
    /// True once the Mac answered `hello` for this pairing (the pending slot
    /// on the Mac is now a paired device).
    private(set) var hasConfirmedPairing = false
    /// What the Bonjour browse knows: whether it is looking, why it can't,
    /// and where the Mac is.
    private(set) var macPresence = MacPresence() { didSet { linkInputsChanged() } }
    /// The network this iPhone is on (nil while not watched or not yet known).
    private(set) var networkPath: NetworkPath? { didSet { linkInputsChanged() } }
    /// How the open session reaches the Mac; nil when none is open.
    private(set) var route: SyncRoute? { didSet { linkInputsChanged() } }
    /// When the backoff timer tries again; nil when none is running.
    private(set) var retryAt: Date? { didSet { linkInputsChanged() } }
    /// The Mac answered and refused this iPhone's key (unpaired there, or a
    /// different Mac answered). Only pairing again clears it.
    private(set) var isRejected = false { didSet { linkInputsChanged() } }

    /// The way to the Mac right now, for the Mac screen and the home header.
    var link: LinkState {
        LinkState(presence: macPresence, hasLocalNetwork: networkPath?.hasLocalNetwork,
                  isConnecting: activity == .connecting, route: route, retryAt: retryAt,
                  isRejected: isRejected)
    }

    /// The name this iPhone reports to the Mac.
    var deviceName: String {
        didSet { defaults.set(deviceName, forKey: Keys.deviceName) }
    }

    /// What this iPhone calls the paired Mac ("Office iMac"), as typed; empty
    /// means the Mac's own name. Kept per Mac, so pairing the same Mac again
    /// keeps it, and the Mac's `welcome` never overwrites it (that only
    /// updates the Mac's own name, `macOwnName`).
    var macNickname: String {
        get { pairedMac.flatMap { macNicknames[$0.macID] } ?? "" }
        set {
            guard let mac = pairedMac else { return }
            let typed = String(newValue.prefix(Self.macNicknameLimit))
            macNicknames[mac.macID] = typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : typed
        }
    }

    static let macNicknameLimit = 60

    /// Names given on this iPhone, by Mac ID.
    private var macNicknames: [String: String] {
        didSet { defaults.set(macNicknames, forKey: Keys.macNicknames) }
    }

    var isPaired: Bool { pairedMac != nil }
    var isRunning: Bool { runTask != nil }
    /// The paired Mac as the person knows it: their name for it, else its own.
    var macName: String { pairedMac.map(displayName(of:)) ?? "your Mac" }
    /// The name the paired Mac gives itself, whatever this iPhone calls it.
    var macOwnName: String? { pairedMac?.macName }

    func displayName(of mac: PairedMac) -> String {
        name(forMacID: mac.macID, fallback: mac.macName)
    }

    /// The name to show for the Mac `macID`: what this iPhone calls it, else
    /// `fallback` (its own name, from a pairing code or its last `welcome`).
    func name(forMacID macID: String, fallback: String) -> String {
        let nickname = macNicknames[macID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return nickname.isEmpty ? fallback : nickname
    }

    /// Live upload fraction for the recording being sent right now.
    func uploadFraction(for recordingID: String) -> Double? {
        if case let .uploading(id, fraction) = activity, id == recordingID { return fraction }
        return nil
    }

    func badge(for recording: Recording) -> SyncBadge {
        SyncBadge(recording: recording, isPaired: isPaired, uploadFraction: uploadFraction(for: recording.id))
    }

    /// Why a finished recording hasn't gone to the Mac yet, in one sentence.
    var waitingLine: String {
        if let lastError { return lastError }
        if link.isBlocked, let why = link.explanation(macName: macName) { return why }
        return isMacReachable ? "Ready to send to \(macName)." : "Waiting for \(macName). Open Huske on your Mac."
    }

    /// Recordings waiting to go to the Mac (for the Mac screen).
    var pendingUploadCount: Int {
        guard let macID = pairedMac?.macID else { return 0 }
        return library.recordings.filter { $0.needsUpload(to: macID) }.count
    }

    // MARK: dependencies

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let pairingStore: PairingStoring
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeConnector: (PairedMac, String) -> any MacConnecting
    @ObservationIgnored private let makePresence: (PairedMac) -> (any PresenceSource)?
    @ObservationIgnored private let retryDelay: (Int) -> Duration
    @ObservationIgnored private let backgroundPollingWindow: TimeInterval
    @ObservationIgnored private let applicationIsInBackground: @MainActor () -> Bool
    @ObservationIgnored private let makePathSource: () -> (any NetworkPathSource)?
    @ObservationIgnored private let discoveryWait: Duration
    /// How often a running browse that can't see the Mac is started over
    /// (`lookAgainWhileUnseen`).
    @ObservationIgnored private let lookAgainInterval: Duration
    @ObservationIgnored private var lookAgainTask: Task<Void, Never>?
    @ObservationIgnored private let now: () -> Date
    /// What sync did and why, for "Copy details" (no audio, no transcript text).
    @ObservationIgnored let journal: SyncJournal
    @ObservationIgnored private var presence: (any PresenceSource)?
    @ObservationIgnored private var presenceTask: Task<Void, Never>?
    @ObservationIgnored private var pathSource: (any NetworkPathSource)?
    @ObservationIgnored private var pathTask: Task<Void, Never>?
    /// Passes waiting for the browse to find the Mac.
    @ObservationIgnored private var sightingWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var journaledLink: String?
    /// A session `pair(with:)` already opened, for the next pass to use
    /// instead of connecting again.
    @ObservationIgnored private var adoptedSession: (any MacSession)?
    /// "Forget this Mac" telling the Mac, after this iPhone already forgot.
    @ObservationIgnored private(set) var goodbye: Task<Void, Never>?
    /// The upload in flight, so deleting its recording can stop it.
    @ObservationIgnored private var transfer: (id: String, task: Task<RemoteStatus, Error>)?
    @ObservationIgnored private var isBrowsing = false
    @ObservationIgnored private var activeObserver: NSObjectProtocol?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var rerunRequested = false
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var consecutiveFailures = 0
    /// `pair(with:)` waiting for the new Mac's first answer.
    @ObservationIgnored private var confirmationWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var isForeground = true
    /// The app came to the front and no pass has yet asked the Mac about the
    /// recordings it had given up on (`wasGivenUpOn`).
    @ObservationIgnored private var failureCheckDue = false
    @ObservationIgnored private var backgroundPollingDeadline = Date.distantPast
    @ObservationIgnored private var lastProgressPush = Date.distantPast
    #if DEBUG
    /// Demo mode: never touch the network; states are set by DemoData.
    @ObservationIgnored var isFrozenForDemo = false
    #endif

    private enum Keys {
        static let deviceName = "sync.deviceName"
        static let macNicknames = "sync.macNicknames"
        static let lastSyncAt = "sync.lastSyncAt"
        static let confirmedMacID = "sync.confirmedMacID"
        /// What the Mac announced in its last `welcome` (for "Forget this
        /// Mac": whether it can be told).
        static let macCapabilities = "sync.macCapabilities"
    }

    init(library: LibraryStore,
         pairingStore: PairingStoring,
         defaults: UserDefaults = .standard,
         defaultDeviceName: String,
         makeConnector: @escaping (PairedMac, String) -> any MacConnecting = { HuskeSyncConnector(pairing: $0, deviceName: $1) },
         makePresence: @escaping (PairedMac) -> (any PresenceSource)? = { MacPresenceMonitor(macID: $0.macID) },
         retryDelay: @escaping (Int) -> Duration = SyncManager.retryDelay(afterFailures:),
         backgroundPollingWindow: TimeInterval = 20,
         applicationIsInBackground: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .background },
         makePathSource: @escaping () -> (any NetworkPathSource)? = { SystemNetworkPath() },
         discoveryWait: Duration = .seconds(8),
         lookAgainInterval: Duration = .seconds(15),
         journal: SyncJournal? = nil,
         now: @escaping () -> Date = Date.init) {
        self.library = library
        self.makePathSource = makePathSource
        self.discoveryWait = discoveryWait
        self.lookAgainInterval = lookAgainInterval
        self.journal = journal ?? SyncJournal()
        self.now = now
        self.retryDelay = retryDelay
        self.backgroundPollingWindow = backgroundPollingWindow
        self.applicationIsInBackground = applicationIsInBackground
        self.pairingStore = pairingStore
        self.defaults = defaults
        self.makeConnector = makeConnector
        self.makePresence = makePresence
        deviceName = defaults.string(forKey: Keys.deviceName) ?? defaultDeviceName
        macNicknames = (defaults.dictionary(forKey: Keys.macNicknames) as? [String: String]) ?? [:]
        lastSyncAt = defaults.object(forKey: Keys.lastSyncAt) as? Date
        pairedMac = pairingStore.load()
        if let mac = pairedMac {
            hasConfirmedPairing = defaults.string(forKey: Keys.confirmedMacID) == mac.macID
            startPresence(for: mac)
        }
        // Launched into the background (Action button, Shortcuts, a BGTask),
        // SwiftUI reports no scene phase: don't behave as if on screen. Checked
        // once the app is running; `didBecomeActive` covers the way back.
        Task { @MainActor [weak self] in
            guard let self, self.applicationIsInBackground() else { return }
            self.isForeground = false
            self.updatePresenceBrowsing()
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isForeground else { return }
                self.scenePhaseChanged(isActive: true)
            }
        }
    }

    // MARK: triggers

    /// Kicks off a sync pass (or queues another pass if one is running).
    @discardableResult
    func syncNow(_ trigger: Trigger) -> Task<Void, Never>? {
        guard pairedMac != nil else { return nil }
        #if DEBUG
        if isFrozenForDemo { return nil }
        #endif
        if trigger == .manual || trigger == .retry { lastError = nil }
        if trigger == .manual { consecutiveFailures = 0 }
        if let runTask {
            rerunRequested = true
            return runTask
        }
        cancelScheduledRetry()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let failure = await self.runWithBackgroundTime(trigger)
            self.runTask = nil
            self.resumeConfirmationWaiters()
            // A pass asked for meanwhile runs now — unless this one ended on
            // something only the user can fix (the Mac refused this iPhone):
            // knocking again at once would just be refused again.
            let queued = self.rerunRequested
            self.rerunRequested = false
            if queued, failure.map(SyncMessages.isWorthRetrying) ?? true {
                self.syncNow(.retry)
            } else {
                self.scheduleRetryIfNeeded(after: failure)
            }
            self.updatePresenceBrowsing()
        }
        runTask = task
        updatePresenceBrowsing()
        return task
    }

    /// 2 s doubling to 60 s, each ±20 % (`LinkBackoff`).
    nonisolated static func retryDelay(afterFailures failures: Int) -> Duration {
        LinkBackoff.delay(afterFailures: failures)
    }

    /// A recording just stopped: send it right away, with background time so
    /// leaving the app (or locking) doesn't cut the upload short.
    func recordingSaved(_ recordingID: String) {
        guard pairedMac != nil else { return }
        syncNow(.recordingSaved)
        scheduleBackgroundSyncIfNeeded()
    }

    func scenePhaseChanged(isActive: Bool) {
        isForeground = isActive
        updatePresenceBrowsing()
        if isActive {
            // Once per visit, the next pass also asks about recordings the
            // Mac had given up on — whichever event starts it (this one, or
            // the Mac appearing on the browse that just restarted).
            failureCheckDue = true
            // A fresh start: don't sit out a backoff from before the app
            // left. (If the Mac isn't visible yet, the browse that just
            // restarted starts the pass when it finds it.)
            linkEvent(.appActive)
        } else {
            // Background tasks take over from the foreground retry timer.
            cancelScheduledRetry()
            backgroundPollingDeadline = Date().addingTimeInterval(backgroundPollingWindow)
            scheduleBackgroundSyncIfNeeded()
        }
    }

    /// Clears a recording's failure (or asks the Mac again about a remote
    /// failure) and syncs.
    func retry(_ recordingID: String) {
        library.update(recordingID) { recording in
            recording.sync.failure = nil
            recording.sync.attempts = 0
            if recording.sync.remote?.stage == .failed {
                // The Mac gave up on it. Offering it again is how the phone
                // asks for another try: the Mac still has the audio, queues
                // it again and says so, and polling resumes
                // (sync-protocol.md § Retrying).
                recording.sync.remote = nil
                recording.sync.uploadedAt = nil
            }
        }
        journal.record(.upload, "\(SyncJournal.shortID(recordingID)): retry asked")
        syncNow(.retry)
    }

    /// Runs one pass for a BGTask; returns when done or cancelled.
    func runBackgroundPass() async {
        // Launched straight into the background, the scene never reported a
        // phase: don't poll as if the app were on screen.
        if applicationIsInBackground() { isForeground = false }
        backgroundPollingDeadline = Date().addingTimeInterval(backgroundPollingWindow)
        guard let task = syncNow(.background) else { return }
        // The BGTask's expiration handler cancels the caller; end the run with
        // it so the task is completed before the system's deadline.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancelRun() {
        runTask?.cancel()
    }

    // MARK: pairing

    enum PairingResult: Equatable {
        case paired
        case savedButNotReached(String)
        case failed(String)
    }

    /// What the pairing screen says when the Mac refused the code.
    static let codeRejectedMessage = "This code didn't work — make a new one on your Mac."

    func pair(with invite: PairingInvite) async -> PairingResult {
        // Stop the current pass *and* any pass it queued: a queued pass would
        // otherwise start against the old Mac while this one is saved.
        await stopRuns()
        let mac = PairedMac(invite: invite)
        // With a pairing in place, the new key is only a candidate until its
        // Mac answers: a code the Mac no longer accepts (expired, used, made
        // by a Mac that isn't there) must not cost the pairing that works.
        if let current = pairedMac {
            return await replacePairing(current, with: mac)
        }
        do {
            try pairingStore.save(mac)
        } catch {
            return .failed(error.localizedDescription)
        }
        // Everything not yet transcribed that another Mac held goes to this
        // one — also after "Forget this Mac", when there is no previous pairing.
        library.updateAll(where: {
            $0.transcript == nil && $0.sync.macID != nil && $0.sync.macID != mac.macID
        }) { recording in
            recording.sync = SyncRecord()
        }
        stopPresence()
        pairedMac = mac
        hasConfirmedPairing = false
        defaults.removeObject(forKey: Keys.confirmedMacID)
        engineAvailable = nil
        lastError = nil
        isRejected = false
        consecutiveFailures = 0
        journal.record(.pairing, "paired; waiting for the mac to confirm")
        startPresence(for: mac)
        // First contact promotes the Mac's pending slot to a paired device.
        // Return as soon as the Mac answers (or the attempt ends); the backlog
        // keeps syncing afterwards instead of holding the pairing screen.
        if syncNow(.pairing) != nil, !hasConfirmedPairing {
            await withCheckedContinuation { continuation in
                if hasConfirmedPairing || runTask == nil {
                    continuation.resume()
                } else {
                    confirmationWaiters.append(continuation)
                }
            }
        }
        if hasConfirmedPairing { return .paired }
        if isRejected {
            // The Mac refused the code: there is nothing to keep, and nothing
            // to tell it.
            journal.record(.pairing, "the mac refused the code; not kept")
            forgetMac(tellingMac: false)
            return .failed(Self.codeRejectedMessage)
        }
        // Say why, when the reason is this iPhone (Local Network off, no Wi-Fi).
        let blocked = link.isBlocked ? link.explanation(macName: displayName(of: mac)) : nil
        return .savedButNotReached(
            lastError ?? blocked ?? "Waiting for \(displayName(of: mac)) — open Huske on your Mac.")
    }

    /// Tries `candidate` against its Mac while `current` stays paired, and
    /// switches only once that Mac has answered.
    private func replacePairing(_ current: PairedMac, with candidate: PairedMac) async -> PairingResult {
        journal.record(.pairing, "trying a new code; the current pairing stays until the mac accepts it")
        let kept = "\(displayName(of: current)) stays paired."
        let session: any MacSession
        do {
            session = try await contact(candidate, sameMacAs: current)
        } catch {
            journal.record(.pairing, "new code not accepted: \(String(describing: error))")
            // Back to the pairing that works.
            syncNow(.retry)
            if SyncMessages.isRejection(error) {
                return .failed("\(Self.codeRejectedMessage) \(kept)")
            }
            let why: String
            if let issue = error as? DiscoveryIssue, issue == .localNetworkDenied {
                why = LinkState.localNetworkOff.explanation(macName: displayName(of: candidate)) ?? ""
            } else {
                why = "Couldn't reach \(displayName(of: candidate)) to confirm the code — open Huske there and try again."
            }
            return .failed("\(why) \(kept)")
        }
        // A pass with the old key may have started meanwhile.
        await stopRuns()
        do {
            try pairingStore.save(candidate)
        } catch {
            await session.close()
            syncNow(.retry)
            return .failed(error.localizedDescription)
        }
        library.updateAll(where: {
            $0.transcript == nil && $0.sync.macID != nil && $0.sync.macID != candidate.macID
        }) { recording in
            recording.sync = SyncRecord()
        }
        stopPresence()
        pairedMac = candidate
        hasConfirmedPairing = false
        engineAvailable = nil
        lastError = nil
        isRejected = false
        consecutiveFailures = 0
        startPresence(for: candidate)
        didConnect(session.welcome, macID: candidate.macID)
        journal.record(.pairing, "paired; the mac accepted the new code")
        // The backlog goes out over the session that is already open.
        adoptedSession = session
        if syncNow(.pairing) == nil {
            adoptedSession = nil
            await session.close()
        }
        return .paired
    }

    /// Opens a session with `candidate`'s key without touching the current
    /// pairing. Looks for the Mac on the browse that is already running when
    /// it is the same Mac, on a short one of its own otherwise.
    private func contact(_ candidate: PairedMac, sameMacAs current: PairedMac) async throws -> any MacSession {
        // Only a try: the pairing in place is still the one this iPhone
        // keeps, so the Mac is not told which install this is (it would
        // remove the entry of the pairing that still works).
        let connector = makeConnector(candidate, deviceName).asCandidate
        if candidate.macID == current.macID, presence != nil {
            updatePresenceBrowsing()
            guard let endpoint = await waitForMac(upTo: discoveryWait) else {
                throw macPresence.issue ?? SyncError.macNotFound
            }
            return try await connector.connect(to: endpoint, timeout: 8)
        }
        guard candidate.macID != current.macID, let scout = makePresence(candidate) else {
            // No presence source (demo, tests): the connector finds the Mac.
            return try await connector.connect(timeout: 8)
        }
        scout.start()
        defer { scout.stop() }
        let search = Task { @MainActor () -> MacPresence? in
            for await sighting in scout.presenceUpdates
            where sighting.isVisible || sighting.issue == .localNetworkDenied {
                return sighting
            }
            return nil
        }
        let limit = discoveryWait
        let timeout = Task {
            try? await Task.sleep(for: limit)
            search.cancel()
        }
        let found = await withTaskCancellationHandler {
            await search.value
        } onCancel: {
            search.cancel()
        }
        timeout.cancel()
        guard let endpoint = found?.endpoint else {
            throw found?.issue ?? SyncError.macNotFound
        }
        return try await connector.connect(to: endpoint, timeout: 8)
    }

    /// Forgets the paired Mac on this iPhone, now and whatever happens next.
    /// - Parameter tellingMac: also ask the Mac to remove this iPhone, when
    ///   it can be reached right now and understands the request. When not,
    ///   the Mac keeps listing this iPhone until it is removed there.
    func forgetMac(tellingMac: Bool = true) {
        let leaving = pairedMac
        // Where the Mac is, read before the browse stops.
        let place = macPresence.endpoint
        let canLook = presence == nil || place != nil
        let macUnderstands = (defaults.stringArray(forKey: Keys.macCapabilities) ?? [])
            .contains(SyncCapability.unpair)
        cancelScheduledRetry()
        rerunRequested = false
        runTask?.cancel()
        stopPresence()
        if pairedMac != nil { journal.record(.pairing, "forgot the mac") }
        pairingStore.clear()
        pairedMac = nil
        hasConfirmedPairing = false
        defaults.removeObject(forKey: Keys.confirmedMacID)
        defaults.removeObject(forKey: Keys.macCapabilities)
        isMacReachable = false
        engineAvailable = nil
        lastError = nil
        isRejected = false
        activity = .idle
        guard tellingMac, let leaving else { return }
        #if DEBUG
        if isFrozenForDemo { return }
        #endif
        if macUnderstands, canLook {
            sayGoodbye(as: leaving, at: place)
        } else {
            journal.record(.pairing, macUnderstands
                ? "the mac isn't nearby, so it wasn't told; it lists this iphone until removed there"
                : "the mac wasn't told (it doesn't take that request); it lists this iphone until removed there")
        }
    }

    // MARK: keys

    /// Connects as `mac` (its `deviceID` and `key`).
    /// - Parameter keeping: this is the pairing the iPhone keeps (false for a
    ///   goodbye, which must not look like one).
    private func connect(as mac: PairedMac, at endpoint: NWEndpoint?, keeping: Bool = true,
                         timeout: TimeInterval = 8) async throws -> any MacSession {
        let connector = keeping ? makeConnector(mac, deviceName) : makeConnector(mac, deviceName).asCandidate
        if let endpoint { return try await connector.connect(to: endpoint, timeout: timeout) }
        return try await connector.connect(timeout: timeout)
    }

    /// Opens a session for the stored pairing. Returns it, and whether it had
    /// to fall back to the earlier key because the Mac turned the new one
    /// away.
    ///
    /// Mid-rotation the pairing holds two keys: the one it paired with and
    /// one the Mac issued that this iPhone has not proven yet (`pending`).
    /// The Mac accepts both until it sees the new one used, and only the new
    /// one afterwards — and the iPhone cannot know which side of that it is
    /// on (the Mac's answer may have been lost). So:
    ///
    /// 1. the new key goes first; if the Mac answers, it is the pairing's key;
    /// 2. only if the Mac *refuses* it is the earlier key tried. If that one
    ///    works, the unproven key is **kept** — only the Mac's next answer to
    ///    `rekey` replaces it (`rotateKey`) — because a connection that
    ///    drops before the Mac's answer reads exactly like a refusal;
    /// 3. if the earlier key is refused too, the new one is tried once more:
    ///    the first attempt may have reached the Mac (which then retired the
    ///    earlier key) with only its answer lost. Refused again, this iPhone
    ///    really was removed on the Mac.
    ///
    /// Any other failure says nothing about keys, and both stay stored. At no
    /// step is a key dropped that the Mac might still come to require.
    private func openSession(
        for mac: PairedMac, at endpoint: NWEndpoint?
    ) async throws -> (session: any MacSession, newKeyRefused: Bool) {
        guard let unproven = mac.usingPending else { return (try await connect(as: mac, at: endpoint), false) }
        let proven = "the new key works; the one from the pairing code is retired"
        do {
            let session = try await connect(as: unproven, at: endpoint)
            store(mac.promotingPending(), replacing: mac, proven)
            return (session, false)
        } catch SyncError.handshakeFailed {
            journal.record(.pairing, "the mac turned the new key away; trying the one it replaces")
        }
        do {
            return (try await connect(as: mac, at: endpoint), true)
        } catch SyncError.handshakeFailed {
            journal.record(.pairing, "the earlier key is refused too; the new one once more")
        }
        let session = try await connect(as: unproven, at: endpoint)
        store(mac.promotingPending(), replacing: mac, proven)
        return (session, false)
    }

    /// Replaces the key the pairing link carried with one the Mac issues over
    /// this session, and proves it at once on a second connection — the Mac
    /// retires the link's key the moment it sees the new one used. Returns
    /// the session to carry on with. Whatever fails, a key the Mac accepts
    /// stays stored: see `openSession`.
    /// - Parameter newKeyRefused: this session runs on the earlier key
    ///   because the Mac turned the unproven one away; ask which is current.
    private func rotateKey(over session: any MacSession, macID: String, at endpoint: NWEndpoint?,
                           newKeyRefused: Bool = false) async -> any MacSession {
        guard let mac = pairedMac, mac.macID == macID, mac.rotatedAt == nil,
              mac.pending == nil || newKeyRefused,
              session.supports(SyncCapability.rekey) else { return session }
        let issued: DeviceCredential
        do {
            issued = try await session.rekey()
        } catch {
            // Not now (the Mac had none to give, the link dropped): the key
            // in use keeps working, and the next pass asks again.
            journal.record(.pairing, "no new key this time: \(String(describing: error))")
            return session
        }
        guard !Task.isCancelled, pairedMac == mac else { return session }
        var waiting = mac
        // The Mac's answer is the only thing that replaces an unproven key:
        // it is the same one again while the Mac still honours it.
        if let held = mac.pending, held.deviceID == issued.deviceID, held.key == issued.key {
            waiting.pending = held
        } else {
            waiting.pending = issued
        }
        if waiting != mac {
            do {
                // Stored before it is used: once the Mac has seen the new key
                // it refuses the old one, so losing it would lock us out.
                try pairingStore.save(waiting)
            } catch {
                journal.record(.pairing, "the new key couldn't be stored, so it isn't used")
                return session
            }
            pairedMac = waiting
        }
        journal.record(.pairing, "the mac issued a new key; proving it")
        let place = endpoint ?? macPresence.endpoint
        guard let unproven = waiting.usingPending, place != nil || presence == nil else { return session }
        do {
            let fresh = try await connect(as: unproven, at: place)
            guard !Task.isCancelled, pairedMac == waiting else {
                await fresh.close()
                return session
            }
            store(waiting.promotingPending(), replacing: waiting,
                  "the new key works; the one from the pairing code is retired")
            await session.close()
            return fresh
        } catch {
            journal.record(.pairing, "the new key isn't proven yet (\(String(describing: error))); it goes first next time")
            return session
        }
    }

    /// Stores `updated` as the pairing, if `expected` is still the one in
    /// place (it may have been forgotten or replaced meanwhile).
    private func store(_ updated: PairedMac, replacing expected: PairedMac, _ note: String) {
        guard pairedMac == expected else { return }
        do {
            try pairingStore.save(updated)
            pairedMac = updated
            journal.record(.pairing, note)
        } catch {
            // Nothing is lost: what is stored still holds a key that works.
            journal.record(.pairing, "the pairing couldn't be updated in the keychain; trying again next time")
        }
    }

    /// "Forget this Mac", the Mac's half: ask it to remove this iPhone. Best
    /// effort and bounded — the iPhone has already forgotten.
    private func sayGoodbye(as mac: PairedMac, at endpoint: NWEndpoint?) {
        goodbye = Task { @MainActor [weak self] in
            guard let self else { return }
            var taskID = UIBackgroundTaskIdentifier.invalid
            taskID = UIApplication.shared.beginBackgroundTask(withName: "huske.unpair") {
                MainActor.assumeIsolated {
                    if taskID != .invalid {
                        UIApplication.shared.endBackgroundTask(taskID)
                        taskID = .invalid
                    }
                }
            }
            defer {
                if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) }
            }
            // Either key may be the one the Mac takes right now.
            for identity in [mac.usingPending, mac].compactMap({ $0 }) {
                do {
                    let session = try await self.connect(as: identity, at: endpoint, keeping: false, timeout: 4)
                    guard session.supports(SyncCapability.unpair) else {
                        await session.close()
                        self.journal.record(.pairing, "the mac wasn't told (it doesn't take that request)")
                        return
                    }
                    try await session.unpair()
                    await session.close()
                    self.journal.record(.pairing, "the mac removed this iphone too")
                    return
                } catch SyncError.handshakeFailed {
                    continue
                } catch {
                    self.journal.record(.pairing, "couldn't tell the mac (\(String(describing: error))); it lists this iphone until removed there")
                    return
                }
            }
            self.journal.record(.pairing, "the mac had already removed this iphone")
        }
    }

    // MARK: presence

    private func startPresence(for mac: PairedMac) {
        guard let monitor = makePresence(mac) else { return }
        presence = monitor
        isBrowsing = false
        if let source = makePathSource() {
            pathSource = source
            pathTask = Task { @MainActor [weak self] in
                for await path in source.updates {
                    guard let self, !Task.isCancelled else { return }
                    self.pathChanged(path)
                }
            }
        }
        updatePresenceBrowsing()
        presenceTask = Task { @MainActor [weak self] in
            for await sighting in monitor.presenceUpdates {
                guard let self, !Task.isCancelled else { return }
                // Only a browsing monitor's word counts, and only while we
                // are looking: the rest are echoes from before a stop().
                guard self.isBrowsing, sighting.isBrowsing else { continue }
                self.presenceChanged(sighting)
            }
        }
    }

    /// The browse has something new to say about the Mac.
    private func presenceChanged(_ new: MacPresence) {
        let old = macPresence
        guard new != old else { return }
        macPresence = new
        isMacReachable = new.isVisible
        if let issue = new.issue, issue != old.issue {
            journal.record(.link, "can't look for the mac: \(String(describing: issue))")
        }
        lookAgainWhileUnseen()
        guard new.isVisible else {
            if old.isVisible, new.isBrowsing {
                journal.record(.link, "mac no longer seen (was via \(old.routes.map(\.rawValue).joined(separator: ", ")))")
            }
            // Nothing to retry against: the browse brings the next attempt.
            if old.isVisible { cancelScheduledRetry() }
            // Nobody finds the Mac while Local Network is off: stop waiting.
            if new.issue == .localNetworkDenied { resumeSightingWaiters() }
            return
        }
        guard !old.isVisible || old.endpoint != new.endpoint || old.routes != new.routes else { return }
        journal.record(.link, "mac seen via \(new.routes.map(\.rawValue).joined(separator: ", "))")
        if sightingWaiters.isEmpty {
            linkEvent(old.isVisible ? .macChanged : .macAppeared)
        } else {
            // A pass is already waiting for exactly this.
            consecutiveFailures = 0
            resumeSightingWaiters()
        }
    }

    /// The network path changed (the first reading only says where we are).
    private func pathChanged(_ new: NetworkPath) {
        let old = networkPath
        guard new != old else { return }
        networkPath = new
        let interfaces = new.interfaces.isEmpty ? "none" : new.interfaces.joined(separator: ", ")
        journal.record(.network, "\(new.hasLocalNetwork ? "on wifi or ethernet" : "not on wifi") (\(interfaces))")
        if old != nil { linkEvent(.networkChanged) }
    }

    /// Something happened that can make the link work again: forget the
    /// backoff and try now.
    private func linkEvent(_ trigger: Trigger) {
        consecutiveFailures = 0
        cancelScheduledRetry()
        // While the Mac isn't visible there is nothing to try: its appearing
        // is the next event.
        if presence == nil || macPresence.isVisible { syncNow(trigger) }
    }

    /// Waits — on the presence browse, not a new one — until the Mac is
    /// visible, `limit` passes, the task is cancelled, or looking is hopeless.
    private func waitForMac(upTo limit: Duration) async -> NWEndpoint? {
        if macPresence.isVisible || macPresence.issue == .localNetworkDenied { return macPresence.endpoint }
        let id = UUID()
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            self?.sightingWaiters.removeValue(forKey: id)?.resume()
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    sightingWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.sightingWaiters.removeValue(forKey: id)?.resume() }
        }
        timeout.cancel()
        return macPresence.endpoint
    }

    private func resumeSightingWaiters() {
        let waiters = sightingWaiters
        sightingWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
    }

    /// While the browse runs but can't see the Mac, start it over every
    /// `lookAgainInterval`. With the iPhone off Wi-Fi (switched off in
    /// Control Center, so only peer-to-peer is left) the Mac's AWDL result
    /// can drop within seconds, and a browse left running doesn't bring it
    /// back; a fresh one does. Only while browsing (on screen, or a pass
    /// running), so a phone in a pocket doesn't keep searching.
    private func lookAgainWhileUnseen() {
        let wanted = isBrowsing && presence != nil && !macPresence.isVisible
            && macPresence.issue != .localNetworkDenied
        guard wanted else {
            lookAgainTask?.cancel()
            lookAgainTask = nil
            return
        }
        guard lookAgainTask == nil else { return }
        let interval = lookAgainInterval
        lookAgainTask = Task { @MainActor [weak self] in
            var announced = false
            while true {
                try? await Task.sleep(for: interval)
                // Cancelled: whoever cancelled has already let go of this task.
                guard let self, !Task.isCancelled else { return }
                guard self.isBrowsing, self.presence != nil, !self.macPresence.isVisible else {
                    self.lookAgainTask = nil
                    return
                }
                if !announced {
                    // Once per absence: the journal keeps only ~200 events.
                    self.journal.record(.link, "mac not seen; starting the browse over every \(interval)")
                    announced = true
                }
                self.presence?.refresh()
            }
        }
    }

    /// Journals each change of `link` once, whichever input caused it.
    private func linkInputsChanged() {
        let text = link.journalText
        guard text != journaledLink else { return }
        journaledLink = text
        journal.record(.link, text)
    }

    private func stopPresence() {
        lookAgainTask?.cancel()
        lookAgainTask = nil
        presenceTask?.cancel()
        presenceTask = nil
        presence?.stop()
        presence = nil
        pathTask?.cancel()
        pathTask = nil
        pathSource?.stop()
        pathSource = nil
        isBrowsing = false
        isMacReachable = false
        macPresence = MacPresence()
        networkPath = nil
        resumeSightingWaiters()
    }

    /// Peer-to-peer browsing costs battery: watch for the Mac only while the
    /// app is on screen or a pass is running (e.g. an upload after a
    /// recording stopped from the Lock Screen) — not through a long
    /// background recording.
    private func updatePresenceBrowsing() {
        guard let presence else { return }
        let wanted = isForeground || runTask != nil
        guard wanted != isBrowsing else { return }
        isBrowsing = wanted
        if wanted {
            presence.start()
            pathSource?.start()
            presenceChanged(MacPresence(isBrowsing: true))
        } else {
            presence.stop()
            pathSource?.stop()
            // Not looking is not seeing; don't wait for the stream to say so.
            presenceChanged(MacPresence())
            // Unknown while not watched; the next reading is not a "change".
            networkPath = nil
        }
    }

    // MARK: the run

    private func hasWork(for macID: String) -> Bool {
        library.recordings.contains {
            $0.needsUpload(to: macID) || $0.awaitsRemote(on: macID) || $0.needsTranscript(from: macID)
        }
    }

    private func runWithBackgroundTime(_ trigger: Trigger) async -> Error? {
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "huske.sync") { [weak self] in
            MainActor.assumeIsolated {
                self?.runTask?.cancel()
                if taskID != .invalid {
                    UIApplication.shared.endBackgroundTask(taskID)
                    taskID = .invalid
                }
            }
        }
        let failure = await run(trigger)
        if taskID != .invalid {
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
        return failure
    }

    /// One pass. Returns the error that cut it short (nil when it finished,
    /// had nothing to do, or was cancelled).
    private func run(_ trigger: Trigger) async -> Error? {
        let adopted = adoptedSession
        adoptedSession = nil
        guard !Task.isCancelled, let mac = pairedMac, adopted.map({ $0.welcome.macID == mac.macID }) ?? true else {
            await adopted?.close()
            return nil
        }
        let macID = mac.macID
        let mustContact = !hasConfirmedPairing || trigger == .manual || trigger == .pairing
        // Coming back to the app is also the moment to ask about recordings
        // the Mac had given up on: they may have been tried again there.
        let askAboutFailures = failureCheckDue
            && library.recordings.contains { $0.wasGivenUpOn(by: macID) }
        guard adopted != nil || mustContact || hasWorkNow(for: macID) || askAboutFailures || rotationOwed
        else { return nil }

        // Where is the Mac? The presence browse already knows; a pass never
        // starts a browse of its own. (No presence source — demo, tests — and
        // the connector finds the Mac itself.)
        var endpoint: NWEndpoint?
        if presence != nil, adopted == nil {
            endpoint = macPresence.endpoint
            if endpoint == nil {
                // On screen, the browse result itself starts the next pass.
                // Wait only when someone is waiting for the answer (Sync now,
                // pairing, a recording just saved) or when this pass is what
                // keeps the browse alive (in the background).
                guard trigger == .manual || trigger == .pairing || trigger == .recordingSaved || !isForeground else {
                    journal.record(.run, "\(trigger.rawValue): not started, the mac isn't visible")
                    return nil
                }
                journal.record(.run, "\(trigger.rawValue): waiting for the mac to appear")
                // A peer-to-peer result that dropped doesn't come back on a
                // browse left running; a fresh one finds the Mac if it's near.
                presence?.refresh()
                endpoint = await waitForMac(upTo: discoveryWait)
                guard !Task.isCancelled, pairedMac?.macID == macID else { return nil }
                guard endpoint != nil else {
                    // Not an error to show: `link` says why the Mac can't be
                    // seen, and stops saying it the moment that changes.
                    let reason: Error = macPresence.issue ?? SyncError.macNotFound
                    journal.record(.run, "gave up: \(String(describing: reason))")
                    scheduleBackgroundSyncIfNeeded()
                    return reason
                }
            }
        }

        activity = .connecting
        log.info("sync run (\(trigger.rawValue, privacy: .public)) connecting to \(mac.macName, privacy: .public)")
        let opened: any MacSession
        var newKeyRefused = false
        let connectStarted = now()
        do {
            if let adopted {
                opened = adopted
            } else {
                // With whichever of the pairing's keys the Mac takes (two
                // while a rotation is under way).
                (opened, newKeyRefused) = try await openSession(for: mac, at: endpoint)
            }
        } catch {
            log.error("connect failed: \(String(describing: error), privacy: .public)")
            activity = .idle
            guard !Task.isCancelled, pairedMac?.macID == macID else { return nil }
            journal.record(.connect, "\(trigger.rawValue): failed after \(milliseconds(since: connectStarted)) ms: \(String(describing: error))")
            if let text = SyncMessages.connectText(for: error, macName: displayName(of: mac)) { lastError = text }
            if SyncMessages.isRejection(error) { isRejected = true }
            scheduleBackgroundSyncIfNeeded()
            return error is CancellationError ? nil : error
        }
        // Forgotten or replaced while connecting: this Mac is no longer ours,
        // and its answer must not confirm the new pairing.
        guard !Task.isCancelled, pairedMac?.macID == macID else {
            await opened.close()
            activity = .idle
            return nil
        }
        didConnect(opened.welcome, macID: macID)
        // The pairing is confirmed; now swap the key that was in the QR code
        // for one that never left the two devices (a no-op once done, and
        // with a Mac that predates it).
        let session = await rotateKey(over: opened, macID: macID, at: endpoint, newKeyRefused: newKeyRefused)
        route = session.route
        log.info("connected: \(session.welcome.macName, privacy: .public) engine=\(session.welcome.engineAvailable)")
        journal.record(.connect, "\(trigger.rawValue): connected in \(milliseconds(since: connectStarted)) ms via \(session.route.rawValue), protocol v\(session.welcome.protocolVersion), engine \(session.welcome.engineAvailable ? "ready" : "not set up")")

        var failure: Error?
        do {
            // Close the session on cancellation so a cancelled pass (re-pairing,
            // forget, background expiry) stops within one request even when
            // the transport's I/O ignores task cancellation, instead of first
            // finishing the whole current upload.
            try await withTaskCancellationHandler {
                try await drive(session, macID: macID)
            } onCancel: {
                Task { await session.close() }
            }
            lastSyncAt = Date()
            defaults.set(lastSyncAt, forKey: Keys.lastSyncAt)
            lastError = nil
            journal.record(.run, "finished")
        } catch {
            log.error("sync run ended: \(String(describing: error), privacy: .public)")
            if !Task.isCancelled, !(error is CancellationError) {
                failure = error
                if let text = SyncMessages.text(for: error, macName: macName) { lastError = text }
                journal.record(.run, "ended: \(String(describing: error))")
            } else {
                journal.record(.run, "cancelled")
            }
        }
        await session.close()
        route = nil
        activity = .idle
        scheduleBackgroundSyncIfNeeded()
        return failure
    }

    private func didConnect(_ welcome: Welcome, macID: String) {
        // Only the Mac we are paired with *now* can confirm the pairing.
        guard pairedMac?.macID == macID else { return }
        isRejected = false
        hasConfirmedPairing = true
        defaults.set(macID, forKey: Keys.confirmedMacID)
        engineAvailable = welcome.engineAvailable
        defaults.set(welcome.capabilities, forKey: Keys.macCapabilities)
        lastError = nil
        if var mac = pairedMac, mac.macID == macID, mac.macName != welcome.macName, !welcome.macName.isEmpty {
            mac.macName = welcome.macName
            try? pairingStore.save(mac)
            pairedMac = mac
        }
        resumeConfirmationWaiters()
    }

    private func drive(_ session: any MacSession, macID: String) async throws {
        var pollDelay: Double = 0
        var checksumRetries: [String: Int] = [:]
        var askedAboutFailures = false

        while true {
            try Task.checkCancellation()
            guard pairedMac?.macID == macID else { return }

            // 1. Uploads, one at a time, oldest first.
            if let next = library.recordings
                .filter({ $0.needsUpload(to: macID) })
                .min(by: { $0.startedAt < $1.startedAt }) {
                do {
                    try await upload(next, over: session, macID: macID)
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    if library.recording(id: next.id) == nil {
                        // Deleted while it was being sent: its upload was
                        // stopped on purpose; go on with the others.
                        journal.record(.upload, "\(SyncJournal.shortID(next.id)): deleted while sending, upload stopped")
                        activity = .connecting
                        continue
                    }
                    if error is CancellationError { throw CancellationError() }
                    try handleUploadFailure(error, of: next.id, checksumRetries: &checksumRetries)
                }
                activity = .connecting
                continue
            }

            // Once per pass: a recording the Mac gave up on is final here, so
            // nothing ever asks about it again — but "Try again" on the Mac
            // may have moved it on (or the Mac may now have parts to hand
            // over). A Mac that no longer knows it is not sent it again
            // unasked: that is what Retry is for.
            if !askedAboutFailures {
                askedAboutFailures = true
                failureCheckDue = false
                let givenUp = library.recordings.filter { $0.wasGivenUpOn(by: macID) }.map(\.id)
                if !givenUp.isEmpty {
                    let answers = try await session.status(givenUp)
                    apply(answers.filter { $0.state != .unknown }, macID: macID)
                }
            }

            // 2. Transcripts that are ready.
            for recording in library.recordings where recording.needsTranscript(from: macID) {
                try Task.checkCancellation()
                // The whole transcript, or — for a recording the Mac gave up
                // on — the parts it did transcribe.
                let fetched = try await session.fetchTranscript(recording.id)
                let outcome = fetched.map { $0.isPartial ? "fetched in part" : "fetched" } ?? "not available"
                log.info("transcript for \(recording.id, privacy: .public): \(fetched?.text.count ?? 0) chars, \(outcome, privacy: .public)")
                journal.record(.transcript, "\(SyncJournal.shortID(recording.id)): \(outcome)")
                library.update(recording.id) {
                    $0.storeFetchedTranscript(fetched?.text, isPartial: fetched?.isPartial ?? false)
                }
            }

            // 3. Poll the Mac until everything uploaded is terminal.
            let waiting = library.recordings.filter { $0.awaitsRemote(on: macID) }
            guard !waiting.isEmpty, shouldKeepPolling else { return }
            // Without an engine nothing on the Mac gets past "received": stop,
            // rather than hold a connection open (and "Sync now" spinning)
            // for as long as the app is on screen. The next pass asks again.
            if engineAvailable == false, waiting.allSatisfy({ $0.sync.remote?.stage == .received }) { return }
            activity = .checking
            let statuses = try await session.status(waiting.map(\.id))
            let readyBefore = library.recordings.filter { $0.needsTranscript(from: macID) }.count
            apply(statuses, macID: macID)
            let readyAfter = library.recordings.filter { $0.needsTranscript(from: macID) }.count
            if readyAfter > readyBefore || library.recordings.contains(where: { $0.needsUpload(to: macID) }) {
                pollDelay = 0
                continue
            }
            let transcribingOnScreen = isForeground && library.recordings.contains {
                $0.awaitsRemote(on: macID) && $0.sync.remote?.stage == .transcribing
            }
            pollDelay = Self.pollDelay(after: pollDelay, transcribingOnScreen: transcribingOnScreen)
            try await Task.sleep(for: .seconds(pollDelay))
        }
    }

    /// A failed upload is either this recording's problem (mark it and move
    /// on to the next one) or the connection's (rethrow: end the pass, retry
    /// later). A network error must never become a sticky per-recording
    /// failure — it would strand every recording queued behind it.
    private func handleUploadFailure(_ error: Error, of id: String, checksumRetries: inout [String: Int]) throws {
        guard let recording = library.recording(id: id) else { return }  // deleted while sending
        if let syncError = error as? SyncError, syncError == .checksumMismatch {
            let count = checksumRetries[id, default: 0] + 1
            checksumRetries[id] = count
            if count >= 2 {
                markFailed(id, "The upload didn't verify on \(macName) twice. The file may be damaged.")
            }
            return
        }
        if case .io? = error as? SyncError {
            // Local: this recording's file could not be read. (The network
            // has its own case, so this is no longer a guess.)
            let missing = !FileManager.default.isReadableFile(atPath: library.audioURL(for: recording).path)
            markFailed(id, missing
                ? "The audio file for this recording is missing on this iPhone."
                : "The audio for this recording couldn't be read on this iPhone.")
            return
        }
        if SyncMessages.isPerRecording(error) {
            markFailed(id, SyncMessages.text(for: error, macName: macName) ?? "Upload failed.")
            return
        }
        journal.record(.upload, "\(SyncJournal.shortID(id)): interrupted: \(String(describing: error))")
        throw error
    }

    private var shouldKeepPolling: Bool {
        isForeground || Date() < backgroundPollingDeadline
    }

    /// Seconds to wait before asking the Mac for `status` again: 2, 3, 4.5…
    /// up to 10 while recordings only wait in line. While the Mac is
    /// transcribing and the app is on screen the answer is moments away, so
    /// it stays at 2.
    nonisolated static func pollDelay(after previous: Double, transcribingOnScreen: Bool) -> Double {
        if transcribingOnScreen || previous <= 0 { return 2 }
        return min(previous * 1.5, 10)
    }

    /// Work a pass can do right now. A recording that only waits for the
    /// Mac's verdict is polled while the app is on screen or inside a
    /// background window; past that a pass would connect, ask nothing and
    /// hang up.
    private func hasWorkNow(for macID: String) -> Bool {
        let canPoll = shouldKeepPolling
        return library.recordings.contains {
            $0.needsUpload(to: macID) || $0.needsTranscript(from: macID)
                || (canPoll && $0.awaitsRemote(on: macID))
        }
    }

    /// The pairing still holds the key its link carried and this Mac can
    /// replace it, or holds one the Mac issued that has not been used yet.
    /// That alone is worth a connection while the Mac is in reach: otherwise
    /// a rotation cut short (the Mac quit between issuing the key and seeing
    /// it used, a pairing an older build made) would leave the link's key
    /// working until the next recording. A Mac known not to rotate keys is
    /// not contacted for it; one this build has not spoken to yet is asked
    /// once, by the pass that learns what it takes.
    private var rotationOwed: Bool {
        guard let mac = pairedMac, !isRejected else { return false }
        let macRotates = defaults.stringArray(forKey: Keys.macCapabilities)
            .map { $0.contains(SyncCapability.rekey) } ?? true
        guard macRotates else { return false }
        if mac.pending != nil { return true }
        return mac.needsRekey && makeConnector(mac, deviceName).announces.contains(SyncCapability.rekey)
    }

    private func upload(_ recording: Recording, over session: any MacSession, macID: String) async throws {
        let fileURL = library.audioURL(for: recording)
        let device = deviceName
        let zone = TimeZone(identifier: recording.timeZoneID) ?? .current
        library.update(recording.id) {
            $0.sync.attempts += 1
            $0.sync.lastAttemptAt = Date()
        }
        activity = .uploading(recordingID: recording.id, fraction: 0)

        // Hashing reads the whole file: keep it off the main actor.
        let manifest: RecordingManifest
        do {
            manifest = try await Task.detached(priority: .userInitiated) {
                try RecordingManifest.make(
                    id: recording.id, title: recording.title, startedAt: recording.startedAt,
                    durationSeconds: recording.duration, fileURL: fileURL,
                    sampleRate: RecorderController.sampleRate, channels: RecorderController.channels,
                    timeZone: zone, deviceName: device)
            }.value
        } catch {
            // The file is gone or unreadable: this recording's problem.
            throw SyncError.io("cannot read the audio file: \(error.localizedDescription)")
        }

        let id = recording.id
        // In a task of its own, so deleting the recording can stop just this
        // upload (HuskeSync stops between chunks) and the pass goes on.
        let sending = Task {
            try await session.upload(manifest: manifest, fileURL: fileURL) { [weak self] sent, total in
                Task { @MainActor in self?.reportProgress(id, sent: sent, total: total) }
            }
        }
        transfer = (id, sending)
        defer { transfer = nil }
        let status = try await withTaskCancellationHandler {
            try await sending.value
        } onCancel: {
            sending.cancel()
        }
        // Deleted during the very last chunk: the Mac has it, the phone doesn't.
        guard library.recording(id: id) != nil else { throw CancellationError() }
        log.info("uploaded \(id, privacy: .public): \(status.state.rawValue, privacy: .public)")
        journal.record(.upload, "\(SyncJournal.shortID(id)): sent \(manifest.byteCount) bytes, now \(status.state.rawValue)")
        library.update(id) {
            $0.sync.macID = macID
            $0.sync.uploadedAt = Date()
            $0.sync.failure = nil
            $0.sync.remote = RemoteSnapshot(status)
        }
    }

    private func reportProgress(_ id: String, sent: Int64, total: Int64) {
        if library.recording(id: id) == nil {
            // Deleted while sending: stop, there is nothing left to offer.
            if transfer?.id == id { transfer?.task.cancel() }
            return
        }
        guard case let .uploading(current, previous) = activity, current == id, total > 0 else { return }
        let fraction = Double(sent) / Double(total)
        let now = Date()
        // Coalesce: ~10 Hz is plenty for a badge.
        guard fraction >= 1 || fraction - previous >= 0.01 || now.timeIntervalSince(lastProgressPush) > 0.1
        else { return }
        lastProgressPush = now
        activity = .uploading(recordingID: id, fraction: fraction)
    }

    private func apply(_ statuses: [RemoteStatus], macID: String) {
        for status in statuses {
            library.update(status.recordingID) { recording in
                guard recording.sync.macID == macID else { return }
                if status.state == .unknown {
                    // The Mac no longer knows it (reset, pruned): send again.
                    recording.sync.uploadedAt = nil
                    recording.sync.remote = nil
                } else {
                    recording.sync.remote = RemoteSnapshot(status)
                }
            }
        }
    }

    private func markFailed(_ id: String, _ message: String) {
        library.update(id) { $0.sync.failure = message }
        // The message can name the Mac; the journal only says that it failed.
        journal.record(.upload, "\(SyncJournal.shortID(id)): marked failed")
    }

    // MARK: stopping, retrying, waiting

    /// Cancels the current pass and any pass it queued, and waits for them.
    private func stopRuns() async {
        cancelScheduledRetry()
        while let task = runTask {
            rerunRequested = false
            task.cancel()
            await task.value
        }
    }

    private func cancelScheduledRetry() {
        retryTask?.cancel()
        retryTask = nil
        retryAt = nil
    }

    /// After a pass that couldn't reach the Mac (or lost it midway), try again
    /// with backoff — only while the app is on screen and the Mac is visible
    /// (otherwise the Mac appearing, the app becoming active and background
    /// tasks restart sync), and never for problems only the user can fix.
    private func scheduleRetryIfNeeded(after failure: Error?) {
        guard let failure else {
            consecutiveFailures = 0
            return
        }
        guard isForeground, isMacReachable, SyncMessages.isWorthRetrying(failure),
              let macID = pairedMac?.macID, hasWork(for: macID) || !hasConfirmedPairing else { return }
        consecutiveFailures += 1
        let delay = retryDelay(consecutiveFailures)
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        log.info("retrying in \(String(describing: delay), privacy: .public)")
        journal.record(.retry, "next attempt in \(String(format: "%.1f", seconds)) s (failed \(consecutiveFailures) in a row)")
        retryAt = now().addingTimeInterval(seconds)
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.retryAt = nil
            self.syncNow(.scheduledRetry)
        }
    }

    private func milliseconds(since start: Date) -> Int {
        Int((now().timeIntervalSince(start) * 1000).rounded())
    }

    /// What "Copy details" puts on the clipboard: versions, the state right
    /// now and the journal. No names, titles, audio or transcript text.
    func diagnosticsReport() -> String {
        let pairing: String
        if !isPaired {
            pairing = "no"
        } else {
            pairing = hasConfirmedPairing ? "yes" : "yes, not confirmed by the Mac yet"
        }
        let engine: String
        switch engineAvailable {
        case true?: engine = "ready"
        case false?: engine = "not set up"
        case nil: engine = "unknown"
        }
        return journal.report(header: [
            "Huske for iPhone \(DeviceInfo.appVersion) · \(DeviceInfo.modelIdentifier) · iOS \(UIDevice.current.systemVersion)",
            "Paired: \(pairing)",
            "Link: \(link.journalText)",
            "Waiting to send: \(pendingUploadCount)",
            "Last sync: \(lastSyncAt.map(SyncJournal.stamp) ?? "never")",
            "Transcription on the Mac: \(engine)",
        ])
    }

    private func resumeConfirmationWaiters() {
        let waiters = confirmationWaiters
        confirmationWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func scheduleBackgroundSyncIfNeeded() {
        guard let macID = pairedMac?.macID, hasWork(for: macID) else { return }
        BackgroundSync.schedule()
    }
}

#if DEBUG
extension SyncManager {
    func setDemoState(reachable: Bool, activity: Activity, lastSyncAt: Date?, engineAvailable: Bool?) {
        isMacReachable = reachable
        macPresence = MacPresence(
            isBrowsing: true, endpoint: reachable ? .hostPort(host: "127.0.0.1", port: 9) : nil,
            routes: reachable ? [.wifi] : [])
        self.activity = activity
        self.lastSyncAt = lastSyncAt
        self.engineAvailable = engineAvailable
        hasConfirmedPairing = true
    }
}
#endif

extension RemoteSnapshot {
    init(_ status: RemoteStatus) {
        self.init(
            stage: RemoteStage(rawValue: status.state.rawValue) ?? .unknown,
            detail: status.detail,
            progress: status.progress,
            updatedAt: status.updatedAt,
            partial: status.partial,
            partsDone: status.partsDone,
            partsTotal: status.partsTotal,
            retrying: status.retrying,
            attempt: status.attempt,
            maxAttempts: status.maxAttempts)
    }
}
