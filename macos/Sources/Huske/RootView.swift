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
        case .connect: return "Cloud sync"
        case .doctor: return "Doctor"
        case .configuration: return "Configuration"
        }
    }

    var symbol: String {
        switch self {
        case .record: return "waveform"
        case .transcripts: return "text.document"
        case .connect: return "icloud.and.arrow.up"
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
        VStack(alignment: .leading, spacing: 7) {
            if let update = model.appUpdate {
                UpdateChip(release: update)
            }
            Text(model.isDemo ? "demo session" : "v\(model.binaryVersion ?? "—")")
                .font(.brandMono(10))
                .foregroundStyle(Theme.fgFaint)
                .help("huske engine version")
        }
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
/// screen: one click when a package manager can actually reach the engine in
/// use, copyable commands otherwise, with the manager's output streamed live.
struct EngineSetupActions: View {
    let kind: EngineInstaller.Kind
    @Environment(AppModel.self) private var model
    @State private var installer = EngineInstaller()
    @State private var pickingBinary = false
    /// A manager reported success and the app is still driving the same old
    /// engine. Upgrading something the app does not use looks exactly like
    /// upgrading nothing, so this state has to be named out loud.
    @State private var upgradeMissedTarget = false

    /// The manager to offer, or nil for "no one-click upgrade would be honest".
    ///
    /// For an upgrade it must be the manager that owns the engine *in use*.
    /// Falling back to "whatever is installed on this Mac" is how the app came
    /// to offer `uv tool upgrade huske` for an engine uv had never seen: it
    /// exits 0, upgrades some other install, and this screen never changes.
    private var manager: EngineInstaller.Manager? {
        guard kind == .upgrade else { return EngineInstaller.available().first }
        guard case .managed(let owner) = model.engineProvenance else { return nil }
        return owner.locate() != nil ? owner : nil
    }

    /// What the copyable commands should say when no manager owns the engine.
    /// You cannot upgrade a source checkout — you install a released one.
    private var fallbackKind: EngineInstaller.Kind {
        model.engineProvenance == .sourceCheckout ? .install : kind
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
        if upgradeMissedTarget {
            Text(
                "The upgrade finished, but Huske is still pointed at "
                    + "\(model.binaryURL?.path ?? "the same engine")"
                    + " — it wasn't the one that got upgraded. Switch engines below."
            )
            .font(.brandSans(12))
            .foregroundStyle(Theme.err)
            .multilineTextAlignment(.center)
        }
        if kind == .upgrade {
            EngineSwitcher(prominent: manager == nil)
        }
        if let manager {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Button {
                        Task { await run(manager) }
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
                    command: EngineInstaller.Manager.uv.commandLine(for: fallbackKind))
                InstallCommandRow(
                    label: "brew",
                    command: EngineInstaller.Manager.brew.commandLine(for: fallbackKind))
            }
            HStack(spacing: 10) {
                checkAgainButton
                locateButton
            }
            Text(noManagerHint)
                .font(.brandSans(11.5))
                .foregroundStyle(Theme.fgFaint)
                .multilineTextAlignment(.center)
        }
    }

    private var noManagerHint: String {
        guard kind == .upgrade else {
            return "No uv or Homebrew found for a one-click install — run either command in a terminal; huske appears here by itself."
        }
        switch model.engineProvenance {
        case .sourceCheckout:
            return "This engine is a source checkout, so no package manager can upgrade it. Rebuild it in the repo, or install a released engine with one of the commands above."
        case .managed, .unknown:
            return "Nothing on this Mac manages that engine, so there is no upgrade to run in place — install a released engine with one of the commands above."
        }
    }

    private func run(_ manager: EngineInstaller.Manager) async {
        upgradeMissedTarget = false
        guard await installer.run(kind, using: manager) else { return }
        model.refreshBinary()
        await model.bootstrap()
        // Success from the manager is not success for the user: it may well
        // have upgraded an engine the app is not pointed at.
        upgradeMissedTarget = kind == .upgrade && !model.engineReady
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

/// What to offer when the selected engine will not run at all: switch to one
/// that does, unpin, repoint, or re-check.
///
/// Deliberately no upgrade button. A binary that never executed has no version
/// to move, and every package-manager offer here would act on something else.
struct EngineRepairActions: View {
    @Environment(AppModel.self) private var model
    @State private var pickingBinary = false

    var body: some View {
        let hasAlternatives = !model.healthyAlternatives.isEmpty
        VStack(spacing: 12) {
            EngineSwitcher(prominent: true)
            HStack(spacing: 10) {
                if model.binaryOverride != nil {
                    Button { model.clearBinaryOverride() } label: {
                        Label("Auto-detect", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(hasAlternatives ? AnyButtonStyle(SecondaryButtonStyle())
                                                 : AnyButtonStyle(PrimaryButtonStyle()))
                }
                Button {
                    model.refreshBinary()
                    Task { await model.bootstrap() }
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
                Button("Locate huske…") { pickingBinary = true }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if model.binaryOverride != nil {
                Text("Huske is pinned to that path in Settings (⌘,). Auto-detect drops the pin and drives the newest engine it can find.")
                    .font(.brandSans(11))
                    .foregroundStyle(Theme.fgFaint)
                    .multilineTextAlignment(.center)
            }
            if !hasAlternatives {
                VStack(alignment: .leading, spacing: 8) {
                    InstallCommandRow(
                        label: "uv",
                        command: EngineInstaller.Manager.uv.commandLine(for: .install))
                    InstallCommandRow(
                        label: "brew",
                        command: EngineInstaller.Manager.brew.commandLine(for: .install))
                }
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
}

/// Every *working* engine on this Mac that isn't the one in use, one click
/// each — the way out of a selection that can't be repaired from in here.
///
/// "Working" means it answered `--version`. A candidate that stayed silent is
/// not an escape route; it may be broken in exactly the same way.
struct EngineSwitcher: View {
    @Environment(AppModel.self) private var model
    /// The first row leads the screen when nothing better is on offer.
    var prominent = false

    var body: some View {
        let alternatives = model.healthyAlternatives
        if !alternatives.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(alternatives.count == 1
                    ? "Another engine is installed"
                    : "Other engines are installed")
                    .font(.brandSans(11, .semibold))
                    .foregroundStyle(Theme.fgFaint)
                    .textCase(.uppercase)
                ForEach(Array(alternatives.enumerated()), id: \.element.url) { index, candidate in
                    EngineSwitchRow(
                        candidate: candidate, prominent: prominent && index == 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct EngineSwitchRow: View {
    @Environment(AppModel.self) private var model
    let candidate: EngineCandidate
    var prominent = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("huske \(candidate.version?.description ?? "?")")
                    .font(.brandSans(12.5, .semibold))
                    .foregroundStyle(Theme.fg)
                Text(EngineSwitchRow.tildeAbbreviated(candidate.origin))
                    .font(.brandMono(10.5))
                    .foregroundStyle(Theme.fgFaint)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            Button("Use this engine") { model.useEngine(candidate) }
                .buttonStyle(prominent ? AnyButtonStyle(PrimaryButtonStyle())
                                       : AnyButtonStyle(SecondaryButtonStyle()))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusMD, style: .continuous)
                .fill(Theme.bgSunken.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusMD, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        )
    }

    /// Paths are shown to be read, not to be complete: `~/.local/bin` beats
    /// `/Users/<someone>/.local/bin` in a one-line row.
    static func tildeAbbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

/// A newer Huske.app exists. Deliberately quiet: it sits under the nav rail,
/// never in front of a session, and it links out rather than pretending the
/// app can replace itself.
struct UpdateChip: View {
    let release: AppRelease
    @State private var hovering = false

    var body: some View {
        Link(destination: release.downloadURL ?? release.pageURL) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 10))
                Text("Update \(release.tag)")
                    .font(.brandSans(10.5, .semibold))
            }
            .foregroundStyle(Theme.amber)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous)
                    .fill(Theme.amber.opacity(hovering ? 0.22 : 0.13))
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
        }
        .buttonStyle(.plain)
        .pointingCursor(hovering: $hovering)
        .animation(Theme.easeFast, value: hovering)
        .help("Download Huske \(release.tag)")
    }
}

/// Type eraser so one button can pick its style at runtime — SwiftUI's
/// `buttonStyle` takes a concrete type, and a ternary needs both branches to
/// agree.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { configuration in AnyView(style.makeBody(configuration: configuration)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
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
