// What `huske sync login|logout|status|repos|use --json` prints, decoded.
//
// The engine owns the GitHub sign-in (device flow, Keychain, token refresh);
// the app only renders these events. One JSON object per line, each tagged
// with an "event" field.

import Foundation

public struct GitHubSyncStatus: Decodable, Equatable, Sendable {
    /// `"git"` (this Mac's own Git sign-in) or `"github-app"` (Huske Sync).
    public let auth: String
    public let connected: Bool
    public let login: String?
    /// `owner/repo` when publishing through Huske Sync.
    public let repository: String?
    public let remote: String?
    public let syncEnabled: Bool
    public let installUrl: String
    public let newRepositoryUrl: String

    public var usesGitHubApp: Bool { auth == "github-app" }

    public init(
        auth: String, connected: Bool, login: String?, repository: String?,
        remote: String?, syncEnabled: Bool, installUrl: String, newRepositoryUrl: String
    ) {
        self.auth = auth
        self.connected = connected
        self.login = login
        self.repository = repository
        self.remote = remote
        self.syncEnabled = syncEnabled
        self.installUrl = installUrl
        self.newRepositoryUrl = newRepositoryUrl
    }
}

public struct GitHubRepository: Decodable, Equatable, Sendable, Identifiable {
    public let fullName: String
    public let isPrivate: Bool
    public let htmlUrl: String

    public var id: String { fullName }

    enum CodingKeys: String, CodingKey {
        case fullName
        case isPrivate = "private"
        case htmlUrl
    }

    public init(fullName: String, isPrivate: Bool, htmlUrl: String = "") {
        self.fullName = fullName
        self.isPrivate = isPrivate
        self.htmlUrl = htmlUrl
    }
}

/// The repositories shared with the Huske Sync app's installation.
public struct GitHubSharedRepositories: Decodable, Equatable, Sendable {
    public let installed: Bool
    /// `"selected"` or `"all"`.
    public let repositorySelection: String?
    public let repositories: [GitHubRepository]
    public let installUrl: String
    public let installationSettingsUrl: String?
    public let newRepositoryUrl: String
    public let current: String?

    /// The app can see every repository: worth a nudge to narrow it.
    public var sharesEverything: Bool { repositorySelection == "all" }
    /// Huske only publishes to private repositories.
    public var usable: [GitHubRepository] { repositories.filter(\.isPrivate) }
    public var publicOnes: [GitHubRepository] { repositories.filter { !$0.isPrivate } }

    public init(
        installed: Bool, repositorySelection: String?, repositories: [GitHubRepository],
        installUrl: String, installationSettingsUrl: String?, newRepositoryUrl: String,
        current: String?
    ) {
        self.installed = installed
        self.repositorySelection = repositorySelection
        self.repositories = repositories
        self.installUrl = installUrl
        self.installationSettingsUrl = installationSettingsUrl
        self.newRepositoryUrl = newRepositoryUrl
        self.current = current
    }
}

public struct GitHubDeviceCode: Decodable, Equatable, Sendable {
    public let userCode: String
    public let verificationUri: String
    public let expiresIn: Int

    public init(userCode: String, verificationUri: String, expiresIn: Int) {
        self.userCode = userCode
        self.verificationUri = verificationUri
        self.expiresIn = expiresIn
    }
}

public enum GitHubSyncEvent: Equatable, Sendable {
    case status(GitHubSyncStatus)
    case shared(GitHubSharedRepositories)
    case code(GitHubDeviceCode)
    case connected(login: String)
    case using(repository: String)
    case disconnected
    /// `reconnect` means the sign-in itself is gone: offer Connect GitHub.
    case error(message: String, reconnect: Bool)

    private struct Tag: Decodable { let event: String }
    private struct Connected: Decodable { let login: String }
    private struct Using: Decodable { let repository: String }
    private struct Failure: Decodable {
        let message: String
        let reconnect: Bool?
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// One line of engine output; `nil` for anything that isn't an event.
    public static func parse(_ line: String) -> GitHubSyncEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
            let tag = try? decoder.decode(Tag.self, from: data)
        else { return nil }
        switch tag.event {
        case "status":
            return (try? decoder.decode(GitHubSyncStatus.self, from: data)).map { .status($0) }
        case "repos":
            return (try? decoder.decode(GitHubSharedRepositories.self, from: data)).map { .shared($0) }
        case "code":
            return (try? decoder.decode(GitHubDeviceCode.self, from: data)).map { .code($0) }
        case "connected":
            return (try? decoder.decode(Connected.self, from: data)).map { .connected(login: $0.login) }
        case "using":
            return (try? decoder.decode(Using.self, from: data)).map { .using(repository: $0.repository) }
        case "disconnected":
            return .disconnected
        case "error":
            return (try? decoder.decode(Failure.self, from: data)).map {
                .error(message: $0.message, reconnect: $0.reconnect ?? false)
            }
        default:
            return nil
        }
    }

    /// Every event in a block of output, in order.
    public static func parseAll(_ text: String) -> [GitHubSyncEvent] {
        text.components(separatedBy: "\n").compactMap(parse)
    }
}
