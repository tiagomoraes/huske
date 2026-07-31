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
                                "Pulls first, then commits and pushes after every finalized transcript.")
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)

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
                                destination: URL(string: "https://github.com/new")!)
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
                            .disabled(
                                model.syncRunning || config.string("sync_remote").isEmpty)
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
                        SectionLabel("Always-on agents")
                        // `.init` picks the LocalizedStringKey overload so the
                        // Markdown code spans render as code, not as backticks.
                        Text(
                            .init(
                                "Run the separate `huske-mcp` service on the VPS. It pulls this "
                                    + "repository, maintains a small SQLite index, and exposes "
                                    + "`search`, `fetch`, `recap`, `overview`, and `sync_status` "
                                    + "over MCP.")
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
