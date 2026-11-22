// Async helpers for one-shot `huske <subcommand>` invocations (config, doctor,
// devices, recover, llm, models). Never used for `huske run` — that goes through
// EngineProcess so the app can supervise it.

import Foundation

public struct CLIResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum CLIRunner {
    /// Run to completion and capture output.
    ///
    /// `stdin` is written to the child's standard input and then closed —
    /// the channel for secrets (`huske llm key set` reads the API key from
    /// it), which must never travel as an argument: `ps` shows every
    /// process's argv. Nothing here logs or keeps it; callers wipe their copy.
    public static func run(
        binary: URL,
        arguments: [String],
        stdin: Data? = nil,
        timeout: TimeInterval = 120
    ) async throws -> CLIResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = binary
                process.arguments = arguments
                process.environment = HelperLocator.childEnvironment()
                let outPipe = Pipe()
                let errPipe = Pipe()
                let inPipe = stdin.map { _ in Pipe() }
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = inPipe ?? FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                if let stdin, let inPipe {
                    writeAll(stdin, to: inPipe.fileHandleForWriting)
                }

                let watchdog = DispatchWorkItem { [weak process] in
                    process?.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                // Read fully before waitUntilExit so a large output cannot
                // deadlock on a full pipe.
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()

                continuation.resume(
                    returning: CLIResult(
                        status: process.terminationStatus,
                        stdout: String(data: outData, encoding: .utf8) ?? "",
                        stderr: String(data: errData, encoding: .utf8) ?? ""
                    ))
            }
        }
    }

    /// Write `data` and close, without ever raising SIGPIPE: a child that
    /// exits before reading would otherwise take the whole app down with it.
    /// The payloads are a line or two, far below the pipe buffer, so writing
    /// before draining stdout cannot deadlock.
    private static func writeAll(_ data: Data, to handle: FileHandle) {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    break // EPIPE: the child is gone; its exit status says why
                }
            }
        }
        try? handle.close()
    }

    /// Run to completion, handing each *stdout* line to `onLine` as it
    /// arrives (on a background queue) while stderr is collected apart — a
    /// JSON-lines command (`huske models download --json`) keeps its stream
    /// clean of the progress bars and warnings libraries print to stderr.
    ///
    /// Cancelling the calling task terminates the child (SIGTERM); the call
    /// then returns normally with whatever the child said before it went, so
    /// the caller decides what a cancelled run means.
    public static func streamLines(
        binary: URL,
        arguments: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CLIResult {
        let running = RunningProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = binary
                    process.arguments = arguments
                    process.environment = HelperLocator.childEnvironment()
                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    process.standardOutput = outPipe
                    process.standardError = errPipe
                    process.standardInput = FileHandle.nullDevice

                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    running.started(process)

                    // stderr drains on its own queue so a chatty child can
                    // never block on a full pipe while stdout is being read.
                    let errData = DataBox()
                    let errDone = DispatchGroup()
                    errDone.enter()
                    DispatchQueue.global(qos: .utility).async {
                        errData.set(errPipe.fileHandleForReading.readDataToEndOfFile())
                        errDone.leave()
                    }

                    var all = Data()
                    var pending = Data()
                    let reader = outPipe.fileHandleForReading
                    while true {
                        let chunk = reader.availableData
                        if chunk.isEmpty { break } // EOF
                        all.append(chunk)
                        pending.append(chunk)
                        while let newline = pending.firstIndex(of: 0x0A) {
                            let lineData = pending.prefix(upTo: newline)
                            pending.removeSubrange(...newline)
                            if let line = String(data: lineData, encoding: .utf8) {
                                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty { onLine(trimmed) }
                            }
                        }
                    }
                    if let rest = String(data: pending, encoding: .utf8) {
                        let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { onLine(trimmed) }
                    }
                    errDone.wait()
                    process.waitUntilExit()
                    continuation.resume(
                        returning: CLIResult(
                            status: process.terminationStatus,
                            stdout: String(data: all, encoding: .utf8) ?? "",
                            stderr: String(data: errData.value, encoding: .utf8) ?? ""))
                }
            }
        } onCancel: {
            running.cancel()
        }
    }

    /// Run while streaming combined output lines to `onLine` (main queue).
    /// Returns the exit status.
    public static func stream(
        binary: URL,
        arguments: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        let engine = EngineProcess(binary: binary, arguments: arguments)
        engine.onOutputLine = onLine
        return try await withCheckedThrowingContinuation { continuation in
            engine.onTermination = { status in
                withExtendedLifetime(engine) {} // keep the supervisor alive until exit
                continuation.resume(returning: status)
            }
            do {
                try engine.launch()
            } catch {
                engine.onTermination = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

/// The child behind a `streamLines` call, so a cancellation that lands
/// before, during or after launch always does the right thing.
private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func started(_ process: Process) {
        lock.lock()
        self.process = process
        let stop = cancelled
        lock.unlock()
        if stop { process.terminate() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
