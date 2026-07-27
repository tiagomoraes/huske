// Supervises a `huske run` child process. Combined stdout+stderr lines are
// surfaced on the main queue (the engine prints its warm-up progress there
// before the control socket exists), as is termination.

import Foundation

public final class EngineProcess: @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()
    private let lock = NSLock()
    private var lineBuffer = Data()
    private var tail: [String] = []
    private static let tailLimit = 200

    /// Called on the main queue per output line.
    public var onOutputLine: (@Sendable (String) -> Void)?
    /// Called on the main queue once, with the exit status.
    public var onTermination: (@Sendable (Int32) -> Void)?

    public init(binary: URL, arguments: [String], environment: [String: String] = [:]) {
        process.executableURL = binary
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["HUSKE_NO_UPDATE_CHECK"] = "1"
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
    }

    public var isRunning: Bool { process.isRunning }
    public var processIdentifier: Int32 { process.processIdentifier }

    /// Last output lines, for failure diagnostics.
    public var outputTail: [String] {
        lock.lock()
        defer { lock.unlock() }
        return tail
    }

    public func launch() throws {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.ingest(data)
        }
        process.terminationHandler = { [weak self] proc in
            proc.terminationHandler = nil // break retain cycles via captured closures
            guard let self else { return }
            self.pipe.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus
            if let onTermination = self.onTermination {
                DispatchQueue.main.async { onTermination(status) }
            }
        }
        try process.run()
    }

    /// Ask the engine to stop gracefully (same as Ctrl+C: finalize the current
    /// chunk, drain pending transcriptions, then exit).
    public func interrupt() {
        guard process.isRunning else { return }
        process.interrupt() // SIGINT
    }

    public func terminate() {
        guard process.isRunning else { return }
        process.terminate() // SIGTERM — the engine treats it like SIGINT
    }

    public func kill9() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }

    private func ingest(_ data: Data) {
        var lines: [String] = []
        lock.lock()
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer.prefix(upTo: newline)
            lineBuffer.removeSubrange(...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    lines.append(cleaned)
                    tail.append(cleaned)
                }
            }
        }
        if tail.count > Self.tailLimit {
            tail.removeFirst(tail.count - Self.tailLimit)
        }
        lock.unlock()
        guard !lines.isEmpty, let onOutputLine else { return }
        DispatchQueue.main.async {
            for line in lines { onOutputLine(line) }
        }
    }
}
