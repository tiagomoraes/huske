// Cloud sync pane. Huske.app publishes finalized transcript files; the MCP
// service is a separate Linux/VPS package and never runs inside this app.

import HuskeKit
import SwiftUI

struct ConnectView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let config = model.config
        PaneScroll {
            VStack(alignment: .leading, spacing: 14) {
                PaneHeader(
                    "Cloud sync",
                    subtitle: "Publish finished transcripts to a private GitHub repository."
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

                        Toggle(isOn: config.boolBinding("sync_enabled")) {
                            settingLabel(
                                "Sync new transcripts automatically",
                                model.session.isBusy
                                    ? "Starts with the next recording session. Until then, use Sync now."
                                    : "Pulls first, then commits and pushes after every finalized transcript.")
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        // The engine refuses sync_enabled without a repository;
                        // don't offer a switch that can only fail.
                        .disabled(!hasRemote && !config.bool("sync_enabled"))

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

                        HStack(spacing: 10) {
                            Link(
                                "Create a private repository…",
                                destination: Self.newRepositoryURL)
                            .font(.brandSans(12, .medium))
                            .foregroundStyle(Theme.amber)
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
                            .disabled(model.syncRunning || !hasRemote)
                        }

                        // The recording engine's own sync runs in the background;
                        // its last problem stays here until a clean run clears it.
                        if let warning = model.session.snapshot?.warnings["sync"] {
                            Label {
                                Text(warning)
                                    .font(.brandSans(12))
                                    .foregroundStyle(Theme.fg)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Theme.warn)
                            }
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
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .task {
            if model.config.snapshot == nil, model.capabilities?.configCLI == true {
                await model.config.reload(binary: model.binaryURL)
            }
        }
    }

    private var hasRemote: Bool { !model.config.string("sync_remote").isEmpty }

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
