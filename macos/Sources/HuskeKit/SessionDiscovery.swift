// Finds control sockets of already-running huske sessions (TUI or
// LaunchAgent). Those live in ~/Library/Application Support/huske/ as
// control-<sid8>.sock; sockets owned by this app use the app-*.sock prefix
// and are deliberately excluded.

import Foundation

public enum SessionDiscovery {
    public static func socketDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/huske", isDirectory: true)
    }

    /// Path for a socket owned by this app instance.
    public static func makeAppSocketPath() -> String {
        let dir = socketDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return dir.appendingPathComponent("app-\(suffix).sock").path
    }

    /// Return the first engine-owned control socket that accepts a
    /// connection. Stale socket files from crashed sessions refuse and are
    /// skipped (the engine unlinks them on clean shutdown).
    public static func findLiveEngineSocket(directory: URL? = nil) -> String? {
        let dir = directory ?? socketDirectory()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return nil
        }
        for name in names.sorted()
        where name.hasPrefix("control-") && name.hasSuffix(".sock") {
            let path = dir.appendingPathComponent(name).path
            let probe = LineSocketClient(path: path)
            if (try? probe.connect()) != nil {
                probe.close()
                return path
            }
        }
        return nil
    }
}
