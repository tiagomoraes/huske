// Async framing over one NWConnection: wait for `.ready`, send a message,
// receive the next message (reassembling frames from arbitrary TCP splits via
// FrameDecoder). Timeouts cancel the connection, which is what unblocks a
// pending receive — Network.framework receives do not observe Task
// cancellation on their own.

import Foundation
import Network

final class FramedConnection: @unchecked Sendable {
    let connection: NWConnection
    let queue: DispatchQueue

    private let lock = NSLock()
    private var decoder = FrameDecoder()
    private var timedOut = false
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var startFailure: SyncError?
    private var isReady = false
    private var closed = false
    /// A path error seen while connecting, and the timer that turns it into
    /// the attempt's failure if the path hasn't recovered by then.
    private var pathFailure: SyncError?
    private var pathGraceTimer: DispatchWorkItem?
    private let pathGrace: TimeInterval
    private var pathGraceExpired = false

    /// How long a connection that isn't ready yet may sit in `.waiting` on a
    /// *path* problem (no route, the interface still coming up, the Bonjour
    /// name not resolved yet) before the attempt fails. Network.framework
    /// retries by itself when the path changes; a network handover takes a
    /// second or two.
    static let defaultPathGrace: TimeInterval = 3

    init(_ connection: NWConnection, label: String, pathGrace: TimeInterval = FramedConnection.defaultPathGrace) {
        self.connection = connection
        self.queue = DispatchQueue(label: "huske.sync.\(label)")
        self.pathGrace = pathGrace
    }

    var endpointDescription: String { "\(connection.endpoint)" }

    /// How the connection reaches its peer (meaningful once ready).
    var route: SyncRoute {
        guard let interface = connection.currentPath?.availableInterfaces.first else { return .other }
        return SyncRoute(interfaceName: interface.name, type: interface.type)
    }

    // MARK: lifecycle

    /// Starts the connection and waits for TLS to be established.
    func start(timeout: TimeInterval) async throws {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state: state)
        }
        let timer = scheduleTimeout(timeout)
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if isReady {
                lock.unlock()
                continuation.resume()
                return
            }
            if let failure = startFailure {
                lock.unlock()
                continuation.resume(throwing: failure)
                return
            }
            if closed || timedOut {
                // Cancelled before it ever started (e.g. the server stopped
                // between accept and serve): Network.framework reports no
                // further state, so waiting for one would hang forever.
                let failure: SyncError = timedOut ? .timeout : .connectionClosed
                lock.unlock()
                continuation.resume(throwing: failure)
                return
            }
            readyWaiter = continuation
            lock.unlock()
            connection.start(queue: queue)
        }
    }

    private func handle(state: NWConnection.State) {
        lock.lock()
        var resume: (CheckedContinuation<Void, Error>, Error?)?
        var cancelNow = false
        switch state {
        case .ready:
            isReady = true
            clearPathFailure()
            if let waiter = readyWaiter {
                resume = (waiter, nil)
                readyWaiter = nil
            }
        case .preparing:
            // Trying again (the path changed): the earlier path error is
            // history. The caller's timeout still bounds the attempt.
            clearPathFailure()
        case .failed(let error):
            let failure = timedOut ? SyncError.timeout : Self.map(error)
            startFailure = failure
            if let waiter = readyWaiter {
                resume = (waiter, failure)
                readyWaiter = nil
            }
            closed = true
        case .waiting(let error):
            // Only interesting before we are ready.
            if !isReady, let waiter = readyWaiter {
                if Self.isPathError(error) {
                    // No way through *yet*. Network.framework tries again by
                    // itself when the path changes, so give it a moment
                    // (`pathGrace`) before calling the attempt failed.
                    pathFailure = Self.map(error)
                    if pathGraceTimer == nil { schedulePathGrace() }
                } else {
                    // An answer from the other side — a refused port, a TLS
                    // rejection: waiting would just burn the caller's timeout.
                    let failure = Self.map(error)
                    startFailure = failure
                    resume = (waiter, failure)
                    readyWaiter = nil
                    cancelNow = true
                    clearPathFailure()
                }
            }
        case .cancelled:
            closed = true
            if let waiter = readyWaiter {
                let failure = timedOut ? SyncError.timeout : (startFailure ?? .connectionClosed)
                resume = (waiter, failure)
                readyWaiter = nil
            }
        default:
            break
        }
        lock.unlock()
        if cancelNow { connection.cancel() }
        if let (waiter, error) = resume {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
    }

    /// Test seam: deliver `state` as Network.framework would, on the
    /// connection's queue.
    func deliverState(_ state: NWConnection.State) {
        queue.sync { handle(state: state) }
    }

    /// Whether `start(timeout:)` is still waiting for the connection.
    var isAwaitingReady: Bool {
        lock.withLock { readyWaiter != nil }
    }

    /// The attempt ended without the other side saying anything: it timed
    /// out, or there was no path to it. (A refused port or a TLS rejection is
    /// an answer.) Another address of the same Mac may still work.
    var gotNoAnswer: Bool {
        lock.withLock { !isReady && (timedOut || pathGraceExpired) }
    }

    /// Whether a `.waiting` error is about the path — curable by the network
    /// changing — rather than an answer from the peer (refused, TLS rejected).
    static func isPathError(_ error: NWError) -> Bool {
        switch error {
        case .posix(let code):
            switch code {
            case .ENETDOWN, .ENETUNREACH, .EHOSTDOWN, .EHOSTUNREACH, .EADDRNOTAVAIL:
                return true
            default:
                return false
            }
        case .dns:
            // The Bonjour name hasn't resolved (yet): the Mac's record is
            // still settling after a listener restart, or it just left.
            return true
        default:
            return false
        }
    }

    /// Call with `lock` held.
    private func schedulePathGrace() {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pathGraceTimer = nil
            guard !self.isReady, let waiter = self.readyWaiter, let failure = self.pathFailure else {
                self.lock.unlock()
                return
            }
            self.startFailure = failure
            self.readyWaiter = nil
            self.pathFailure = nil
            self.pathGraceExpired = true
            self.lock.unlock()
            self.connection.cancel()
            waiter.resume(throwing: failure)
        }
        pathGraceTimer = item
        queue.asyncAfter(deadline: .now() + pathGrace, execute: item)
    }

    /// Call with `lock` held.
    private func clearPathFailure() {
        pathFailure = nil
        pathGraceTimer?.cancel()
        pathGraceTimer = nil
    }

    func cancel() {
        lock.lock()
        closed = true
        lock.unlock()
        connection.cancel()
    }

    deinit {
        // Dropping the last reference must not leave the socket open until
        // the peer's idle timeout; cancelling twice is harmless.
        connection.cancel()
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    // MARK: I/O

    func send(_ message: WireMessage, timeout: TimeInterval = 30) async throws {
        let data = try WireCodec.encode(message)
        let timer = scheduleTimeout(timeout)
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { [weak self] error in
                    if let error {
                        continuation.resume(throwing: self?.failure(for: error) ?? Self.map(error))
                    } else {
                        continuation.resume()
                    }
                })
        }
    }

    /// The next message, or nil when the peer closed cleanly between frames.
    func receive(timeout: TimeInterval?) async throws -> WireMessage? {
        let timer = timeout.map { scheduleTimeout($0) }
        defer { timer?.cancel() }
        while true {
            if let frame = try nextBufferedFrame() {
                return try WireCodec.decode(frame)
            }
            let (data, isComplete, error) = await receiveRaw()
            if let data, !data.isEmpty {
                lock.withLock { decoder.append(data) }
                continue
            }
            if let error {
                throw failure(for: error)
            }
            if isComplete {
                // Our own deadline cancelled the connection, and a cancelled
                // receive can end "complete" with no error: still a timeout.
                if lock.withLock({ timedOut }) { throw SyncError.timeout }
                if let frame = try nextBufferedFrame() {
                    return try WireCodec.decode(frame)
                }
                let leftover = lock.withLock { decoder.bufferedByteCount }
                if leftover == 0 { return nil }
                throw SyncError.connectionClosed
            }
        }
    }

    private func nextBufferedFrame() throws -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        return try decoder.nextFrame()
    }

    private func receiveRaw() async -> (Data?, Bool, NWError?) {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) {
                data, _, isComplete, error in
                continuation.resume(returning: (data, isComplete, error))
            }
        }
    }

    // MARK: timeouts + errors

    private func scheduleTimeout(_ seconds: TimeInterval) -> DispatchWorkItem {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.timedOut = true
            // Resume a pending start ourselves: a connection that never
            // started reports no `.cancelled`, so the deadline must not rely
            // on one.
            let waiter = self.readyWaiter
            self.readyWaiter = nil
            self.lock.unlock()
            self.connection.cancel()
            waiter?.resume(throwing: SyncError.timeout)
        }
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }

    private func failure(for error: NWError) -> SyncError {
        lock.lock()
        defer { lock.unlock() }
        if timedOut { return .timeout }
        // Once the handshake succeeded the key was accepted: a TLS error now
        // is a damaged record or a torn-down session — retry and resume, not
        // "pair again".
        if isReady, case .tls = error { return .connectionClosed }
        return Self.map(error)
    }

    static func map(_ error: NWError) -> SyncError {
        switch error {
        case .tls(let status):
            return .handshakeFailed("TLS error \(status)")
        case .posix(let code):
            switch code {
            case .ECONNRESET, .EPIPE, .ENOTCONN, .ECANCELED, .ECONNABORTED:
                return .connectionClosed
            case .ETIMEDOUT:
                return .timeout
            default:
                return .network(NetworkFailure(posix: code))
            }
        case .dns(let code):
            return .network(.nameNotResolved("DNS error \(code)"))
        default:
            return .network(.other("\(error)"))
        }
    }
}
