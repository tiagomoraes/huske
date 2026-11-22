// Records AAC-LC .m4a (mono, 48 kHz, ~64 kbps) with AVAudioRecorder.
//
// - Pause/resume continue the same file.
// - Keeps recording when locked/backgrounded (UIBackgroundModes: audio).
// - A phone call (audio session interruption) pauses with a clear reason; the
//   user resumes from the app or the Live Activity.
// - Route changes (AirPods in/out) keep recording and update the input name.
// - The library entry is written *before* the first sample, as `.inProgress`,
//   so a crash leaves a trace that `RecoveryScanner` resolves on next launch.

import AVFoundation
import Foundation
import Observation
import OSLog
import UIKit

private let log = Logger(subsystem: "cloud.tiagomoraes.huske.ios", category: "recorder")

@MainActor
@Observable
final class RecorderController {
    enum PauseReason: Equatable {
        case user
        case interruption
    }

    enum Phase: Equatable {
        case idle
        case recording
        case paused(PauseReason)

        var isActive: Bool { self != .idle }
    }

    enum Problem: Identifiable, Equatable {
        case microphoneDenied
        case couldNotStart(String)
        case couldNotResume(String)
        case stoppedUnexpectedly(String)

        var id: String { message }

        var title: String {
            switch self {
            case .microphoneDenied: return "Microphone access is off"
            case .couldNotStart: return "Couldn't start recording"
            case .couldNotResume: return "Couldn't resume"
            case .stoppedUnexpectedly: return "Recording stopped"
            }
        }

        var message: String {
            switch self {
            case .microphoneDenied:
                return "Allow Huske to use the microphone in Settings to record."
            case let .couldNotStart(detail), let .couldNotResume(detail), let .stoppedUnexpectedly(detail):
                return detail
            }
        }
    }

    // MARK: observable state

    private(set) var phase: Phase = .idle
    /// True while the audio session and recorder spin up (off the main thread).
    private(set) var isStarting = false
    private(set) var recordingID: String?
    private(set) var title: String = ""
    /// Seconds recorded so far (excludes pauses). Refreshed by the meter tick.
    private(set) var elapsed: TimeInterval = 0
    /// Most recent level samples, 0…1, oldest first — the live meter.
    private(set) var levels: [Float] = Array(repeating: 0, count: RecorderController.levelHistory)
    /// Latest average power in dBFS (text equivalent of the meter).
    private(set) var power: Float = -160
    private(set) var inputName: String = "iPhone Microphone"
    /// A transient one-liner such as "Switched to iPhone Microphone".
    private(set) var notice: String?
    var problem: Problem?

    static let levelHistory = 48
    nonisolated static let sampleRate: Double = 48_000

    /// Bluetooth headset mics (AirPods). The iOS 26 SDK renamed the option;
    /// both spell the same HFP route, so older Xcodes (CI) still build.
    nonisolated static var bluetoothMicOption: AVAudioSession.CategoryOptions {
        #if compiler(>=6.2)
        return .allowBluetoothHFP
        #else
        return .allowBluetooth
        #endif
    }
    nonisolated static let channels = 1

    /// Called on the main actor after a recording is saved (sync hook).
    @ObservationIgnored var onRecordingSaved: ((String) -> Void)?

    // MARK: private

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let liveActivity: LiveActivityController
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private let delegateProxy = RecorderDelegateProxy()
    @ObservationIgnored private var accumulated: TimeInterval = 0
    @ObservationIgnored private var segmentStart: Date?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var lastPersistedElapsed: TimeInterval = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var isAppActive = UIApplication.shared.applicationState != .background
    #if DEBUG
    @ObservationIgnored fileprivate var demoTimer: Timer?
    @ObservationIgnored fileprivate var demoPhase = 0.0
    #endif

    init(library: LibraryStore, liveActivity: LiveActivityController) {
        self.library = library
        self.liveActivity = liveActivity
        delegateProxy.onFinish = { [weak self] success in
            Task { @MainActor in self?.recorderDidFinish(successfully: success) }
        }
        delegateProxy.onEncodeError = { [weak self] message in
            Task { @MainActor in self?.recorderDidFail(message) }
        }
        observeSystem()
        refreshInputName()
    }

    // MARK: commands

    func toggleRecord() async {
        if phase == .idle {
            await start()
        } else {
            stop()
        }
    }

    /// Starts a new recording, named `requestedTitle` if given. Also the path
    /// of a background start (Action button, Shortcuts): the Live Activity is
    /// requested *before* the microphone, since iOS only keeps a background
    /// recording alive while one is showing.
    func start(title requestedTitle: String? = nil) async {
        guard phase == .idle, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        log.info("start requested")
        if AVAudioApplication.shared.recordPermission == .undetermined,
           UIApplication.shared.applicationState == .background {
            // The permission prompt needs the app on screen.
            problem = .couldNotStart("Open Huske once and allow the microphone, then try again.")
            return
        }
        guard await ensureMicrophonePermission() else {
            log.error("microphone permission denied")
            problem = .microphoneDenied
            return
        }

        let id = UUID().uuidString
        let startedAt = Date()
        let (fileName, url) = library.newAudioFile(id: id)
        let newTitle = requestedTitle.flatMap(RecordingTitle.normalized)
            ?? RecordingTitle.makeDefault(startedAt: startedAt, existing: library.titles)

        // Persist first: if we crash after this line, recovery finds the entry.
        library.insert(Recording(
            id: id, title: newTitle, startedAt: startedAt, fileName: fileName,
            inputName: inputName, capture: .inProgress))

        let showing = liveActivity.start(recordingID: id, title: newTitle, startedAt: startedAt)
        if !showing, UIApplication.shared.applicationState == .background {
            // iOS ends a background recording that has no Live Activity.
            library.delete(id)
            problem = .couldNotStart(
                "Turn on Live Activities for Huske (Settings › Huske) to record without opening the app.")
            return
        }

        let recorder: AVAudioRecorder
        do {
            let background = UIApplication.shared.applicationState == .background
            recorder = try await AudioStarter.start(url: url, timeout: 6, mixable: background)
        } catch {
            let code = (error as NSError).code
            log.error("recorder failed to start (background: \(UIApplication.shared.applicationState == .background, privacy: .public), \((error as NSError).domain, privacy: .public) \(code, privacy: .public) \(FourCC.text(code), privacy: .public)): \(error.localizedDescription, privacy: .public)")
            liveActivity.cancel()
            library.delete(id)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            problem = .couldNotStart(error.localizedDescription)
            return
        }
        recorder.delegate = delegateProxy
        self.recorder = recorder
        refreshInputName()
        library.update(id) { [inputName] in $0.inputName = inputName }

        recordingID = id
        title = newTitle
        accumulated = 0
        segmentStart = Date()
        elapsed = 0
        lastPersistedElapsed = 0
        levels = Array(repeating: 0, count: Self.levelHistory)
        phase = .recording
        log.info("recording \(id, privacy: .public) started on \(self.inputName, privacy: .public)")
        startTicker()
        pushLiveActivity()
    }

    func togglePause() {
        #if DEBUG
        if demoTimer != nil { return toggleDemoPause() }
        #endif
        switch phase {
        case .recording: pause(reason: .user)
        case .paused: resume()
        case .idle: break
        }
    }

    func pause(reason: PauseReason) {
        guard phase == .recording, let recorder else { return }
        recorder.pause()
        if let segmentStart {
            accumulated += Date().timeIntervalSince(segmentStart)
        }
        segmentStart = nil
        elapsed = accumulated
        phase = .paused(reason)
        power = -160
        persistProgress()
        pushLiveActivity()
    }

    func resume() {
        guard case .paused = phase, let recorder else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            problem = .couldNotResume("The microphone is still in use by another app (\(error.localizedDescription)).")
            return
        }
        guard recorder.record() else {
            problem = .couldNotResume("The recorder didn't restart. Stop to save what you have.")
            return
        }
        segmentStart = Date()
        phase = .recording
        refreshInputName()
        pushLiveActivity()
    }

    func stop() {
        #if DEBUG
        if demoTimer != nil { return stopDemoSession() }
        #endif
        guard phase.isActive, let recorder, let id = recordingID else { return }
        if let segmentStart {
            accumulated += Date().timeIntervalSince(segmentStart)
        }
        segmentStart = nil
        recorder.stop()
        finalize(id: id, trackedDuration: accumulated, note: nil)
    }

    /// Renames the recording in progress (it is already in the library).
    func renameCurrent(to proposed: String) {
        guard let id = recordingID, let normalized = RecordingTitle.normalized(proposed) else { return }
        title = normalized
        library.rename(id, to: normalized)
        pushLiveActivity()
    }

    /// Handles a Live Activity / App Intent command (Shortcuts, Siri, the
    /// Action button, Control Center) and says what happened.
    func handle(_ command: RecordingCommand) async -> RecordingCommandOutcome {
        switch command {
        case let .start(requestedTitle):
            if let id = recordingID { return .alreadyRecording(recordingID: id) }
            if isStarting { return .alreadyRecording(recordingID: "") }
            problem = nil
            await start(title: requestedTitle)
            if let id = recordingID { return .started(recordingID: id) }
            return .failed(problem?.message ?? "Huske couldn't start recording.")
        case .toggleRecording:
            // A second press while the microphone is still spinning up is a
            // double press, not "stop".
            if isStarting { return .alreadyRecording(recordingID: "") }
            if recordingID != nil { return await handle(.stop(recordingID: nil)) }
            return await handle(.start(title: nil))
        case let .togglePause(id):
            guard let current = recordingID, id == nil || id == current else {
                await liveActivity.endStale(keeping: recordingID)
                return .notRecording
            }
            togglePause()
            if case .paused = phase { return .paused }
            if phase == .recording { return .resumed }
            return .failed(problem?.message ?? "Huske couldn't resume.")
        case let .stop(id):
            guard let current = recordingID, id == nil || id == current else {
                await liveActivity.endStale(keeping: recordingID)
                return .notRecording
            }
            stop()
            return .stopped(recordingID: current)
        }
    }

    func elapsed(at date: Date) -> TimeInterval {
        guard let segmentStart else { return accumulated }
        return accumulated + date.timeIntervalSince(segmentStart)
    }

    // MARK: finishing

    private func finalize(id: String, trackedDuration: TimeInterval, note: String?) {
        stopTicker()
        let url = library.recording(id: id).map(library.audioURL(for:))
        let measured = url.flatMap(AudioFileInspector.duration(of:))
        let bytes = url.flatMap(AudioFileInspector.byteCount(of:)) ?? 0
        let finalDuration = measured ?? trackedDuration
        let playable = measured != nil
        library.update(id) { recording in
            recording.duration = finalDuration
            recording.byteCount = bytes
            recording.capture = playable ? .complete : .damaged
            if let note { recording.note = note }
            if !playable {
                recording.note = "The recording couldn't be saved — the audio file is unreadable."
            }
        }
        liveActivity.end(title: title, elapsed: finalDuration)

        recorder = nil
        recordingID = nil
        phase = .idle
        elapsed = 0
        power = -160
        accumulated = 0
        levels = Array(repeating: 0, count: Self.levelHistory)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if playable { onRecordingSaved?(id) }
    }

    private func recorderDidFinish(successfully: Bool) {
        // Normal stops are handled synchronously in `stop()`. This only fires
        // on its own when the system ended the recording (e.g. disk full).
        guard phase.isActive, let id = recordingID else { return }
        if let segmentStart { accumulated += Date().timeIntervalSince(segmentStart) }
        segmentStart = nil
        finalize(id: id, trackedDuration: accumulated,
                 note: successfully ? nil : "The system stopped this recording early.")
        if !successfully {
            problem = .stoppedUnexpectedly("The system stopped the recording. What was recorded so far was saved.")
        }
    }

    private func recorderDidFail(_ message: String) {
        guard phase.isActive, let id = recordingID else { return }
        recorder?.stop()
        finalize(id: id, trackedDuration: accumulated, note: "Recording ended early: \(message)")
        problem = .stoppedUnexpectedly("Recording ended early (\(message)). What was recorded so far was saved.")
    }

    // MARK: metering

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let recorder else { return }
        tickCount += 1
        // In the background only the Live Activity's coarse meter needs data.
        if !isAppActive, tickCount % 10 != 0 { return }

        elapsed = elapsed(at: Date())
        if phase == .recording {
            recorder.updateMeters()
            let average = recorder.averagePower(forChannel: 0)
            power = average
            if isAppActive {
                levels.removeFirst()
                levels.append(Self.normalize(average))
            }
        }
        if elapsed - lastPersistedElapsed >= 10 { persistProgress() }
        liveActivity.refreshForElapsedTime()
    }

    /// dBFS → 0…1 on a perceptual-ish curve (−55 dB floor).
    nonisolated static func normalize(_ dBFS: Float) -> Float {
        let floor: Float = -55
        guard dBFS > floor else { return 0 }
        let linear = (dBFS - floor) / -floor
        return min(1, max(0, pow(linear, 1.6)))
    }

    private func persistProgress() {
        guard let id = recordingID else { return }
        lastPersistedElapsed = elapsed
        let value = elapsed
        library.update(id) { $0.duration = value }
    }

    private func pushLiveActivity() {
        guard recordingID != nil else { return }
        let now = Date()
        let current = elapsed(at: now)
        let pausedAt: Date? = phase == .recording ? nil : now
        let reason: String? = phase == .paused(.interruption) ? "Interrupted by a call" : nil
        liveActivity.update(RecordingActivityAttributes.ContentState(
            phase: phase == .recording ? .recording : .paused,
            title: title,
            timerStart: now.addingTimeInterval(-current),
            pausedAt: pausedAt,
            pauseReason: reason))
    }

    // MARK: microphone permission

    private func ensureMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }

    // MARK: system events

    private func observeSystem() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo ?? [:]
            let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleInterruption(typeRaw: typeRaw)
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated { self?.handleRouteChange(reasonRaw: reasonRaw) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMediaServicesReset() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Finalize the file so it stays playable (an unfinished .m4a is not).
            MainActor.assumeIsolated { self?.stop() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isAppActive = false }
        })
        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isAppActive = true }
        })
    }

    private func handleInterruption(typeRaw: UInt?) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            guard phase == .recording else { return }
            pause(reason: .interruption)
            showNotice("Paused — interrupted by a call")
        case .ended:
            // Deliberately no auto-resume: the user decides when the meeting
            // is back on. The Live Activity and the app both offer Resume.
            break
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonRaw: UInt?) {
        let previous = inputName
        refreshInputName()
        guard phase.isActive, let reasonRaw,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable:
            if previous != inputName { showNotice("Now using \(inputName)") }
        default:
            break
        }
    }

    private func handleMediaServicesReset() {
        guard phase.isActive, let id = recordingID else { return }
        if let segmentStart { accumulated += Date().timeIntervalSince(segmentStart) }
        segmentStart = nil
        recorder?.stop()
        finalize(id: id, trackedDuration: accumulated, note: "The audio system restarted; the recording ends here.")
        problem = .stoppedUnexpectedly("The iPhone's audio system restarted. The recording was saved up to that point.")
    }

    private func refreshInputName() {
        let input = AVAudioSession.sharedInstance().currentRoute.inputs.first
        inputName = input?.portName ?? "iPhone Microphone"
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}

/// Activates the session and starts AVAudioRecorder off the main thread.
/// `prepareToRecord` talks to the audio server synchronously; if that server
/// is wedged it can block for a long time, and it must never freeze the UI.
/// After `timeout` the caller gets an error; a recorder that starts later
/// anyway is stopped and its file removed.
/// AVAudioSession errors are four-character codes ('!rec', '!int', '!pri').
enum FourCC {
    static func text(_ code: Int) -> String {
        let value = UInt32(truncatingIfNeeded: code)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
        guard bytes.allSatisfy({ (32...126).contains($0) }) else { return "-" }
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
}

enum AudioStarter {
    static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: RecorderController.sampleRate,
        AVNumberOfChannelsKey: RecorderController.channels,
        AVEncoderBitRateKey: 64_000,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]

    /// `mixable` is for a start from the background (Action button, Shortcuts):
    /// iOS refuses to activate an exclusive session there ("Session activation
    /// failed"), while a session that mixes with other audio is allowed. In the
    /// foreground the session stays exclusive, so music stops, as in Voice Memos.
    static func start(url: URL, timeout: TimeInterval, mixable: Bool = false) async throws -> AVAudioRecorder {
        let gate = OnceGate()
        let result: RecorderBox = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    var options: AVAudioSession.CategoryOptions = [RecorderController.bluetoothMicOption, .defaultToSpeaker]
                    if mixable { options.insert(.mixWithOthers) }
                    try session.setCategory(.playAndRecord, mode: .default, options: options)
                    try? session.setPreferredSampleRate(RecorderController.sampleRate)
                    try session.setActive(true)
                    let recorder = try AVAudioRecorder(url: url, settings: settings)
                    recorder.isMeteringEnabled = true
                    guard recorder.prepareToRecord(), recorder.record() else {
                        throw RecorderFailure("The recorder didn't start.")
                    }
                    if gate.claim() {
                        continuation.resume(returning: RecorderBox(recorder: recorder))
                    } else {
                        recorder.stop()
                        recorder.deleteRecording()
                    }
                } catch {
                    if gate.claim() { continuation.resume(throwing: error) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if gate.claim() {
                    continuation.resume(throwing: RecorderFailure(
                        "The microphone didn't respond. Another app may be using audio — try again in a moment."))
                }
            }
        }
        return result.recorder
    }

    private struct RecorderBox: @unchecked Sendable {
        let recorder: AVAudioRecorder
    }

    private final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.withLock {
                guard !done else { return false }
                done = true
                return true
            }
        }
    }
}

private struct RecorderFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// AVAudioRecorderDelegate is an NSObject protocol; this keeps the controller
/// a plain @Observable class and hops callbacks to the main actor.
private final class RecorderDelegateProxy: NSObject, AVAudioRecorderDelegate, @unchecked Sendable {
    var onFinish: ((Bool) -> Void)?
    var onEncodeError: ((String) -> Void)?

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        onFinish?(flag)
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        onEncodeError?(error?.localizedDescription ?? "encoder error")
    }
}

#if DEBUG
/// Screenshots/UI review on machines where the simulator has no working
/// microphone: a simulated session with synthetic, speech-like levels. Never
/// touches AVAudioRecorder or the library. (`-HuskeDemoRecording YES`)
extension RecorderController {
    func startDemoSession(title demoTitle: String, alreadyElapsed: TimeInterval) {
        guard phase == .idle else { return }
        recordingID = "DEMO-LIVE"
        title = demoTitle
        accumulated = alreadyElapsed
        segmentStart = Date()
        phase = .recording
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.demoTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        demoTimer = timer
        liveActivity.start(recordingID: "DEMO-LIVE", title: demoTitle, startedAt: Date())
        pushLiveActivity()
    }

    private func demoTick() {
        elapsed = elapsed(at: Date())
        guard phase == .recording else { return }
        demoPhase += 0.05
        // Syllable-ish bursts under a slow phrase envelope, with pauses.
        let phrase = max(0, sin(demoPhase * 0.9) + 0.35)
        let syllable = abs(sin(demoPhase * 7.3)) * 0.6 + Double.random(in: 0...0.4)
        let level = min(1, phrase * syllable * 0.9)
        power = Float(-55 + level * 47)
        levels.removeFirst()
        levels.append(Self.normalize(power))
        liveActivity.refreshForElapsedTime()
    }

    private func toggleDemoPause() {
        if phase == .recording {
            if let segmentStart { accumulated += Date().timeIntervalSince(segmentStart) }
            segmentStart = nil
            phase = .paused(.user)
            power = -160
        } else {
            segmentStart = Date()
            phase = .recording
        }
        elapsed = elapsed(at: Date())
        pushLiveActivity()
    }

    private func stopDemoSession() {
        demoTimer?.invalidate()
        demoTimer = nil
        liveActivity.end(title: title, elapsed: elapsed(at: Date()))
        recordingID = nil
        segmentStart = nil
        accumulated = 0
        elapsed = 0
        phase = .idle
        levels = Array(repeating: 0, count: Self.levelHistory)
    }
}
#endif
