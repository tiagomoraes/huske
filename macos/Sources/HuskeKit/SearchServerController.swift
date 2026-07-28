// Supervises a `huske mcp` child process on behalf of the app.
//
// Without this the only way to run the search server is a terminal window the
// user has to leave open — the single most confusing step in the old setup, and
// the reason "connect an LLM" was not something you could finish in the GUI.
//
// Distinct from `SessionController`, which owns `huske run`: the two are
// independent (search answers queries about past transcripts whether or not a
// recording is in progress), so they must be startable and stoppable
// separately.

import Foundation

@MainActor
@Observable
public final class SearchServerController {
    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case running
        /// Exited on its own, with the last line of output as the reason.
        case failed(String)
    }

    public private(set) var state: State = .stopped
    /// Recent output, newest last — shown when the server fails to start.
    public private(set) var log: [String] = []

    private var process: EngineProcess?
    private static let logLimit = 80

    /// A line the engine prints only once it is actually serving.
    private static let readyMarker = "huske MCP server"

    public init() {}

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    public var isBusy: Bool {
        if case .starting = state { return true }
        return false
    }

    public var failure: String? {
        if case .failed(let reason) = state { return reason }
        return nil
    }

    /// Adopt a server someone already started (a terminal, a LaunchAgent).
    ///
    /// Called after probing the port: the app must not present "start" for a
    /// server that is already up, and must not claim ownership it does not have
    /// — so `stop()` deliberately does nothing to a process we did not spawn.
    public func adoptExternal() {
        guard process == nil else { return }
        state = .running
    }

    public func start(binary: URL) {
        guard process == nil else { return }
        state = .starting
        log.removeAll()

        let child = EngineProcess(binary: binary, arguments: ["mcp"])
        child.onOutputLine = { [weak self] line in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.append(line)
                // The banner is the only reliable "serving now" signal; the
                // port opens slightly before it prints.
                if line.contains(Self.readyMarker), self.isBusy {
                    self.state = .running
                }
            }
        }
        child.onTermination = { [weak self] status in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.process = nil
                if status == 0 {
                    self.state = .stopped
                } else {
                    // Surface the engine's own last words — usually a missing
                    // extra or an unbuilt index, both of which have a fix.
                    let reason =
                        self.log.last(where: { $0.lowercased().contains("error") })
                        ?? self.log.last
                        ?? "the search server exited (status \(status))"
                    self.state = .failed(reason)
                }
            }
        }

        do {
            try child.launch()
            process = child
        } catch {
            process = nil
            state = .failed(error.localizedDescription)
        }
    }

    public func stop() {
        guard let process else {
            // Nothing of ours to stop; an adopted external server keeps running.
            state = .stopped
            return
        }
        process.terminate()
        self.process = nil
        state = .stopped
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > Self.logLimit {
            log.removeFirst(log.count - Self.logLimit)
        }
    }
}
