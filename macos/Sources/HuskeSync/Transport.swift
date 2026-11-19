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

    init(_ connection: NWConnection, label: String) {
        self.connection = connection
        self.queue = DispatchQueue(label: "huske.sync.\(label)")
    }

    var endpointDescription: String { "\(connection.endpoint)" }

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
            if let waiter = readyWaiter {
                resume = (waiter, nil)
                readyWaiter = nil
            }
        case .failed(let error):
            let failure = timedOut ? SyncError.timeout : Self.map(error)
            startFailure = failure
            if let waiter = readyWaiter {
                resume = (waiter, failure)
                readyWaiter = nil
            }
            closed = true
        case .waiting(let error):
            // Only interesting before we are ready: a TLS rejection or a
            // refused port shows up here, and waiting for the path to change
            // would just burn the caller's timeout.
            if !isReady, let waiter = readyWaiter {
                let failure = Self.map(error)
                startFailure = failure
                resume = (waiter, failure)
                readyWaiter = nil
                cancelNow = true
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

    func cancel() {
        lock.lock()
        closed = true
        lock.unlock()
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
            self.lock.unlock()
            self.connection.cancel()
        }
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }

    private func failure(for error: NWError) -> SyncError {
        lock.lock()
        defer { lock.unlock() }
        return timedOut ? .timeout : Self.map(error)
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
                return .io("network error: \(code)")
            }
        case .dns(let code):
            return .io("DNS error \(code)")
        default:
            return .io("\(error)")
        }
    }
}
