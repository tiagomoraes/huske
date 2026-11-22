// Which networks this iPhone is on, from NWPathMonitor. Two uses: saying "Not
// on Wi-Fi" instead of "Looking for your Mac", and noticing a change (joined
// Wi-Fi, left it) — the moment to try the Mac again rather than sit out a
// backoff. Behind a seam so SyncManager tests can script it.

import Foundation
import Network

struct NetworkPath: Equatable, Sendable {
    /// On Wi-Fi or Ethernet: the Mac can be on the same network.
    var hasLocalNetwork: Bool
    /// The interfaces in use, e.g. `["en0"]`. A different list is a path change.
    var interfaces: [String]
}

protocol NetworkPathSource: AnyObject, Sendable {
    /// The current path first, then every change.
    var updates: AsyncStream<NetworkPath> { get }
    func start()
    func stop()
}

/// The production source. `NWPathMonitor` cannot restart once cancelled, so
/// each `start()` makes a new one.
final class SystemNetworkPath: NetworkPathSource, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "huske.sync.path")
    private var monitor: NWPathMonitor?
    private var current: NetworkPath?
    private var continuations: [UUID: AsyncStream<NetworkPath>.Continuation] = [:]

    deinit {
        monitor?.cancel()
        for continuation in continuations.values { continuation.finish() }
    }

    func start() {
        lock.lock()
        guard monitor == nil else {
            lock.unlock()
            return
        }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        lock.unlock()
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            guard let self, let monitor else { return }
            self.publish(Self.describe(path), from: monitor)
        }
        monitor.start(queue: queue)
    }

    func stop() {
        lock.lock()
        let monitor = self.monitor
        self.monitor = nil
        current = nil
        lock.unlock()
        monitor?.cancel()
    }

    var updates: AsyncStream<NetworkPath> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[id] = continuation
            let current = self.current
            lock.unlock()
            if let current { continuation.yield(current) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    static func describe(_ path: NWPath) -> NetworkPath {
        NetworkPath(
            hasLocalNetwork: path.status == .satisfied
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)),
            interfaces: path.availableInterfaces.map(\.name))
    }

    private func publish(_ path: NetworkPath, from source: NWPathMonitor) {
        lock.lock()
        // A monitor that was stopped (or replaced) has nothing more to say.
        guard monitor === source, path != current else {
            lock.unlock()
            return
        }
        current = path
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets { continuation.yield(path) }
    }
}
