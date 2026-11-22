// Async helpers for one-shot `huske <subcommand>` invocations (config, doctor,
// devices, recover). Never used for `huske run` — that goes through
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
    public static func run(
        binary: URL,
        arguments: [String],
        timeout: TimeInterval = 120
    ) async throws -> CLIResult {
        try await run(binary: binary, arguments: arguments, timeout: timeout, killGrace: defaultKillGrace)
    }

    static func run(
        binary: URL, arguments: [String], timeout: TimeInterval, killGrace: TimeInterval
    ) async throws -> CLIResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    var environment = ProcessInfo.processInfo.environment
                    environment["HUSKE_NO_UPDATE_CHECK"] = "1"
                    let child = try SpawnedChild(binary: binary, arguments: arguments, environment: environment)
                    continuation.resume(returning: child.collect(timeout: timeout, killGrace: killGrace))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
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
/// group (`Foundation.Process` cannot do that), stdin from /dev/null, stdout
/// and stderr on pipes read without blocking.
private struct SpawnedChild {
    let pid: pid_t
    private let outRead: Int32
    private let errRead: Int32

    init(binary: URL, arguments: [String], environment: [String: String]) throws {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw Self.failure(binary, errno) }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0])
            close(outPipe[1])
            throw Self.failure(binary, errno)
        }
        defer {
            // The child has its own copies; ours would keep the pipes open.
            close(outPipe[1])
            close(errPipe[1])
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
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
            throw Self.failure(binary, code)
        }
        pid = child
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
