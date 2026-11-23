// Is there a newer Huske.app? The engine has told users about new releases
// since it shipped (`huske/update_check.py` polls PyPI and prints a banner),
// but that banner only appears on a TTY — and an app user never sees one. So
// the app, which *is* the UI now, had no way at all to say "there's a new
// version", while the zip it was installed from sat one click away on GitHub.
//
// Same shape as the engine's check, deliberately: stdlib only, a 24 h disk
// cache next to the engine's, silent on every failure, and off entirely when
// HUSKE_NO_UPDATE_CHECK is set. It asks GitHub for one release's metadata and
// sends nothing — no identifiers, no audio, no transcripts.

import Foundation

public struct AppRelease: Equatable, Sendable, Codable {
    public let tag: String
    /// The release page, for "what changed".
    public let pageURL: URL
    /// The `Huske.app.zip` asset, when the release has one.
    public let downloadURL: URL?

    public init(tag: String, pageURL: URL, downloadURL: URL?) {
        self.tag = tag
        self.pageURL = pageURL
        self.downloadURL = downloadURL
    }

    /// Releases are tagged `vX.Y.Z`; EngineVersion already knows how to order
    /// those numerically (never lexically — `0.9.0` is not above `0.11.0`).
    public var version: EngineVersion? {
        EngineVersion(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag)
    }
}

public enum AppUpdateCheck {
    public static let assetName = "Huske.app.zip"
    public static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/tiagomoraes/huske/releases/latest")!

    // MARK: pure

    /// Parse GitHub's `releases/latest` payload. Returns nil for anything
    /// unexpected — a check that cannot be trusted must not raise an alarm.
    public static func parse(_ data: Data) -> AppRelease? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = root["tag_name"] as? String, !tag.isEmpty,
            let page = (root["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        if root["draft"] as? Bool == true || root["prerelease"] as? Bool == true {
            return nil
        }
        let assets = root["assets"] as? [[String: Any]] ?? []
        let download = assets
            .first { $0["name"] as? String == assetName }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap(URL.init(string:))
        return AppRelease(tag: tag, pageURL: page, downloadURL: download)
    }

    /// Strictly newer than what is running. An unparseable version on either
    /// side means "say nothing".
    public static func isNewer(_ release: AppRelease, than current: String) -> Bool {
        guard let latest = release.version, let running = EngineVersion(current) else {
            return false
        }
        return latest > running
    }

    public static func isDisabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let raw = (environment["HUSKE_NO_UPDATE_CHECK"] ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        return ["1", "true", "yes", "on"].contains(raw)
    }

    // MARK: cache

    /// Shares a directory with the engine's PyPI check, and its 24 h rhythm.
    public static func cacheURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let explicit = environment["HUSKE_APP_UPDATE_CACHE"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }
        let base = environment["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache", isDirectory: true)
        return base
            .appendingPathComponent("huske", isDirectory: true)
            .appendingPathComponent("app-update-check.json")
    }

    struct CachedCheck: Codable {
        let checkedAt: Date
        let release: AppRelease?
    }

    static func loadCache(at url: URL) -> CachedCheck? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedCheck.self, from: data)
    }

    static func storeCache(_ check: CachedCheck, at url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(check) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func isFresh(_ checkedAt: Date, ttl: TimeInterval = 24 * 60 * 60, now: Date = Date())
        -> Bool
    {
        now.timeIntervalSince(checkedAt) < ttl && checkedAt <= now
    }

    // MARK: network

    /// The newest release GitHub knows about, or nil on any failure.
    ///
    /// `force` skips the cache — what the menu command does, because a person
    /// who just asked deserves a real answer, not yesterday's.
    public static func latestRelease(force: Bool = false) async -> AppRelease? {
        guard !isDisabled() else { return nil }
        let cache = cacheURL()
        if !force, let cached = loadCache(at: cache), isFresh(cached.checkedAt) {
            return cached.release
        }
        var request = URLRequest(url: latestReleaseAPI)
        request.timeoutInterval = 8
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Huske.app", forHTTPHeaderField: "User-Agent")
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        let release = parse(data)
        storeCache(CachedCheck(checkedAt: Date(), release: release), at: cache)
        return release
    }

    /// The release to tell the user about, or nil when they are current.
    public static func availableUpdate(currentVersion: String, force: Bool = false) async
        -> AppRelease?
    {
        guard let release = await latestRelease(force: force),
            isNewer(release, than: currentVersion)
        else { return nil }
        return release
    }
}
