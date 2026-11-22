// Receives recordings from paired iPhones (HuskeSync's SyncServer) and hands
// them to the engine inbox through the CLI — never by writing the inbox
// itself (specs/002-phone-sync/contracts/inbox.md). Reads the engine-owned
// status.json files to answer the phone and to drive the iPhone pane.
//
// Lifecycle: AppModel owns one; `bootstrap()` starts the listener once the
// engine is probed (the setting "Receive recordings from iPhone", default on,
// can turn it off). Nothing happens at init, so the offscreen renderer and
// previews never open sockets or touch Application Support.

import AppKit
import Foundation
import HuskeKit
import HuskeSync
import Observation
import SystemConfiguration
import os

@MainActor
@Observable
final class PhoneSyncCoordinator {
    static let enabledKey = "huskePhoneSyncEnabled"
    /// Recent recordings kept in the pane.
    static let recordingLimit = 50

    /// One phone recording as the pane shows it.
    struct Recording: Identifiable, Equatable, Codable {
        let id: String
        var title: String
        var deviceName: String
        var startedAt: Date
        var durationSeconds: Double
        var byteCount: Int64
        var state: RemoteState
        var progress: Double?
        var detail: String?
        var transcripts: [String]
        var updatedAt: Date
        /// `receiving`, but nothing is arriving: the Mac holds part of it and
        /// is waiting for the phone to come back (optional so lists saved by
        /// earlier versions still load).
        var stalled: Bool?
        /// `failed`, but some of its parts were transcribed and can be read
        /// (optional for the same reason; nil for every other recording).
        var partsDone: Int?
        var partsTotal: Int?

        /// The engine gave up, with some parts transcribed.
        var isPartlyTranscribed: Bool {
            state == .failed && PhoneRecordingWords.isPartlyTranscribed(partsDone: partsDone, partsTotal: partsTotal)
        }

        /// Bytes are arriving right now.
        var isArriving: Bool { state == .receiving && stalled != true }

        init(manifest: RecordingManifest, state: RemoteState, progress: Double? = nil) {
            id = manifest.id
            title = manifest.title
            deviceName = manifest.deviceName
            startedAt = manifest.startedAt
            durationSeconds = manifest.durationSeconds
            byteCount = manifest.byteCount
            self.state = state
            self.progress = progress
            detail = nil
            transcripts = []
            updatedAt = Date()
        }

        init(
            id: String, title: String, deviceName: String, startedAt: Date,
            durationSeconds: Double, byteCount: Int64, state: RemoteState,
            progress: Double? = nil, detail: String? = nil, transcripts: [String] = [],
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.title = title
            self.deviceName = deviceName
            self.startedAt = startedAt
            self.durationSeconds = durationSeconds
            self.byteCount = byteCount
            self.state = state
            self.progress = progress
            self.detail = detail
            self.transcripts = transcripts
            self.updatedAt = updatedAt
        }
    }

    // MARK: observable state

    /// "Receive recordings from iPhone".
    var enabled: Bool =
        (UserDefaults.standard.object(forKey: PhoneSyncCoordinator.enabledKey) as? Bool) ?? true
    {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled { startIfEnabled() } else { stopServer() }
        }
    }

    private(set) var devices: [PairedDevice] = []
    private(set) var recordings: [Recording] = []
    private(set) var isListening = false
    private(set) var listenerError: String?
    /// Whether a paired iPhone can find and reach this Mac right now — the
    /// server's own answer, which also knows whether the advert is up.
    private(set) var health: SyncServerHealth = .stopped
    /// Paired phones with a connection open right now.
    private(set) var connectedDeviceIDs: Set<String> = []
    /// Why receiving could not be started at all (it is retried).
    private(set) var startError: String?
    /// The user turned down "Open Huske at login" for the iPhone's sake.
    private(set) var loginOfferDeclined = UserDefaults.standard.bool(forKey: LoginItemOffer.declinedKey)
    let macName: String

    /// The pane's "can my iPhone reach this Mac?" line.
    var reachability: PhoneReachability.Line {
        PhoneReachability.line(
            enabled: enabled, health: health, macName: macName,
            hasPairedPhone: devices.contains(where: \.isPaired), startError: startError)
    }

    /// Paired entries that are leftovers of an iPhone that paired again.
    var supersededDeviceIDs: Set<String> { PhoneContact.supersededPairings(devices) }

    /// Offer "Open Huske at login" (never turned on silently, never asked
    /// again once on or declined).
    var shouldOfferOpenAtLogin: Bool {
        guard let model else { return false }
        return LoginItemOffer.shouldOffer(
            hasPairedPhone: devices.contains(where: \.isPaired), openAtLogin: model.openAtLogin,
            canManageLoginItem: model.canManageLoginItem, declined: loginOfferDeclined)
    }

    /// The invite on screen in the pairing sheet.
    private(set) var activeInvite: PairingInvite?
    /// Set when the phone holding `activeInvite` says hello.
    private(set) var pairedFromInvite: PairedDevice?
    var pairingSheetVisible = false

    /// Paired (not pending) devices, newest first.
    var pairedDevices: [PairedDevice] {
        devices.filter(\.isPaired).sorted { ($0.pairedAt ?? .distantPast) > ($1.pairedAt ?? .distantPast) }
    }

    /// Recordings still moving (for the menu bar line and the poll cadence).
    /// An upload the phone walked away from is not moving: it waits.
    var activeRecordings: [Recording] {
        recordings.filter { !$0.state.isTerminal && $0.state != .unknown && $0.stalled != true }
    }

    // MARK: plumbing

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var server: SyncServer?
    @ObservationIgnored private var registry: DeviceRegistry?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var processTask: Task<Void, Never>?
    @ObservationIgnored private var processAgain = false
    @ObservationIgnored private var lastProcessEnded: Date?
    @ObservationIgnored private var handOffInFlight: Set<String> = []
    @ObservationIgnored private var lastHandOffAttempt: Date?
    /// When each upload last made progress in this run (StaleUpload).
    @ObservationIgnored private var uploadProgressAt: [String: Date] = [:]
    @ObservationIgnored private var uploadDevice: [String: String] = [:]
    /// Inbox items that failed with attempts left: they want a pass soon.
    @ObservationIgnored private var retryPendingIDs: Set<String> = []
    /// When a phone last asked for a retry of each recording by re-offering it.
    @ObservationIgnored private var reofferRetryAt: [String: Date] = [:]
    @ObservationIgnored private var startRetry: Task<Void, Never>?
    @ObservationIgnored private var handOffChain: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// The Mac does not idle-sleep while a recording is being received or
    /// handed to the engine; an idle Huske never holds it awake.
    @ObservationIgnored private let keepAwake = KeepAwake()
    /// "Why isn't it syncing": a small rotating log, made on first start.
    @ObservationIgnored private var syncLog: SyncLog?
    /// Read from the server's queue (welcome), so it lives outside the actor.
    private nonisolated let engineAvailableFlag = OSAllocatedUnfairLock(initialState: false)
    private let log = Logger(subsystem: "cloud.tiagomoraes.huske", category: "phone-sync")

    init() {
        macName = Self.computerName()
    }

    func attach(model: AppModel) {
        self.model = model
    }

    // MARK: paths

    static func supportDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Huske/PhoneSync", isDirectory: true)
    }

    private var support: URL { Self.supportDirectory() }
    private var stagingDirectory: URL { support.appendingPathComponent("staging", isDirectory: true) }
    /// Verified uploads waiting for an engine that can take them.
    private var pendingDirectory: URL { support.appendingPathComponent("pending", isDirectory: true) }
    private var indexURL: URL { support.appendingPathComponent("recordings.json") }
    /// The sync log ("Show log"); with its one rotated file, under 400 KB.
    static func logURL() -> URL { supportDirectory().appendingPathComponent("sync.log") }

    private var inboxRoot: URL {
        PhoneInbox.root(fromConfigValue: model?.config.snapshot?.string("inbox_root"))
    }

    // MARK: lifecycle

    /// Idempotent; called from AppModel.bootstrap() after every engine probe.
    func startIfEnabled() {
        refreshEngineAvailability()
        guard enabled, !(model?.isDemo ?? false) else { return }
        if registry == nil {
            try? FileManager.default.createDirectory(
                at: support, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            registry = DeviceRegistry(fileURL: support.appendingPathComponent("devices.json"))
            loadIndex()
        }
        if syncLog == nil { syncLog = SyncLog(fileURL: Self.logURL()) }
        guard server == nil, let registry else {
            retryPendingHandOffs()
            return
        }
        let server = SyncServer(
            registry: registry, stagingDirectory: stagingDirectory, macName: macName,
            serverVersion: model?.appVersion ?? "0.0.0")
        server.delegate = self
        let log = self.log
        let syncLog = self.syncLog
        server.logHandler = { message in
            log.info("\(message, privacy: .public)")
            syncLog?.write(message)
        }
        server.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        server.onHealthChange = { [weak self] _ in
            // Read the truth on arrival: these hop queues and can reorder.
            Task { @MainActor in self?.refreshHealth() }
        }
        startRetry?.cancel()
        startRetry = nil
        do {
            try server.start()
            self.server = server
            listenerError = nil
            startError = nil
            refreshHealth()
            // Uploads verified before a quit/crash but never handed off.
            Task { await server.redeliverVerified() }
        } catch {
            listenerError = error.localizedDescription
            startError = error.localizedDescription
            note("receiving could not start: \(error.localizedDescription); trying again in 30 s", isError: true)
            // Nothing else would try again: polling only starts once the
            // server has, and bootstrap() may not run again for days.
            startRetry = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.startRetry = nil
                self.startIfEnabled()
            }
            return
        }
        observeWake()
        reloadDevices()
        startPolling()
        retryPendingHandOffs()
    }

    private func stopServer() {
        startRetry?.cancel()
        startRetry = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        server?.stop()
        server = nil
        isListening = false
        health = .stopped
        startError = nil
        connectedDeviceIDs = []
        uploadProgressAt.removeAll()
        uploadDevice.removeAll()
        // Nothing can arrive any more; do not keep the Mac up for it, and do
        // not leave rows saying "Receiving".
        keepAwake.releaseAll()
        var changed = false
        for index in recordings.indices where recordings[index].isArriving {
            recordings[index].stalled = true
            changed = true
        }
        if changed { saveIndex() }
        pollTask?.cancel()
        pollTask = nil
    }

    private func refreshHealth() {
        guard let server else { return }
        let current = server.health
        if current != health { health = current }
    }

    /// A Mac that slept comes back with a listener that may no longer be
    /// advertised; the server checks, and repairs it if not. (Network changes
    /// are watched by the server itself.)
    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.note("the Mac woke from sleep")
                self.server?.recheck(reason: "woke from sleep")
                self.retryPendingHandOffs()
            }
        }
    }

    /// The user is looking at the pane, or came back to the app (perhaps from
    /// System Settings): check now instead of at the next backoff step.
    func recheckReachability() {
        server?.recheck(reason: "checked from the iPhone pane")
    }

    /// One line for the unified log and the sync log. No titles, no content.
    private func note(_ message: String, isError: Bool = false) {
        if isError {
            log.error("\(message, privacy: .public)")
        } else {
            log.info("\(message, privacy: .public)")
        }
        syncLog?.write(message)
    }

    func refreshEngineAvailability() {
        let available = engineCanTakeRecordings
        engineAvailableFlag.withLock { $0 = available }
    }

    /// The selected engine has `huske inbox`.
    var engineCanTakeRecordings: Bool {
        guard let model, model.binaryURL != nil, let caps = model.capabilities else { return false }
        return caps.isUsable && caps.inboxCLI
    }

    // MARK: pairing

    func beginPairing() {
        guard let server else { return }
        pairedFromInvite = nil
        activeInvite = server.makeInvite()
        reloadDevices()
        pairingSheetVisible = true
    }

    /// A fresh code after the old one expired (the server prunes the old
    /// slot by itself).
    func renewInvite() {
        beginPairing()
    }

    /// Closing the sheet does not withdraw the invite: "Copy link", close,
    /// paste on the phone is a real flow. An unused slot expires after 10
    /// minutes (sync-protocol.md § Pairing).
    func endPairing() {
        pairingSheetVisible = false
        activeInvite = nil
        pairedFromInvite = nil
        reloadDevices()
    }

    func removeDevice(_ deviceID: String) {
        if let server {
            server.removeDevice(deviceID)
        } else {
            registry?.remove(deviceID: deviceID)
        }
        reloadDevices()
    }

    private func reloadDevices() {
        devices = registry?.devices() ?? []
        if let invite = activeInvite, pairedFromInvite == nil,
            let device = devices.first(where: { $0.deviceID == invite.deviceID }), device.isPaired
        {
            pairedFromInvite = device
        }
    }

    // MARK: server events

    private func handle(_ event: SyncServerEvent) {
        // Awake while something is arriving; the lease runs out by itself if
        // the phone walks away without a word.
        keepAwake.note(event)
        switch event {
        case .listening:
            isListening = true
            listenerError = nil
            refreshHealth()
        case .listenerFailed(let message):
            isListening = false
            listenerError = message
            refreshHealth()
        case .devicePaired(let device):
            // The phone that used the code on screen. Taken from the event,
            // not the list: a moment later the phone has swapped the code's
            // key for one this Mac issued, and the list knows it by that.
            if let invite = activeInvite, pairedFromInvite == nil, device.deviceID == invite.deviceID {
                pairedFromInvite = device
            }
            connectedDeviceIDs = server?.connectedDeviceIDs ?? []
            reloadDevices()
        case .deviceConnected:
            connectedDeviceIDs = server?.connectedDeviceIDs ?? []
            reloadDevices()
        case .deviceDisconnected(let deviceID):
            connectedDeviceIDs = server?.connectedDeviceIDs ?? []
            // Its uploads stopped with it; let the next refresh settle them
            // instead of leaving them at "Receiving".
            for (id, device) in uploadDevice where device == deviceID {
                uploadProgressAt.removeValue(forKey: id)
            }
            reloadDevices()
        case .uploadStarted(let manifest, let offset, let deviceID):
            uploadProgressAt[manifest.id] = Date()
            uploadDevice[manifest.id] = deviceID
            let progress = manifest.byteCount > 0 ? Double(offset) / Double(manifest.byteCount) : 0
            upsert(Recording(manifest: manifest, state: .receiving, progress: progress))
        case .uploadProgress(let id, let received, let total):
            uploadProgressAt[id] = Date()
            guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
            let progress = total > 0 ? Double(received) / Double(total) : 1
            // Coalesce: a 256 KiB chunk per ack would re-render the list
            // dozens of times a second on a fast link.
            if abs((recordings[index].progress ?? 0) - progress) >= 0.01 || received == total
                || recordings[index].stalled == true
            {
                recordings[index].progress = progress
                recordings[index].state = .receiving
                recordings[index].stalled = nil
            }
        case .uploadFailed(let id, let reason):
            uploadProgressAt.removeValue(forKey: id)
            uploadDevice.removeValue(forKey: id)
            if let index = recordings.firstIndex(where: { $0.id == id }) {
                recordings[index].detail = reason
            }
        case .uploadVerified(let manifest, _):
            uploadProgressAt.removeValue(forKey: manifest.id)
            uploadDevice.removeValue(forKey: manifest.id)
            var recording = recordings.first { $0.id == manifest.id } ?? Recording(manifest: manifest, state: .received)
            recording.state = .received
            recording.progress = nil
            recording.stalled = nil
            upsert(recording)
        }
    }

    private func upsert(_ recording: Recording) {
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index] = recording
        } else {
            recordings.insert(recording, at: 0)
        }
        recordings.sort { $0.startedAt > $1.startedAt }
        if recordings.count > Self.recordingLimit {
            recordings.removeLast(recordings.count - Self.recordingLimit)
        }
        saveIndex()
    }

    // MARK: hand-off to the engine

    private func pendingAudioURL(_ manifest: RecordingManifest) -> URL {
        pendingDirectory.appendingPathComponent("\(manifest.id).\(manifest.fileExtension)")
    }

    private func pendingManifestURL(_ id: String) -> URL {
        pendingDirectory.appendingPathComponent("\(id).json")
    }

    private func pendingManifest(_ id: String) -> RecordingManifest? {
        guard let data = try? Data(contentsOf: pendingManifestURL(id)) else { return nil }
        return try? JSONDecoder.wire.decode(RecordingManifest.self, from: data)
    }

    private func allPendingManifests() -> [RecordingManifest] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: pendingDirectory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { pendingManifest(String($0.dropLast(5))) }
    }

    /// Takes a verified upload out of the server's staging area into the
    /// durable pending folder and answers the phone; the hand-off to the
    /// engine follows.
    fileprivate func receive(manifest: RecordingManifest, fileURL: URL) async -> RemoteStatus {
        do {
            try FileManager.default.createDirectory(
                at: pendingDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let destination = pendingAudioURL(manifest)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: fileURL, to: destination)
            try JSONEncoder.wire.encode(manifest).write(to: pendingManifestURL(manifest.id), options: .atomic)
        } catch {
            note("could not keep \(manifest.id): \(error.localizedDescription)", isError: true)
            // Leave the file where the server put it; it still answers
            // `received` for it and the phone will not re-send.
            return RemoteStatus(recordingID: manifest.id, state: .received, detail: "Saved on the Mac")
        }
        var recording = recordings.first { $0.id == manifest.id } ?? Recording(manifest: manifest, state: .received)
        recording.state = .received
        recording.progress = nil
        recording.stalled = nil
        recording.detail = engineCanTakeRecordings ? PhoneInbox.handingOffDetail : Self.noEngineDetail
        upsert(recording)
        // Answer now, hand off after. `huske inbox add` is usually 0.2 s, but
        // the phone gives up on a reply after 30 s and a cold engine can take
        // longer. The audio is already in the pending folder, which is taken
        // up again at launch and every minute, so nothing is lost if this
        // hand-off never finishes. `received` keeps the phone asking.
        enqueueHandOff(manifest)
        return PhoneInbox.commitAnswer(recordingID: manifest.id, engineAvailable: engineCanTakeRecordings)
    }

    static let noEngineDetail = PhoneInbox.noEngineDetail

    /// One `huske inbox add` at a time: a burst of re-delivered uploads at
    /// launch must not start a dozen engines at once.
    private func enqueueHandOff(_ manifest: RecordingManifest) {
        let previous = handOffChain
        handOffChain = Task { [weak self] in
            await previous?.value
            _ = await self?.handOff(manifest)
        }
    }

    /// `huske inbox add … --move`; on success the audio now lives in the inbox.
    private func handOff(_ manifest: RecordingManifest) async -> RemoteStatus {
        let audio = pendingAudioURL(manifest)
        guard engineCanTakeRecordings, let binary = model?.binaryURL else {
            return RemoteStatus(recordingID: manifest.id, state: .received, detail: Self.noEngineDetail)
        }
        guard !handOffInFlight.contains(manifest.id) else {
            return RemoteStatus(recordingID: manifest.id, state: .received, detail: PhoneInbox.handingOffDetail)
        }
        handOffInFlight.insert(manifest.id)
        // Awake until the engine has it (bounded by the CLI's own timeout).
        keepAwake.hold(KeepAwake.handOffKey(manifest.id), for: KeepAwake.handOffLease)
        defer {
            handOffInFlight.remove(manifest.id)
            keepAwake.release(KeepAwake.handOffKey(manifest.id))
        }
        lastHandOffAttempt = Date()

        // `--move` may already have taken the file on an earlier attempt whose
        // answer we could not read. The inbox is the source of truth.
        if !FileManager.default.fileExists(atPath: audio.path),
            PhoneInbox.readStatus(root: inboxRoot, id: manifest.id) == nil,
            let rescued = PhoneInbox.stagedAudio(root: inboxRoot, id: manifest.id)
        {
            // An `inbox add --move` killed between the move and its final
            // rename left the audio in the engine's staging: take it back.
            try? FileManager.default.moveItem(at: rescued, to: audio)
        }
        if !FileManager.default.fileExists(atPath: audio.path) {
            try? FileManager.default.removeItem(at: pendingManifestURL(manifest.id))
            if let item = PhoneInbox.readStatus(root: inboxRoot, id: manifest.id) {
                let status = PhoneInbox.remoteStatus(for: item)
                apply(status, transcripts: item.transcripts, to: manifest.id)
                scheduleInboxProcess()
                return status
            }
            let status = RemoteStatus(
                recordingID: manifest.id, state: .failed,
                detail: "The audio file is missing on the Mac; record or send it again")
            apply(status, transcripts: [], to: manifest.id)
            return status
        }

        let outcome: PhoneInbox.AddOutcome
        do {
            let result = try await CLIRunner.run(
                binary: binary, arguments: PhoneInbox.addArguments(fileURL: audio, manifest: manifest),
                timeout: 300)
            outcome = PhoneInbox.parseAddOutput(status: result.status, stdout: result.stdout, stderr: result.stderr)
        } catch {
            outcome = .failed(error.localizedDescription)
        }
        switch outcome {
        case .added(let item, _):
            // `--move` moved it; an idempotent re-add leaves our copy behind.
            try? FileManager.default.removeItem(at: audio)
            try? FileManager.default.removeItem(at: pendingManifestURL(manifest.id))
            let status = PhoneInbox.remoteStatus(for: item)
            apply(status, transcripts: item.transcripts, to: manifest.id)
            note("handed \(manifest.id) to the inbox (\(item.rawState))")
            scheduleInboxProcess()
            return status
        case .failed(let message):
            note("inbox add failed for \(manifest.id): \(message)", isError: true)
            let status = PhoneInbox.handOffRetryStatus(recordingID: manifest.id, message: message)
            apply(status, transcripts: [], to: manifest.id)
            return status
        }
    }

    private func retryPendingHandOffs() {
        guard engineCanTakeRecordings else { return }
        let pending = allPendingManifests()
        guard !pending.isEmpty else { return }
        Task {
            for manifest in pending {
                _ = await self.handOff(manifest)
            }
        }
    }

    /// `huske inbox process` when no live engine is there to pick the item up.
    /// Single-flight; a request while one runs queues exactly one more pass.
    func scheduleInboxProcess() {
        guard engineCanTakeRecordings, let binary = model?.binaryURL else { return }
        if processTask != nil {
            processAgain = true
            return
        }
        if liveEngineRunning() {
            // The live engine scans the inbox every few seconds and holds its
            // lock; a one-shot process would only report "deferred".
            return
        }
        processTask = Task {
            repeat {
                processAgain = false
                note("running huske inbox process")
                // Awake while this Mac transcribes for the phone.
                keepAwake.hold(KeepAwake.processKey, for: KeepAwake.processLease)
                do {
                    // Transcription takes real time; the watchdog is only a
                    // backstop against a wedged process.
                    let result = try await CLIRunner.run(
                        binary: binary, arguments: ["inbox", "process", "--json"], timeout: 6 * 3600)
                    note("inbox process exited \(result.status)", isError: result.status != 0)
                } catch {
                    note("inbox process failed to launch: \(error.localizedDescription)", isError: true)
                }
                await refreshStatuses()
            } while processAgain && !liveEngineRunning()
            keepAwake.release(KeepAwake.processKey)
            processTask = nil
            lastProcessEnded = Date()
        }
    }

    var inboxProcessRunning: Bool { processTask != nil }

    private func liveEngineRunning() -> Bool {
        if model?.session.isBusy == true { return true }
        return SessionDiscovery.findLiveEngineSocket() != nil
    }

    // MARK: status

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshStatuses()
                self.maintenance(tick: ticks)
                ticks += 1
                let busy = !self.activeRecordings.isEmpty
                try? await Task.sleep(nanoseconds: busy ? 2_000_000_000 : 15_000_000_000)
            }
        }
    }

    /// Re-reads status.json for every recording that is still moving.
    func refreshStatuses() async {
        let root = inboxRoot
        let pendingIDs = Set(allPendingManifests().map(\.id))
        var retryPending: Set<String> = []
        for recording in recordings where !recording.state.isTerminal || recording.transcripts.isEmpty {
            if pendingIDs.contains(recording.id) { continue }
            if recording.state == .receiving {
                await settleQuietUpload(recording.id)
                continue
            }
            guard let item = PhoneInbox.readStatus(root: root, id: recording.id) else { continue }
            if PhoneInbox.isRetryable(item) { retryPending.insert(item.id) }
            apply(PhoneInbox.remoteStatus(for: item), transcripts: item.transcripts, to: recording.id)
        }
        retryPendingIDs = retryPending
    }

    /// A row that says "Receiving" while nothing arrives — the phone walked
    /// away, deleted the recording, or Huske relaunched mid-upload. Nothing
    /// used to revisit it: it sat at "Receiving · 42%" and the menu bar said
    /// "arriving" for good. Ask the server what it still holds.
    private func settleQuietUpload(_ id: String) async {
        guard StaleUpload.isQuiet(lastProgress: uploadProgressAt[id]), let server else { return }
        let answer = await server.statuses(for: [id]).first
        // Things move while we wait; decide on what is true now.
        guard let index = recordings.firstIndex(where: { $0.id == id }),
            recordings[index].state == .receiving
        else { return }
        switch StaleUpload.verdict(lastProgress: uploadProgressAt[id], server: answer) {
        case .arriving:
            break
        case .waitingForPhone(let progress):
            let shown = progress ?? recordings[index].progress
            guard recordings[index].stalled != true || recordings[index].progress != shown else { return }
            recordings[index].stalled = true
            recordings[index].progress = shown
            saveIndex()
        case .gone:
            note("the Mac no longer holds the partial upload \(id); dropped its row")
            recordings.remove(at: index)
            uploadProgressAt.removeValue(forKey: id)
            uploadDevice.removeValue(forKey: id)
            saveIndex()
        case .moved(let status):
            apply(status, transcripts: [], to: id)
        }
    }

    private func maintenance(tick: Int) {
        refreshEngineAvailability()
        // Pending uploads: the engine may have been upgraded since.
        if engineCanTakeRecordings, !allPendingManifests().isEmpty,
            Date().timeIntervalSince(lastHandOffAttempt ?? .distantPast) > 60
        {
            retryPendingHandOffs()
        }
        // Queued items with nobody transcribing them (a live session ended,
        // or a failed item has attempts left): give the inbox another pass.
        // `transcribing` with no live engine and no pass of ours running means
        // the transcriber died mid-item (watchdog, crash, reboot); a new pass
        // takes the inbox lock, which re-queues it.
        // An item that failed with attempts left only needs another pass:
        // it gets one soon, not after the idle gap.
        let waiting = recordings.contains { $0.state == .queued || $0.state == .transcribing }
        let gap = PhoneInbox.passGap(retryPending: !retryPendingIDs.isEmpty)
        if waiting, processTask == nil, !liveEngineRunning(),
            Date().timeIntervalSince(lastProcessEnded ?? .distantPast) > gap
        {
            scheduleInboxProcess()
        }
        if tick % 4 == 0 { reloadDevices() }
    }

    private func apply(_ status: RemoteStatus, transcripts: [String], to id: String) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        var recording = recordings[index]
        let parts = PhoneRecordingWords.parts(of: status)
        let changed =
            recording.state != status.state || recording.progress != status.progress
            || recording.detail != status.detail || recording.transcripts != transcripts
            || recording.stalled != nil
            || recording.partsDone != parts?.done || recording.partsTotal != parts?.total
        guard changed else { return }
        recording.stalled = nil
        recording.partsDone = parts?.done
        recording.partsTotal = parts?.total
        recording.state = status.state
        recording.progress = status.progress
        recording.detail = status.detail
        if !transcripts.isEmpty { recording.transcripts = transcripts }
        recording.updatedAt = status.updatedAt
        recordings[index] = recording
        saveIndex()
    }

    /// What the phone is told about `id`.
    fileprivate func status(for id: String) -> RemoteStatus {
        if pendingManifest(id) != nil {
            let detail = recordings.first { $0.id == id }?.detail ?? Self.noEngineDetail
            return PhoneInbox.pendingStatus(recordingID: id, detail: detail)
        }
        if let item = PhoneInbox.readStatus(root: inboxRoot, id: id) {
            return PhoneInbox.remoteStatus(for: item)
        }
        return .unknown(id)
    }

    fileprivate func transcript(for id: String) -> String? {
        guard let item = PhoneInbox.readStatus(root: inboxRoot, id: id) else { return nil }
        return PhoneInbox.transcript(for: item)
    }

    /// The parts the engine did transcribe of a recording it gave up on.
    fileprivate func partialTranscript(for id: String) -> String? {
        guard let item = PhoneInbox.readStatus(root: inboxRoot, id: id) else { return nil }
        return PhoneInbox.partialTranscript(for: item)
    }

    // MARK: pane actions

    /// Recordings with a `huske inbox retry` in flight (the row's button waits).
    private(set) var retrying: Set<String> = []

    /// Gives a recording the engine gave up on a fresh set of attempts
    /// (`huske inbox retry`). `failed` is terminal everywhere else: the engine
    /// stops at 3 attempts. The phone's Retry reaches the same place by
    /// offering the recording again (`retryRequested(for:)`).
    func retry(_ recording: Recording) {
        guard recording.state == .failed else { return }
        let id = recording.id
        Task { _ = await performRetry(id) }
    }

    /// `huske inbox retry ID`, single-flight per recording. Returns the new
    /// status, or nil when nothing was retried.
    @discardableResult
    private func performRetry(_ id: String) async -> RemoteStatus? {
        guard !retrying.contains(id), engineCanTakeRecordings, let binary = model?.binaryURL
        else { return nil }
        retrying.insert(id)
        defer { retrying.remove(id) }
        let outcome: PhoneInbox.RetryOutcome
        do {
            let result = try await CLIRunner.run(
                binary: binary, arguments: PhoneInbox.retryArguments(id: id), timeout: 60)
            outcome = PhoneInbox.parseRetryOutput(
                id: id, status: result.status, stdout: result.stdout, stderr: result.stderr)
        } catch {
            outcome = .refused(error.localizedDescription)
        }
        switch outcome {
        case .retried(let item):
            note("re-queued \(id) for transcription")
            let status = PhoneInbox.remoteStatus(for: item)
            apply(status, transcripts: item.transcripts, to: id)
            scheduleInboxProcess()
            return status
        case .refused(let why):
            note("inbox retry refused for \(id): \(why)", isError: true)
            // Re-read what the engine says, then explain the refusal.
            await refreshStatuses()
            if let index = recordings.firstIndex(where: { $0.id == id }) {
                recordings[index].detail = "Couldn't retry: \(why)"
                saveIndex()
            }
            return nil
        }
    }

    /// A phone offered a recording again that the Mac had failed: its Retry
    /// (sync-protocol.md § Retrying). Same effect as the pane's "Try again".
    fileprivate func retryRequested(for id: String) async -> RemoteStatus? {
        let now = Date()
        guard
            PhoneInbox.shouldRetryOnReoffer(
                lastRequest: reofferRetryAt[id], inFlight: retrying.contains(id),
                engineAvailable: engineCanTakeRecordings, now: now)
        else { return nil }
        reofferRetryAt[id] = now
        note("the iPhone asked to try \(id) again")
        return await performRetry(id)
    }

    // MARK: why isn't it syncing

    /// What "Copy details" puts on the pasteboard: where receiving stands and
    /// the recent log. States and counts — no titles, no transcript text.
    func diagnosticsText() -> String {
        syncLog?.flush()
        let superseded = supersededDeviceIDs
        return PhoneSyncReport.text(
            appVersion: model?.appVersion ?? "?", engineVersion: model?.binaryVersion,
            engineTakesRecordings: engineCanTakeRecordings, enabled: enabled, health: health,
            macName: macName, openAtLogin: model?.openAtLogin ?? false,
            keepingAwake: keepAwake.isHolding,
            phones: pairedDevices.map {
                PhoneSyncReport.Phone(
                    name: $0.name ?? "iPhone", model: $0.model, lastSeen: $0.lastSeenAt,
                    connected: connectedDeviceIDs.contains($0.deviceID),
                    superseded: superseded.contains($0.deviceID))
            },
            recordingStates: recordings.map(\.state),
            logTail: syncLog?.tail() ?? "")
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsText(), forType: .string)
    }

    /// Reveals `sync.log` in the Finder (its folder, before anything is logged).
    func showLog() {
        syncLog?.flush()
        let url = Self.logURL()
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    // MARK: open at login

    /// The user said yes to the offer. Still their action: nothing here runs
    /// unless they chose it.
    func acceptOpenAtLogin() {
        model?.setOpenAtLogin(true)
        note("open at login turned on from the iPhone pane")
    }

    /// The user said no; never offered again.
    func declineOpenAtLogin() {
        loginOfferDeclined = true
        UserDefaults.standard.set(true, forKey: LoginItemOffer.declinedKey)
    }

    func revealTranscript(_ recording: Recording) {
        let urls = recording.transcripts.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: persistence

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
            let decoded = try? JSONDecoder.wire.decode([Recording].self, from: data)
        else { return }
        recordings = decoded
    }

    private func saveIndex() {
        guard registry != nil, let data = try? JSONEncoder.wire.encode(recordings) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: helpers

    private static func computerName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty {
            return name
        }
        return Host.current().localizedName ?? "Mac"
    }

    /// Preview/render seam.
    func _previewInject(
        devices: [PairedDevice]? = nil, recordings: [Recording]? = nil, listening: Bool? = nil,
        invite: PairingInvite? = nil, paired: PairedDevice? = nil,
        health: SyncServerHealth? = nil, connected: Set<String>? = nil
    ) {
        if let devices { self.devices = devices }
        if let recordings { self.recordings = recordings }
        if let listening {
            isListening = listening
            self.health = listening ? .listening(port: 0) : .starting
        }
        if let health { self.health = health }
        if let connected { connectedDeviceIDs = connected }
        if let invite { activeInvite = invite }
        if let paired { pairedFromInvite = paired }
    }
}

// MARK: - SyncServerDelegate

extension PhoneSyncCoordinator: SyncServerDelegate {
    func syncServer(
        _ server: SyncServer, didReceive manifest: RecordingManifest, fileURL: URL,
        from device: PairedDevice
    ) async -> RemoteStatus {
        await receive(manifest: manifest, fileURL: fileURL)
    }

    func syncServer(_ server: SyncServer, statusFor recordingIDs: [String]) async -> [RemoteStatus] {
        recordingIDs.map { status(for: $0) }
    }

    func syncServer(_ server: SyncServer, transcriptFor recordingID: String) async -> String? {
        transcript(for: recordingID)
    }

    func syncServer(_ server: SyncServer, partialTranscriptFor recordingID: String) async -> String? {
        partialTranscript(for: recordingID)
    }

    func syncServer(
        _ server: SyncServer, retryRequestedFor recordingID: String, from device: PairedDevice
    ) async -> RemoteStatus? {
        await retryRequested(for: recordingID)
    }

    nonisolated func syncServerDevicesChanged(_ server: SyncServer) {
        Task { @MainActor in self.reloadDevices() }
    }

    nonisolated func syncServerEngineAvailable(_ server: SyncServer) -> Bool {
        engineAvailableFlag.withLock { $0 }
    }
}

extension JSONEncoder {
    /// Same date format as the sync wire (ISO 8601 with offset).
    static var wire: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(WireDate.format(date))
        }
        return encoder
    }
}

extension JSONDecoder {
    static var wire: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = WireDate.parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: text)
            }
            return date
        }
        return decoder
    }
}
