// Blocking-read AF_UNIX client for huske's newline-delimited JSON control
// protocol. One background thread owns the read loop; callbacks are delivered
// on the main queue. Sends are serialized with a lock and may happen from any
// thread.

import Foundation

public final class LineSocketClient: @unchecked Sendable {
    public enum SocketError: Error, Equatable {
        case pathTooLong
        case connectFailed(errno: Int32)
        case notConnected
    }

    private let path: String
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var readerThread: Thread?
    private var closed = false

    /// Called on the main queue for every decoded message.
    public var onMessage: (@Sendable (ControlMessage) -> Void)?
    /// Called on the main queue exactly once when the connection ends —
    /// whether by server close, read error, or a local `close()`.
    public var onDisconnect: (@Sendable () -> Void)?

    public init(path: String) {
        self.path = path
    }

    deinit {
        close()
    }

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fd >= 0
    }

    /// Connect synchronously. Call from a background context; a Unix-domain
    /// connect either succeeds or fails immediately.
    public func connect() throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count <= capacity else { throw SocketError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw SocketError.connectFailed(errno: errno) }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, size)
            }
        }
        guard result == 0 else {
            let err = errno
            Darwin.close(sock)
            throw SocketError.connectFailed(errno: err)
        }

        lock.lock()
        fd = sock
        closed = false
        lock.unlock()

        let thread = Thread { [weak self] in
            self?.readLoop(socket: sock)
        }
        thread.name = "huske-socket-reader"
        thread.start()
        readerThread = thread
    }

    public func send(_ command: ControlCommand, arg: (any Sendable)? = nil) {
        let data = ControlProtocol.encodeCommand(command, arg: arg)
        lock.lock()
        let sock = fd
        lock.unlock()
        guard sock >= 0 else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(sock, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    public func close() {
        lock.lock()
        let sock = fd
        fd = -1
        let alreadyClosed = closed
        closed = true
        lock.unlock()
        if sock >= 0 {
            shutdown(sock, SHUT_RDWR)
            Darwin.close(sock)
        }
        _ = alreadyClosed
    }

    private func readLoop(socket sock: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(sock, &chunk, chunk.count)
            if count <= 0 { break }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let line = String(data: lineData, encoding: .utf8),
                      !line.trimmingCharacters(in: .whitespaces).isEmpty
                else { continue }
                guard let message = try? ControlProtocol.decode(line: line) else { continue }
                if let onMessage {
                    DispatchQueue.main.async { onMessage(message) }
                }
            }
        }
        // Reader owns teardown so `onDisconnect` fires exactly once.
        lock.lock()
        let wasOpen = fd >= 0
        fd = -1
        closed = true
        lock.unlock()
        if wasOpen {
            shutdown(sock, SHUT_RDWR)
            Darwin.close(sock)
        }
        if let onDisconnect {
            DispatchQueue.main.async { onDisconnect() }
        }
    }
}
