// The app-side session state machine. Owns (or attaches to) one huske engine
// and exposes everything the UI renders. All mutation happens on the main
// actor; socket/process callbacks already arrive on the main queue.

import Foundation
import Observation

@MainActor
@Observable
public final class SessionController {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Engine spawned, waiting for the control socket (model warm-up).
        case launching(status: String)
        /// Connected. `attached` means the session was started outside the
        /// app (TUI / LaunchAgent) — we control it but don't own the process.
        case active(attached: Bool)
        case failed(String)
    }

    public internal(set) var phase: Phase = .idle
    public internal(set) var snapshot: ControlSnapshot?
    public internal(set) var devices: DeviceList?
    /// Rolling, deduplicated event log (snapshots carry only the last 5).
    public internal(set) var eventLog: [SessionEvent] = []
    /// Engine stdout/stderr tail (owned sessions only).
    public internal(set) var engineLog: [String] = []
    /// Set while a stop was requested and the engine is finalizing.
    public internal(set) var stopRequested = false

    @ObservationIgnored private var engine: EngineProcess?
    @ObservationIgnored private var client: LineSocketClient?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var seenEventIDs = Set<String>()

    private static let eventLogLimit = 250
    private static let engineLogLimit = 200

    public init() {}

    public var isBusy: Bool {
        switch phase {
        case .idle, .failed: return false
        case .launching, .active: return true
        }
    }

    public var isDraining: Bool {
        snapshot?.stopping ?? false
    }

    public var ownsEngine: Bool {
        engine != nil
    }

    // MARK: lifecycle

    /// Spawn `huske run` and connect to its control socket.
    public func startEngine(binary: URL, socketPath: String? = nil) {
        guard case .idle = phaseOrFailed() else { return }
        let path = socketPath ?? SessionDiscovery.makeAppSocketPath()
        stopRequested = false
        seenEventIDs.removeAll()
        eventLog = []
        engineLog = []
        snapshot = nil

        let proc = EngineProcess(
            binary: binary,
            arguments: ["run", "--no-ui", "--control-socket", path]
        )
        proc.onOutputLine = { [weak self] line in
            MainActor.assumeIsolated {
                self?.ingestEngineLine(line)
            }
        }
        proc.onTermination = { [weak self] status in
            MainActor.assumeIsolated {
                self?.engineTerminated(status: status)
            }
        }
        do {
            try proc.launch()
        } catch {
            phase = .failed("could not launch huske: \(error.localizedDescription)")
            return
        }
        engine = proc
        phase = .launching(status: "starting the huske engine…")
        connectTask = Task { [weak self] in
            await self?.pollConnect(path: path, timeout: 240)
        }
    }

    /// Attach to a session started outside the app, if one is live.
    @discardableResult
    public func attachIfEngineRunning() -> Bool {
        guard case .idle = phaseOrFailed() else { return false }
        guard let path = SessionDiscovery.findLiveEngineSocket() else { return false }
        stopRequested = false
        seenEventIDs.removeAll()
        eventLog = []
        snapshot = nil
        guard let connected = makeClient(path: path) else { return false }
        client = connected
        phase = .active(attached: true)
        connected.send(.requestDevices)
        return true
    }

    /// Graceful stop: the engine finalizes the current chunk and drains
    /// transcriptions before exiting. Progress arrives via snapshots.
    public func requestStop() {
        stopRequested = true
        if let client, client.isConnected {
            client.send(.stop)
        } else {
            engine?.interrupt()
        }
    }

    /// Last resort while stuck launching (e.g. wrong binary).
    public func cancelLaunch() {
        connectTask?.cancel()
        connectTask = nil
        engine?.terminate()
        // engineTerminated() finishes the transition.
    }

    public func dismissFailure() {
        if case .failed = phase {
            phase = .idle
        }
    }

    // MARK: commands

    public func send(_ command: ControlCommand, arg: (any Sendable)? = nil) {
        client?.send(command, arg: arg)
    }

    public func pauseResume() { send(.pauseResume) }
    public func toggleScreenshots() { send(.toggleScreenshots) }
    public func toggleDistill() { send(.toggleDistill) }
    public func refreshDevices() { send(.requestDevices) }

    public func selectInputDevice(named name: String) {
        send(.setInputDevice, arg: name)
    }

    // MARK: message ingestion (also used by the demo driver)

    func ingest(message: ControlMessage) {
        switch message {
        case .state(let snap):
            snapshot = snap
            mergeEvents(snap.events)
        case .devices(let list):
            devices = list
        }
    }

    func setPhaseForDemo(_ newPhase: Phase) {
        phase = newPhase
    }

    // MARK: internals

    private func phaseOrFailed() -> Phase {
        if case .failed = phase { return .idle } // allow retry from failure
        return phase
    }

    private func mergeEvents(_ events: [SessionEvent]) {
        for event in events where !seenEventIDs.contains(event.id) {
            seenEventIDs.insert(event.id)
            eventLog.append(event)
        }
        if eventLog.count > Self.eventLogLimit {
            eventLog.removeFirst(eventLog.count - Self.eventLogLimit)
        }
    }

    private func ingestEngineLine(_ line: String) {
        engineLog.append(line)
        if engineLog.count > Self.engineLogLimit {
            engineLog.removeFirst(engineLog.count - Self.engineLogLimit)
        }
        if case .launching = phase {
            // Surface the engine's own progress prints while warming up.
            let cleaned = line
                .replacingOccurrences(of: "[huske] ", with: "")
                .replacingOccurrences(of: "[warn] ", with: "")
            phase = .launching(status: cleaned)
        }
    }

    private func engineTerminated(status: Int32) {
        connectTask?.cancel()
        connectTask = nil
        client?.close()
        client = nil
        let wasLaunching: Bool
        if case .launching = phase { wasLaunching = true } else { wasLaunching = false }
        engine = nil

        if stopRequested || (status == 0 && !wasLaunching) {
            phase = .idle
        } else {
            let tail = engineLog.suffix(3).joined(separator: "\n")
            let context = wasLaunching ? "the engine exited during startup" : "the engine exited unexpectedly"
            phase = .failed(tail.isEmpty ? "\(context) (exit \(status))" : "\(context) (exit \(status))\n\(tail)")
        }
        snapshot = nil
        stopRequested = false
    }

    private func clientDisconnected() {
        client = nil
        guard engine == nil else {
            // Owned session: the process termination handler decides the
            // final state (it may still be draining after closing the socket).
            return
        }
        // Attached session ended.
        phase = .idle
        snapshot = nil
        stopRequested = false
    }

    private func makeClient(path: String) -> LineSocketClient? {
        let socket = LineSocketClient(path: path)
        socket.onMessage = { [weak self] message in
            MainActor.assumeIsolated {
                self?.ingest(message: message)
            }
        }
        socket.onDisconnect = { [weak self] in
            MainActor.assumeIsolated {
                self?.clientDisconnected()
            }
        }
        do {
            try socket.connect()
        } catch {
            return nil
        }
        return socket
    }

    private func pollConnect(path: String, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled {
            guard engine?.isRunning == true else { return }
            if let connected = makeClient(path: path) {
                client = connected
                phase = .active(attached: false)
                connected.send(.requestDevices)
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        guard !Task.isCancelled else { return }
        if case .launching = phase {
            engine?.terminate()
            phase = .failed("the engine did not open its control socket in time")
        }
    }
}
