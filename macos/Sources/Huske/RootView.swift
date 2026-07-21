import HuskeKit
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case record
    case transcripts
    case doctor
    case configuration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .record: return "Record"
        case .transcripts: return "Transcripts"
        case .doctor: return "Doctor"
        case .configuration: return "Configuration"
        }
    }

    var symbol: String {
        switch self {
        case .record: return "waveform"
        case .transcripts: return "doc.text"
        case .doctor: return "stethoscope"
        case .configuration: return "slider.horizontal.3"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem = .record

    var body: some View {
        @Bindable var model = model
        Group {
            if model.binaryMissing {
                OnboardingView()
            } else {
                NavigationSplitView {
                    sidebar
                } detail: {
                    detail
                }
            }
        }
        .background(Theme.bg)
        .sheet(isPresented: $model.recoverSheetVisible) {
            RecoverSheet()
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.symbol)
                        .tag(item)
                }
            }
            Section {
                sessionBadge
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var sessionBadge: some View {
        let session = model.session
        if session.isBusy, let snap = session.snapshot {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(snap.stopping ? Theme.warn : (snap.paused ? Theme.warn : Theme.recordRed))
                        .frame(width: 7, height: 7)
                    Text(snap.stopping ? "Finishing…" : (snap.paused ? "Paused" : "Recording"))
                        .font(.system(size: 11, weight: .semibold))
                }
                Text("chunk \(String(format: "%03d", snap.currentChunkSeq)) · queue \(snap.queueDepth)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.fgMuted)
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .record: RecordView()
        case .transcripts: TranscriptsView()
        case .doctor: DoctorView()
        case .configuration: ConfigView()
        }
    }
}

// MARK: - onboarding (engine binary missing)

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var pickingBinary = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 20) {
                LogoMark(size: 76)
                Text("Welcome to huske")
                    .font(.system(size: 26, weight: .bold))
                Text(
                    "This app drives the huske command-line engine, and it "
                        + "doesn't seem to be installed yet. Install it, then come back."
                )
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.fgMuted)
                .frame(maxWidth: 440)

                VStack(alignment: .leading, spacing: 10) {
                    InstallCommandRow(label: "uv", command: "uv tool install \"huske[mcp]\"")
                    InstallCommandRow(label: "brew", command: "brew install tiagomoraes/huske/huske")
                }
                .frame(maxWidth: 440)

                HStack(spacing: 12) {
                    Button {
                        model.refreshBinary()
                        Task { await model.bootstrap() }
                    } label: {
                        Label("Check Again", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut(.defaultAction)

                    Button("Locate huske…") { pickingBinary = true }
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
            Spacer()
            Text("huske records and transcribes entirely on this Mac — nothing leaves your machine.")
                .font(.footnote)
                .foregroundStyle(Theme.fgFaint)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

struct InstallCommandRow: View {
    let label: String
    let command: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.fgMuted)
                .frame(width: 42, alignment: .leading)
            Text(command)
                .font(.system(size: 12, design: .monospaced))
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
                    .foregroundStyle(copied ? Theme.ok : Theme.fgMuted)
            }
            .buttonStyle(.plain)
            .help("Copy")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.bgElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.cardBorder.opacity(0.6), lineWidth: 1)
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
