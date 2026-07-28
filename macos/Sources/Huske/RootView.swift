import HuskeKit
import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case record
    case transcripts
    case connect
    case doctor
    case configuration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .record: return "Record"
        case .transcripts: return "Transcripts"
        case .connect: return "Connect"
        case .doctor: return "Doctor"
        case .configuration: return "Configuration"
        }
    }

    var symbol: String {
        switch self {
        case .record: return "waveform"
        case .transcripts: return "text.document"
        case .connect: return "sparkles"
        case .doctor: return "stethoscope"
        case .configuration: return "slider.horizontal.3"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .record: return "1"
        case .transcripts: return "2"
        case .connect: return "3"
        case .doctor: return "4"
        case .configuration: return "5"
        }
    }
}

/// Custom chrome: the system title bar is hidden; a branded rail owns
/// navigation (traffic lights float over its top-left corner).
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.binaryMissing {
                OnboardingView()
            } else {
                HStack(spacing: 0) {
                    SidebarView()
                    Rectangle()
                        .fill(Theme.divider)
                        .frame(width: 1)
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.bg)
                }
                .overlay { CommandPaletteOverlay() }
            }
        }
        .ignoresSafeArea()
        .background(Theme.bg)
        .sheet(isPresented: $model.recoverSheetVisible) {
            RecoverSheet()
        }
        .onChange(of: model.session.snapshot?.recording) { _, recording in
            // Recording state at a glance from the Dock, matching the menu bar.
            NSApp.dockTile.badgeLabel = recording == true ? "REC" : nil
        }
        .onChange(of: model.session.isBusy) { _, busy in
            if !busy {
                NSApp.dockTile.badgeLabel = nil
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.pane {
        case .record: RecordView()
        case .transcripts: TranscriptsView()
        case .connect: ConnectView()
        case .doctor: DoctorView()
        case .configuration: ConfigView()
        }
    }
}

// MARK: - sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Clearance for the traffic lights, then the wordmark.
            wordmark
                .padding(.top, 44)
                .padding(.horizontal, 18)
                .padding(.bottom, 22)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Pane.allCases) { pane in
                    SidebarItemView(pane: pane)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            // Always present, in every state — the transport is chrome, and a
            // box that comes and goes would move the footer under the cursor.
            TransportDock()
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            footer
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
        }
        .frame(width: 216)
        .frame(maxHeight: .infinity)
        .background(Theme.bgSidebar)
    }

    private var wordmark: some View {
        HStack(spacing: 9) {
            LogoMark(size: 26)
            // The one soft moment in the system: "huske" in italic serif.
            Text("huske")
                .font(.brandSerifItalic(19))
                .foregroundStyle(Theme.fg)
                .baselineOffset(1)
        }
        .accessibilityAddTraits(.isHeader)
    }

    private var footer: some View {
        Text(model.isDemo ? "demo session" : "v\(model.binaryVersion ?? "—")")
            .font(.brandMono(10))
            .foregroundStyle(Theme.fgFaint)
    }
}

struct SidebarItemView: View {
    @Environment(AppModel.self) private var model
    let pane: Pane
    @State private var hovering = false

    var body: some View {
        let selected = model.pane == pane
        Button {
            model.pane = pane
        } label: {
            HStack(spacing: 10) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Theme.amber : Theme.fgMuted)
                    .frame(width: 18)
                Text(pane.title)
                    .font(.brandSans(13, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.fg : Theme.fgMuted)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMD, style: .continuous)
                    .fill(
                        selected
                            ? Theme.amber.opacity(0.14)
                            : (hovering ? Theme.divider.opacity(0.7) : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusMD))
        }
        .buttonStyle(.plain)
        .pointingCursor(hovering: $hovering)
        .keyboardShortcut(pane.shortcut, modifiers: [.command])
        .animation(Theme.easeFast, value: hovering)
        .accessibilityLabel(pane.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - onboarding (engine binary missing)

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 22) {
                LogoMark(size: 76)
                VStack(spacing: 10) {
                    (Text("Welcome to ").font(.brandSans(26, .semibold))
                        + Text("huske").font(.brandSerifItalic(26)))
                        .foregroundStyle(Theme.fg)
                    Text(
                        "Huske needs its recording engine — a one-time, local "
                            + "install. Everything runs on this Mac."
                    )
                    .font(.brandSans(13))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.fgMuted)
                    .lineSpacing(3)
                    .frame(maxWidth: 420)
                }

                EngineSetupActions(kind: .install)
                    .frame(maxWidth: 460)
            }
            Spacer()
            Text("huske records and transcribes entirely on this Mac — nothing leaves your machine.")
                .font(.brandSans(12))
                .foregroundStyle(Theme.fgFaint)
                .padding(.bottom, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        // If the user installs from a terminal instead, notice and move on.
        .task { await model.pollForBinary() }
    }
}

/// Install/upgrade actions shared by onboarding and the outdated-engine
/// screen: one click when a package manager is already on the Mac, copyable
/// commands otherwise, with the manager's output streamed live.
struct EngineSetupActions: View {
    let kind: EngineInstaller.Kind
    @Environment(AppModel.self) private var model
    @State private var installer = EngineInstaller()
    @State private var pickingBinary = false

    private var manager: EngineInstaller.Manager? {
        if kind == .upgrade, let binary = model.binaryURL,
            let owner = EngineInstaller.owner(of: binary)
        {
            return owner
        }
        return EngineInstaller.available().first
    }

    var body: some View {
        VStack(spacing: 14) {
            if !installer.log.isEmpty {
                InstallConsole(lines: installer.log)
            }
            if installer.running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(kind == .install
                        ? "Installing the huske engine…"
                        : "Upgrading the huske engine…")
                        .font(.brandSans(12))
                        .foregroundStyle(Theme.fgMuted)
                }
            } else {
                actions
            }
        }
        .fileImporter(
            isPresented: $pickingBinary,
            allowedContentTypes: [.unixExecutable, .executable, .item]
        ) { result in
            if case .success(let url) = result {
                model.setBinaryOverride(url.path)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if installer.failed {
            Text("That didn't finish cleanly — the log above has the details. You can retry, or install from a terminal.")
                .font(.brandSans(12))
                .foregroundStyle(Theme.err)
                .multilineTextAlignment(.center)
        }
        if let manager {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Button {
                        Task {
                            if await installer.run(kind, using: manager) {
                                model.refreshBinary()
                                await model.bootstrap()
                            }
                        }
                    } label: {
                        Label(
                            kind == .install
                                ? "Install with \(manager.displayName)"
                                : "Upgrade with \(manager.displayName)",
                            systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)

                    checkAgainButton
                    locateButton
                }
                Text("runs `\(manager.commandLine(for: kind))`")
                    .font(.brandMono(10.5))
                    .foregroundStyle(Theme.fgFaint)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                InstallCommandRow(
                    label: "uv",
                    command: EngineInstaller.Manager.uv.commandLine(for: kind))
                InstallCommandRow(
                    label: "brew",
                    command: EngineInstaller.Manager.brew.commandLine(for: kind))
            }
            HStack(spacing: 10) {
                checkAgainButton
                locateButton
            }
            Text("No uv or Homebrew found for a one-click install — run either command in a terminal; huske appears here by itself.")
                .font(.brandSans(11.5))
                .foregroundStyle(Theme.fgFaint)
                .multilineTextAlignment(.center)
        }
    }

    private var checkAgainButton: some View {
        Button {
            model.refreshBinary()
            Task { await model.bootstrap() }
        } label: {
            Label("Check Again", systemImage: "arrow.clockwise")
        }
        .buttonStyle(SecondaryButtonStyle())
    }

    private var locateButton: some View {
        Button("Locate huske…") { pickingBinary = true }
            .buttonStyle(SecondaryButtonStyle())
    }
}

/// Streamed package-manager output, auto-scrolled, in the recover-sheet's
/// sunken console voice.
struct InstallConsole: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.brandMono(10.5))
                            .foregroundStyle(Theme.fg)
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 150)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMD, style: .continuous)
                    .fill(Theme.bgSunken.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusMD, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            )
            .onChange(of: lines.count) {
                proxy.scrollTo(lines.count - 1, anchor: .bottom)
            }
        }
    }
}

struct InstallCommandRow: View {
    let label: String
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.brandMono(11, .medium))
                .foregroundStyle(Theme.fgMuted)
                .frame(width: 48, alignment: .leading)
            Text(command)
                .font(.brandMono(12))
                .foregroundStyle(Theme.fg)
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(copied ? Theme.ok : Theme.fgMuted)
            }
            .buttonStyle(.plain)
            .pointingCursor()
            .help("Copy")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusMD, style: .continuous)
                .fill(Theme.bgElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusMD, style: .continuous)
                .strokeBorder(Theme.cardBorder, lineWidth: 1)
        )
    }
}

/// The huske logo mark (amber bar + paper lines), drawn natively.
struct LogoMark: View {
    var size: CGFloat = 64

    var body: some View {
        Canvas { context, canvasSize in
            let u = canvasSize.width / 64.0
            func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color) {
                let rect = CGRect(x: x * u, y: y * u, width: w * u, height: h * u)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1.2 * u), with: .color(color))
            }
            context.fill(
                Path(
                    roundedRect: CGRect(origin: .zero, size: canvasSize),
                    cornerRadius: 14 * u),
                with: .color(Color(nsColor: NSColor(rgb: 0x0E1116))))
            bar(14, 10, 6, 44, Color(nsColor: NSColor(rgb: 0xD88A3A)))
            bar(24, 24, 26, 5, Color(nsColor: NSColor(rgb: 0xF4EFE3)))
            bar(24, 34, 20, 5, Color(nsColor: NSColor(rgb: 0xF4EFE3)))
            bar(24, 44, 14, 5, Color(nsColor: NSColor(rgb: 0xF4EFE3)))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("huske logo")
    }
}
