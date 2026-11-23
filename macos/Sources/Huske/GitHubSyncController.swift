// "Connect GitHub" for Cloud sync. The engine owns the sign-in (device flow,
// Keychain, token refresh — ADR 0009); this controller only runs
// `huske sync … --json` and keeps what the pane renders.

import AppKit
import HuskeKit
import Observation

@MainActor
@Observable
final class GitHubSyncController {
    enum Login: Equatable {
        case idle
        case starting
        case waiting(GitHubDeviceCode)
    }

    /// `false` when the engine predates `huske sync login` — the pane then
    /// shows only the manual repository URL.
    private(set) var supported: Bool?
    private(set) var status: GitHubSyncStatus?
    private(set) var shared: GitHubSharedRepositories?
    private(set) var login: Login = .idle
    private(set) var loadingShared = false
    private(set) var working = false
    private(set) var message: String?

    @ObservationIgnored private var loginProcess: EngineProcess?

    var connected: Bool { status?.connected == true }

    // MARK: status

    func refresh(binary: URL?) async {
        guard let binary else { return }
        do {
            let result = try await CLIRunner.run(
                binary: binary, arguments: ["sync", "status", "--json"], timeout: 30)
            let output = result.stdout + result.stderr
            if result.status != 0, output.contains("No such command") {
                supported = false
                return
            }
            supported = true
            for event in GitHubSyncEvent.parseAll(result.stdout) {
                switch event {
                case .status(let status):
                    self.status = status
                case .error(let text, _):
                    message = text
                default:
                    break
                }
            }
        } catch {
            message = AppModel.describe(error)
        }
    }

    func loadShared(binary: URL?) async {
        guard let binary, connected else { return }
        loadingShared = true
        defer { loadingShared = false }
        do {
            let result = try await CLIRunner.run(
                binary: binary, arguments: ["sync", "repos", "--json"], timeout: 60)
            for event in GitHubSyncEvent.parseAll(result.stdout) {
                switch event {
                case .shared(let shared):
                    self.shared = shared
                    message = nil
                case .error(let text, let reconnect):
                    message = text
                    if reconnect { await refresh(binary: binary) }
                default:
                    break
                }
            }
        } catch {
            message = AppModel.describe(error)
        }
    }

    // MARK: sign-in

    func connect(binary: URL?) {
        guard let binary, loginProcess == nil else { return }
        message = nil
        login = .starting
        let process = EngineProcess(
            binary: binary, arguments: ["sync", "login", "--json"],
            environment: ["HUSKE_NO_UPDATE_CHECK": "1"])
        process.onOutputLine = { [weak self] line in
            guard let event = GitHubSyncEvent.parse(line) else { return }
            Task { @MainActor in self?.handleLogin(event, binary: binary) }
        }
        process.onTermination = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.loginProcess = nil
                if self.login != .idle { self.login = .idle }
            }
        }
        do {
            try process.launch()
            loginProcess = process
        } catch {
            login = .idle
            message = AppModel.describe(error)
        }
    }

    private func handleLogin(_ event: GitHubSyncEvent, binary: URL) {
        switch event {
        case .code(let code):
            login = .waiting(code)
        case .connected:
            login = .idle
            Task {
                await refresh(binary: binary)
                await loadShared(binary: binary)
            }
        case .error(let text, _):
            login = .idle
            message = text
        default:
            break
        }
    }

    func cancelLogin() {
        loginProcess?.terminate()
        loginProcess = nil
        login = .idle
    }

    /// Put the code on the clipboard and open GitHub's device page.
    func copyCodeAndOpenGitHub(_ code: GitHubDeviceCode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code.userCode, forType: .string)
        if let url = URL(string: code.verificationUri) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: repository

    /// Point sync at `fullName` (private, shared with the app). `true` on success.
    func use(_ fullName: String, binary: URL?) async -> Bool {
        guard let binary else { return false }
        working = true
        defer { working = false }
        do {
            let result = try await CLIRunner.run(
                binary: binary, arguments: ["sync", "use", fullName, "--json"], timeout: 60)
            var ok = false
            for event in GitHubSyncEvent.parseAll(result.stdout) {
                switch event {
                case .using:
                    ok = true
                    message = nil
                case .error(let text, _):
                    message = text
                default:
                    break
                }
            }
            await refresh(binary: binary)
            return ok && result.status == 0
        } catch {
            message = AppModel.describe(error)
            return false
        }
    }

    func disconnect(binary: URL?) async {
        guard let binary else { return }
        working = true
        defer { working = false }
        do {
            let result = try await CLIRunner.run(
                binary: binary, arguments: ["sync", "logout", "--json"], timeout: 60)
            for case .error(let text, _) in GitHubSyncEvent.parseAll(result.stdout) {
                message = text
            }
        } catch {
            message = AppModel.describe(error)
        }
        shared = nil
        await refresh(binary: binary)
    }

    func clearMessage() { message = nil }

    /// Preview/render seam: set the state a screen shows without the engine.
    func _previewInject(
        supported: Bool = true, status: GitHubSyncStatus?,
        shared: GitHubSharedRepositories? = nil, login: Login = .idle
    ) {
        self.supported = supported
        self.status = status
        self.shared = shared
        self.login = login
    }
}
