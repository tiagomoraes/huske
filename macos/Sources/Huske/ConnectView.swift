// The Connect pane: get an LLM reading your transcripts without a terminal.
//
// Every row is a step from `huske setup --json`, and every button runs
// `huske setup --apply <step>` or supervises `huske mcp`. No judgement lives
// here — the engine decides what is done, what is next, and what a step's fix
// is, so the pane and the CLI can never tell you different things (ADR 0006).
//
// The one thing this pane refuses to do is pretend: connecting a phone needs a
// server the user has to own, so that row explains the prerequisite instead of
// offering a button that cannot work.

import HuskeKit
import SwiftUI

struct ConnectView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PaneScroll {
            VStack(alignment: .leading, spacing: 14) {
                PaneHeader(
                    "Connect",
                    subtitle: "Let Claude, ChatGPT, or any agent search what was said. "
                        + "Runs on this Mac."
                ) {
                    if model.setupRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            model.refreshSetup()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(.top, 30)

                if let error = model.setupError {
                    Card {
                        Label {
                            Text(error).font(.brandSans(12.5))
                        } icon: {
                            Image(systemName: "xmark.octagon.fill")
                        }
                        .foregroundStyle(Theme.err)
                    }
                }

                if let report = model.setupReport {
                    statusCard(report)
                    stepsCard(report)
                    if !model.setupApplyLog.isEmpty {
                        InstallConsole(lines: model.setupApplyLog)
                    }
                    phoneCard(report)
                } else if !model.setupRunning {
                    Card {
                        Text("Checking what's set up…")
                            .font(.brandSans(12.5))
                            .foregroundStyle(Theme.fgMuted)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .task { model.refreshSetup() }
    }

    // MARK: status

    private func statusCard(_ report: SetupReport) -> some View {
        let remaining = report.actionable.count
        return Card {
            HStack(spacing: 14) {
                Image(systemName: report.ready ? "checkmark.seal.fill" : "arrow.right.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(report.ready ? Theme.ok : Theme.amber)
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.ready ? "Ready" : stepsLeftLabel(remaining))
                        .font(.brandSans(14, .semibold))
                        .foregroundStyle(Theme.fg)
                    Text(
                        report.ready
                            ? "Ask your agent something only a meeting would know — "
                                + "\"what did we decide about pricing?\""
                            : "Work through the steps below. Each one has a button."
                    )
                    .font(.brandSans(12))
                    .foregroundStyle(Theme.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
    }

    private func stepsLeftLabel(_ count: Int) -> String {
        count == 1 ? "1 step left" : "\(count) steps left"
    }

    // MARK: steps

    private func stepsCard(_ report: SetupReport) -> some View {
        let rows = report.steps.filter { $0.key != "connector" }
        return Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Steps")
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, step in
                    if index > 0 {
                        Rectangle()
                            .fill(Theme.divider)
                            .frame(height: 1)
                            .padding(.leading, 44)
                    }
                    stepRow(step)
                }
            }
        }
    }

    @ViewBuilder
    private func stepRow(_ step: SetupStep) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: glyph(step.state))
                .font(.system(size: 13))
                .foregroundStyle(tint(step.state))
                .frame(width: 20)
                .padding(.top, 1)
                .accessibilityLabel(accessibleState(step.state))

            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.brandSans(13, .medium))
                    .foregroundStyle(Theme.fg)
                if !step.detail.isEmpty {
                    Text(step.detail)
                        .font(.brandSans(12))
                        .foregroundStyle(Theme.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // A command is only shown when the app genuinely cannot do it —
                // installing software into someone's Python is theirs to run.
                if let fix = step.fix, !canAct(step) {
                    InstallCommandRow(label: "run", command: fix)
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 8)
            action(for: step)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func action(for step: SetupStep) -> some View {
        let busy = model.applyingStep == step.key
        switch step.key {
        case "server":
            serverAction(step)
        case "index":
            if step.state != .ok && step.canApply {
                Button {
                    model.applySetupStep("index")
                } label: {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Build index")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.applyingStep != nil)
            }
        case "claude-desktop", "claude-code":
            if step.canApply {
                Button {
                    model.applySetupStep(step.key)
                } label: {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Connect")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.applyingStep != nil)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func serverAction(_ step: SetupStep) -> some View {
        if model.searchServer.isBusy {
            ProgressView().controlSize(.small)
        } else if step.state == .ok || model.searchServer.isRunning {
            Button("Stop") { model.stopSearchServer() }
                .buttonStyle(SecondaryButtonStyle())
        } else {
            Button("Start") { model.startSearchServer() }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    /// True when the pane offers a control for this step, so the raw command can
    /// be hidden — showing both invites the user to do it twice.
    private func canAct(_ step: SetupStep) -> Bool {
        switch step.key {
        case "server": return true
        case "index", "claude-desktop", "claude-code": return step.canApply
        default: return false
        }
    }

    // MARK: other devices

    private func phoneCard(_ report: SetupReport) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "iphone.gen3")
                        .foregroundStyle(Theme.fgMuted)
                    Text("From your phone")
                        .font(.brandSans(13, .semibold))
                        .foregroundStyle(Theme.fg)
                    if report.connectorURL == nil {
                        Text("needs a server")
                            .font(.brandMono(10, .medium))
                            .foregroundStyle(Theme.fgFaint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4).fill(Theme.bgElevated))
                    }
                }
                if let url = report.connectorURL {
                    Text(
                        "Connector mode is on. Add this as a custom connector in Claude "
                            + "(Settings → Connectors) or ChatGPT, and sign in with your "
                            + "passphrase."
                    )
                    .font(.brandSans(12))
                    .foregroundStyle(Theme.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    InstallCommandRow(label: "url", command: url)
                } else {
                    Text(
                        "This Mac answers only while it is awake and on your network. "
                            + "Reaching your transcripts from a phone needs an always-on "
                            + "server you control, with TLS and a reverse proxy — it is a "
                            + "real setup, not a switch, so huske will not pretend "
                            + "otherwise."
                    )
                    .font(.brandSans(12))
                    .foregroundStyle(Theme.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    Link(
                        "Read what it takes →",
                        destination: URL(
                            string:
                                "https://github.com/tiagomoraes/huske/blob/main/docs/integrations.md"
                        )!
                    )
                    .font(.brandSans(12, .medium))
                    .foregroundStyle(Theme.amber)
                }
            }
        }
    }

    // MARK: state presentation

    private func glyph(_ state: SetupState) -> String {
        switch state {
        case .ok: return "checkmark.circle.fill"
        case .todo: return "circle"
        case .blocked: return "exclamationmark.triangle.fill"
        case .optional: return "minus.circle"
        }
    }

    private func tint(_ state: SetupState) -> Color {
        switch state {
        case .ok: return Theme.ok
        case .todo: return Theme.amber
        case .blocked: return Theme.err
        case .optional: return Theme.fgFaint
        }
    }

    /// Colour alone must not carry the state (WCAG); VoiceOver gets the word.
    private func accessibleState(_ state: SetupState) -> String {
        switch state {
        case .ok: return "done"
        case .todo: return "to do"
        case .blocked: return "blocked"
        case .optional: return "optional"
        }
    }
}
