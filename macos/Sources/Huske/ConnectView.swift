// Cloud sync pane. Huske.app publishes finalized transcript files; the MCP
// service is a separate Linux/VPS package and never runs inside this app.
//
// Two ways to reach GitHub: "Connect GitHub" (the Huske Sync app — no SSH,
// a token scoped to one repository; the engine owns the sign-in) and the
// manual repository URL that uses this Mac's own Git sign-in.

import AppKit
import HuskeKit
import SwiftUI

struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.screenRendering) private var rendering
    /// The user asked for the manual (SSH / own Git sign-in) setup.
    @State private var manualRequested = false
    /// Picking a different repository while already publishing.
    @State private var choosingRepository = false

    var body: some View {
        let config = model.config
        PaneScroll {
            VStack(alignment: .leading, spacing: 14) {
                PaneHeader(
                    "Cloud sync",
                    subtitle:
                        "Keep a private copy of your transcripts on GitHub, where your AI tools can read them."
                )
                .padding(.top, 30)

                Card {
                    VStack(alignment: .leading, spacing: 13) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "lock.shield")
                                .foregroundStyle(Theme.amber)
                            Text(
                                "Only transcript Markdown is synced. Audio, screenshots, "
                                    + "logs, configuration, and credentials stay on this Mac."
                            )
                            .font(.brandSans(12))
                            .foregroundStyle(Theme.fgMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        if showsManualSetup {
                            manualSetup
                        } else {
                            githubSetup
                        }

                        if let message = model.github.message {
                            notice(message, color: Theme.err)
                        }

                        if hasRemote {
                            Divider().padding(.vertical, 2)
                            publishControls
                        }
                    }
                }

                if let error = config.writeError {
                    Card {
                        Label {
                            Text(error)
                                .font(.brandSans(12))
                                .textSelection(.enabled)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(Theme.err)
                    }
                }

                if let message = model.syncMessage {
                    Card {
                        HStack(alignment: .top, spacing: 9) {
                            Image(
                                systemName:
                                    model.syncSucceeded == true
                                    ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(model.syncSucceeded == true ? Theme.ok : Theme.err)
                            Text(message)
                                .font(.brandMono(11))
                                .foregroundStyle(Theme.fgMuted)
                                .textSelection(.enabled)
                        }
                    }
                }

                agentsCard
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .task {
            guard !rendering else { return }
            if model.config.snapshot == nil, model.capabilities?.configCLI == true {
                await model.config.reload(binary: model.binaryURL)
            }
            await refreshGitHub()
        }
        // Coming back from the browser (approved the app, created or shared a
        // repository) is the moment the answer changes.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !rendering else { return }
            Task { await refreshGitHub() }
        }
    }

    // MARK: mode

    private var hasRemote: Bool { !model.config.string("sync_remote").isEmpty }

    private var showsManualSetup: Bool {
        let github = model.github
        if github.supported == false { return true }
        if github.status?.usesGitHubApp == true { return false }
        if manualRequested { return true }
        // Someone already publishing with their own Git sign-in keeps that
        // setup until they choose Connect GitHub.
        return hasRemote && model.config.string("sync_auth", default: "git") != "github-app"
            && !github.connected && github.login == .idle
    }

    private func refreshGitHub() async {
        await model.github.refresh(binary: model.binaryURL)
        if model.github.connected,
            model.github.status?.repository == nil || choosingRepository
        {
            await model.github.loadShared(binary: model.binaryURL)
        }
    }

    // MARK: Connect GitHub

    @ViewBuilder
    private var githubSetup: some View {
        let github = model.github
        switch github.login {
        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking GitHub for a sign-in code…")
                    .font(.brandSans(12))
                    .foregroundStyle(Theme.fgMuted)
            }
        case .waiting(let code):
            waitingForApproval(code)
        case .idle:
            if github.connected {
                connectedSetup
            } else {
                connectPrompt
            }
        }
    }

    private var connectPrompt: some View {
        let expired = model.github.status?.usesGitHubApp == true
        return VStack(alignment: .leading, spacing: 10) {
            Text(
                expired
                    ? "The GitHub sign-in expired or was revoked. Connect again to keep publishing."
                    : "Connect your GitHub account. Huske Sync can only read and write the one "
                        + "private repository you share with it. It can't see, create, or delete "
                        + "anything else."
            )
            .font(.brandSans(12.5))
            .foregroundStyle(Theme.fg)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button("Connect GitHub") {
                    model.github.connect(binary: model.binaryURL)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.binaryURL == nil)
                Button("Use an SSH key instead") {
                    manualRequested = true
                }
                .buttonStyle(LinkButtonStyle())
            }
        }
    }

    private func waitingForApproval(_ code: GitHubDeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enter this code on GitHub, then approve Huske Sync.")
                .font(.brandSans(12.5))
                .foregroundStyle(Theme.fg)
            Text(code.userCode)
                .font(.brandSans(26, .semibold))
                .monospacedDigit()
                .tracking(2)
                .foregroundStyle(Theme.fg)
                .textSelection(.enabled)
            HStack(spacing: 14) {
                Button("Copy code and open GitHub") {
                    model.github.copyCodeAndOpenGitHub(code)
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("Cancel") {
                    model.github.cancelLogin()
                }
                .buttonStyle(LinkButtonStyle())
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for your approval on GitHub…")
                    .font(.brandSans(11))
                    .foregroundStyle(Theme.fgMuted)
            }
        }
    }

    @ViewBuilder
    private var connectedSetup: some View {
        let github = model.github
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.ok)
                Text("Connected to GitHub as @\(github.status?.login ?? "")")
                    .font(.brandSans(12.5))
                    .foregroundStyle(Theme.fg)
                Spacer()
                Button("Disconnect") {
                    choosingRepository = false
                    model.disconnectGitHub()
                }
                .buttonStyle(LinkButtonStyle())
                .disabled(github.working)
            }

            if let repository = github.status?.repository, github.status?.usesGitHubApp == true,
                !choosingRepository
            {
                HStack(spacing: 10) {
                    Text("Publishing to \(repository)")
                        .font(.brandSans(12.5, .medium))
                        .foregroundStyle(Theme.fg)
                    if let url = URL(string: "https://github.com/\(repository)") {
                        Link("Open on GitHub", destination: url)
                            .font(.brandSans(12))
                            .foregroundStyle(Theme.amber)
                    }
                    Spacer()
                    Button("Change") {
                        choosingRepository = true
                        Task { await model.github.loadShared(binary: model.binaryURL) }
                    }
                    .buttonStyle(LinkButtonStyle())
                }
            } else {
                repositoryPicker
            }
        }
    }

    @ViewBuilder
    private var repositoryPicker: some View {
        let github = model.github
        let shared = github.shared
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose where your transcripts go:")
                .font(.brandSans(12.5))
                .foregroundStyle(Theme.fg)

            step(
                1, "Create a private repository for them.",
                link: "Create on GitHub…",
                url: URL(string: shared?.newRepositoryUrl ?? github.status?.newRepositoryUrl ?? ""))
            step(
                2, "Share it with Huske Sync: choose “Only select repositories” and pick it.",
                link: "Share on GitHub…",
                url: URL(
                    string: shared?.installationSettingsUrl ?? shared?.installUrl
                        ?? github.status?.installUrl ?? ""))

            if let shared, !shared.usable.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(shared.usable) { repo in
                        HStack(spacing: 10) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.fgMuted)
                            Text(repo.fullName)
                                .font(.brandSans(12.5))
                                .foregroundStyle(Theme.fg)
                            Spacer()
                            Button("Publish here") {
                                choosingRepository = false
                                model.useGitHubRepository(repo.fullName)
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(github.working || model.syncRunning)
                        }
                    }
                }
                .padding(.top, 2)
            }

            if let shared {
                ForEach(shared.publicOnes) { repo in
                    Text("\(repo.fullName) is public, so Huske won't publish there.")
                        .font(.brandSans(11))
                        .foregroundStyle(Theme.fgMuted)
                }
                if shared.sharesEverything, let settings = shared.installationSettingsUrl,
                    let url = URL(string: settings)
                {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warn)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(
                                "Huske Sync can see all your repositories. It only needs the "
                                    + "one with your transcripts."
                            )
                            .font(.brandSans(12))
                            .foregroundStyle(Theme.fg)
                            .fixedSize(horizontal: false, vertical: true)
                            Link("Limit access on GitHub…", destination: url)
                                .font(.brandSans(12))
                                .foregroundStyle(Theme.amber)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button("Check again") {
                    Task { await model.github.loadShared(binary: model.binaryURL) }
                }
                .buttonStyle(LinkButtonStyle())
                .disabled(github.loadingShared)
                if github.loadingShared || github.working {
                    ProgressView().controlSize(.small)
                }
                if choosingRepository {
                    Button("Keep the current repository") { choosingRepository = false }
                        .buttonStyle(LinkButtonStyle())
                }
            }
        }
    }

    private func step(_ number: Int, _ text: String, link: String, url: URL?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(.brandSans(12))
                .foregroundStyle(Theme.fgMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.brandSans(12))
                    .foregroundStyle(Theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
                if let url {
                    Link(link, destination: url)
                        .font(.brandSans(12))
                        .foregroundStyle(Theme.amber)
                }
            }
        }
    }

    // MARK: manual setup (this Mac's own Git sign-in)

    @ViewBuilder
    private var manualSetup: some View {
        let config = model.config
        LabeledRow("Repository", explicit: config.isExplicit("sync_remote")) {
            CommittingTextField(
                value: config.string("sync_remote"),
                prompt: "git@github.com:you/huske-transcripts.git"
            ) { value in
                if value.isEmpty {
                    config.unset("sync_remote")
                } else {
                    config.set("sync_remote", to: .string(value))
                }
            }
            .frame(maxWidth: 430)
        }

        Text(
            .init(
                "Uses this Mac's Git sign-in: an SSH key added to your GitHub "
                    + "account, or the HTTPS URL after `gh auth login`.")
        )
        .font(.brandSans(11))
        .foregroundStyle(Theme.fgMuted)
        .fixedSize(horizontal: false, vertical: true)

        LabeledRow("Branch", explicit: config.isExplicit("sync_branch")) {
            CommittingTextField(
                value: config.string("sync_branch", default: "main"),
                prompt: "main"
            ) { config.set("sync_branch", to: .string($0)) }
            .frame(maxWidth: 180)
        }

        HStack(spacing: 14) {
            Link("Create a private repository…", destination: Self.newRepositoryURL)
                .font(.brandSans(12, .medium))
                .foregroundStyle(Theme.amber)
            if model.github.supported != false {
                Button("Connect GitHub instead") {
                    manualRequested = false
                    model.github.connect(binary: model.binaryURL)
                }
                .buttonStyle(LinkButtonStyle())
            }
        }
    }

    // MARK: publishing

    @ViewBuilder
    private var publishControls: some View {
        let config = model.config
        Toggle(isOn: config.boolBinding("sync_enabled")) {
            settingLabel(
                "Sync new transcripts automatically",
                model.session.isBusy
                    ? "Starts with the next recording session. Until then, use Sync now."
                    : "Pulls first, then commits and pushes after every finalized transcript.")
        }
        .toggleStyle(.switch)
        .controlSize(.small)

        HStack {
            Spacer()
            Button {
                model.syncNow()
            } label: {
                if model.syncRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.syncRunning)
        }

        // The recording engine's own sync runs in the background; its last
        // problem stays here until a clean run clears it.
        if let warning = model.session.snapshot?.warnings["sync"] {
            notice(warning, color: Theme.warn)
        }
    }

    private func notice(_ text: String, color: Color) -> some View {
        Label {
            Text(text)
                .font(.brandSans(12))
                .foregroundStyle(Theme.fg)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(color)
        }
    }

    // MARK: agents

    private var agentsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                SectionLabel("Read it from your AI tools")
                Text(
                    "Claude, ChatGPT, Codex, Cursor, and GitHub Copilot can read this "
                        + "repository through their own GitHub integration, with no server "
                        + "to run. When one asks which repositories to allow, choose only "
                        + "this one, and turn off any setting that lets the vendor train "
                        + "on your content."
                )
                .font(.brandSans(12))
                .foregroundStyle(Theme.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
                // `.init` picks the LocalizedStringKey overload so the
                // Markdown code spans render as code, not as backticks.
                Text(
                    .init(
                        "For always-on search over MCP, run the separate `huske-mcp` "
                            + "service on a VPS. It pulls this repository, maintains a "
                            + "small SQLite index, and exposes `search`, `fetch`, `recap`, "
                            + "`overview`, and `sync_status`.")
                )
                .font(.brandSans(12))
                .foregroundStyle(Theme.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
                Link(
                    "VPS deployment guide →",
                    destination: URL(
                        string:
                            "https://github.com/tiagomoraes/huske/tree/develop/services/huske_mcp"
                    )!
                )
                .font(.brandSans(12, .medium))
                .foregroundStyle(Theme.amber)
            }
        }
    }

    /// GitHub's new-repository form, prefilled and private by default. The
    /// query parameters are documented; unknown ones are ignored by GitHub.
    static let newRepositoryURL = URL(
        string: "https://github.com/new?name=huske-transcripts&visibility=private"
            + "&description=Private%20meeting%20transcripts%20published%20by%20Huske")!

    private func settingLabel(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.brandSans(12.5))
                .foregroundStyle(Theme.fg)
            Text(subtitle)
                .font(.brandSans(11))
                .foregroundStyle(Theme.fgMuted)
        }
    }
}
