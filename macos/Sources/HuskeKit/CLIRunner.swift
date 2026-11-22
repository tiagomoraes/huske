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
    /// How long a child gets after SIGTERM before SIGKILL. `huske inbox
    /// process` uses it to put its recording back in the queue and stop its
    /// worker (up to about 5 s).
    static let defaultKillGrace: TimeInterval = 10
    /// After the child exits, how long its output is still read. Whatever
    /// keeps the pipe open past that is not the child.
    static let drainAfterExit: TimeInterval = 1

    /// Run to completion and capture output.
    ///
    /// The child gets its own process group, and at `timeout` the whole group
    /// is signalled: `huske inbox process` spawns an ASR worker, and killing
    /// only the parent left that worker transcribing for nobody. And this
    /// returns when the *child* exits — not when its pipes reach EOF, which an
    /// orphaned grandchild holding them open could delay for ever (that froze
    /// phone transcription until Huske was relaunched).
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
        try await run(binary: binary, arguments: arguments, stdin: stdin, timeout: timeout, killGrace: defaultKillGrace)
    }

    static func run(
        binary: URL, arguments: [String], stdin: Data? = nil, timeout: TimeInterval, killGrace: TimeInterval
    ) async throws -> CLIResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // The engine's environment, plus where the bundled Apple
                    // Intelligence helper is (and no update check).
                    let child = try SpawnedChild(
                        binary: binary, arguments: arguments,
                        environment: HelperLocator.childEnvironment(), stdin: stdin)
                    continuation.resume(returning: child.collect(timeout: timeout, killGrace: killGrace))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Write `data` and close, without ever raising SIGPIPE: a child that
    /// exits before reading would otherwise take the whole app down with it.
    /// The payloads are a line or two, far below the pipe buffer, so writing
    /// before draining stdout cannot deadlock.
    fileprivate static func writeAll(_ data: Data, to handle: FileHandle) {
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

/// One child started with `posix_spawn` as the leader of its own process
/// group (`Foundation.Process` cannot do that): stdin from /dev/null, or from
/// `stdin` written once and closed; stdout and stderr on pipes read without
/// blocking.
private struct SpawnedChild {
    let pid: pid_t
    private let outRead: Int32
    private let errRead: Int32

    init(binary: URL, arguments: [String], environment: [String: String], stdin: Data? = nil) throws {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        var inPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw Self.failure(binary, errno) }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0])
            close(outPipe[1])
            throw Self.failure(binary, errno)
        }
        if stdin != nil, pipe(&inPipe) != 0 {
            let code = errno
            for descriptor in outPipe + errPipe { close(descriptor) }
            throw Self.failure(binary, code)
        }
        defer {
            // The child has its own copies; ours would keep the pipes open.
            close(outPipe[1])
            close(errPipe[1])
            if inPipe[0] >= 0 { close(inPipe[0]) }
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if stdin != nil {
            posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own process group (pgid = its pid); nothing of ours leaks into it
        // but the three descriptors above; default signal handling.
        var noSignals = sigset_t()
        var allSignals = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&allSignals)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        var argv: [UnsafeMutablePointer<CChar>?] = ([binary.path] + arguments).map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var child: pid_t = 0
        let code = posix_spawn(&child, binary.path, &actions, &attributes, &argv, &envp)
        guard code == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            if inPipe[1] >= 0 { close(inPipe[1]) }
            throw Self.failure(binary, code)
        }
        pid = child
        // A line or two (an API key), far below the pipe buffer: written in
        // full before the output is read, then closed so the child sees EOF.
        if let stdin {
            CLIRunner.writeAll(stdin, to: FileHandle(fileDescriptor: inPipe[1], closeOnDealloc: false))
        }
        outRead = outPipe[0]
        errRead = errPipe[0]
        for descriptor in [outRead, errRead] {
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
    }

    private static func failure(_ binary: URL, _ code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Could not run \(binary.path): \(String(cString: strerror(code)))"
            ])
    }

    /// Reads both pipes and waits for the child. One loop, one thread: no
    /// reader can be left blocked on a pipe somebody else still holds.
    func collect(timeout: TimeInterval, killGrace: TimeInterval) -> CLIResult {
        defer {
            close(outRead)
            close(errRead)
        }
        var out = Data()
        var err = Data()
        var open: [Int32] = [outRead, errRead]
        let started = Date()
        var exitedAt: Date?
        var terminatedAt: Date?
        var killed = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            var polled = open.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            // After the exit only what is already buffered is of interest.
            _ = poll(&polled, nfds_t(polled.count), exitedAt == nil ? 100 : 20)
            var readSomething = false
            for entry in polled where entry.revents != 0 {
                while true {
                    let count = read(entry.fd, &buffer, buffer.count)
                    if count > 0 {
                        readSomething = true
                        if entry.fd == outRead { out.append(buffer, count: count) } else { err.append(buffer, count: count) }
                        continue
                    }
                    if count == 0 || (errno != EAGAIN && errno != EINTR) {
                        open.removeAll { $0 == entry.fd }  // EOF, or a dead pipe
                    }
                    break
                }
            }

            let now = Date()
            if exitedAt == nil {
                // Peek, do not reap: while the child stays a zombie its pid —
                // and so its process group id — cannot be handed to anyone
                // else, which keeps the group signal below on target.
                var info = siginfo_t()
                let peeked = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                if (peeked == 0 && info.si_pid == pid) || (peeked == -1 && errno == ECHILD) {
                    exitedAt = now
                    continue  // one more pass for what it wrote last
                }
                if terminatedAt == nil, now.timeIntervalSince(started) >= timeout {
                    // The group, not just the child: its workers go with it.
                    Darwin.kill(-pid, SIGTERM)
                    terminatedAt = now
                } else if let terminatedAt, !killed, now.timeIntervalSince(terminatedAt) >= killGrace {
                    Darwin.kill(-pid, SIGKILL)
                    killed = true
                }
                continue
            }
            if let exitedAt {
                let drained = open.isEmpty || !readSomething
                if drained || now.timeIntervalSince(exitedAt) >= CLIRunner.drainAfterExit { break }
            }
        }

        var status: Int32 = 0
        var info = siginfo_t()
        let signalled =
            waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0
            && (info.si_code == CLD_KILLED || info.si_code == CLD_DUMPED)
        if terminatedAt != nil || signalled {
            // The child did not end on its own terms; whatever it started and
            // left behind has nobody to work for.
            Darwin.kill(-pid, killed ? SIGKILL : SIGTERM)
        }
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        return CLIResult(
            // An exit code, or — like `Process.terminationStatus` — the signal.
            status: (status & 0x7f) != 0 ? status & 0x7f : (status >> 8) & 0xff,
            stdout: String(data: out, encoding: .utf8) ?? "",
            stderr: String(data: err, encoding: .utf8) ?? "")
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
