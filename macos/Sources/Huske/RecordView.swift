import HuskeKit
import SwiftUI

struct RecordView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let session = model.session
        Group {
            if model.engineOutdated {
                EngineOutdatedView()
            } else {
                switch session.phase {
                case .idle:
                    IdleView()
                case .launching(let status):
                    LaunchingView(status: status)
                case .active(let attached):
                    if let snapshot = session.snapshot {
                        ActiveSessionView(snapshot: snapshot, attached: attached)
                    } else {
                        LaunchingView(status: "connecting to the session…")
                    }
                case .failed(let message):
                    FailedView(message: message)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

// MARK: - engine outdated

struct EngineOutdatedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            LogoMark(size: 60)
            VStack(spacing: 10) {
                Text("Your huske engine needs an update")
                    .font(.brandSans(22, .semibold))
                    .foregroundStyle(Theme.fg)
                Text(
                    "huske \(model.binaryVersion ?? "?") at \(model.binaryURL?.path ?? "?") "
                        + "predates app control. Update it, or point the app at a newer build."
                )
                .font(.brandSans(13))
                .foregroundStyle(Theme.fgMuted)
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            }
            EngineSetupActions(kind: .upgrade)
                .frame(maxWidth: 460)
            Text("Building from source? Point the app at your dev binary in Settings (⌘,) — e.g. <repo>/.venv/bin/huske.")
                .font(.brandSans(11.5))
                .foregroundStyle(Theme.fgFaint)
            Spacer()
            Text("Transcripts and Doctor still work with this engine version.")
                .font(.brandSans(12))
                .foregroundStyle(Theme.fgFaint)
                .padding(.bottom, 24)
        }
        .padding(32)
    }
}

// MARK: - idle

struct IdleView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            LogoMark(size: 64)
                .padding(.bottom, 26)
            Text("Ready to record")
                .font(.brandSans(24, .semibold))
                .kerning(-0.3)
                .foregroundStyle(Theme.fg)
                .padding(.bottom, 8)
            Text("Microphone and system audio, transcribed on this Mac as you go.")
                .font(.brandSans(13))
                .foregroundStyle(Theme.fgMuted)
                .padding(.bottom, 30)

            Button {
                model.startRecording()
            } label: {
                HStack(spacing: 9) {
                    Circle()
                        .fill(Theme.fgOnRed)
                        .frame(width: 9, height: 9)
                    Text("Start Recording")
                }
            }
            .buttonStyle(StopButtonStyle(size: .large))
            .keyboardShortcut("r", modifiers: [.command])
            .padding(.bottom, 26)

            if let version = model.binaryVersion {
                Text("huske \(version) · \(model.binaryURL?.path ?? "")")
                    .font(.brandMono(10.5))
                    .foregroundStyle(Theme.fgFaint)
                    .padding(.bottom, 10)
            }
            Button("Recover orphaned audio from a previous crash…") {
                model.runRecover()
            }
            .buttonStyle(LinkButtonStyle())

            Spacer()
            Text("The first chunk takes ~30 s while the speech model warms up.")
                .font(.brandSans(12))
                .foregroundStyle(Theme.fgFaint)
                .padding(.bottom, 22)
        }
        .padding(32)
    }
}

// MARK: - launching

struct LaunchingView: View {
    @Environment(AppModel.self) private var model
    let status: String

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .padding(.bottom, 6)
            Text("Starting session")
                .font(.brandSans(20, .semibold))
                .foregroundStyle(Theme.fg)
            Text(status)
                .font(.brandMono(12))
                .foregroundStyle(Theme.fgMuted)
                .lineLimit(2)
                .frame(maxWidth: 520)
                .multilineTextAlignment(.center)
            Text("Loading the speech model onto the GPU — usually ~30 seconds.")
                .font(.brandSans(12))
                .foregroundStyle(Theme.fgFaint)
            Button("Cancel") { model.session.cancelLaunch() }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, 10)
            Spacer()
        }
        .padding(32)
    }
}

// MARK: - failed

struct FailedView: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Theme.err)
            Text("The session ended unexpectedly")
                .font(.brandSans(20, .semibold))
                .foregroundStyle(Theme.fg)
            Text(message)
                .font(.brandMono(11.5))
                .foregroundStyle(Theme.fgMuted)
                .frame(maxWidth: 560)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Button("Dismiss") { model.session.dismissFailure() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Run Doctor") {
                    model.session.dismissFailure()
                    model.pane = .doctor
                    model.runDoctor()
                }
                .buttonStyle(SecondaryButtonStyle())
                Button("Try Again") {
                    model.session.dismissFailure()
                    model.startRecording()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
            Spacer()
        }
        .padding(32)
    }
}

// MARK: - active session

struct ActiveSessionView: View {
    @Environment(AppModel.self) private var model
    let snapshot: ControlSnapshot
    let attached: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
                .padding(.top, 30)
            if !snapshot.warnings.isEmpty {
                WarningBanner(warnings: snapshot.warnings)
            }
            MetersCard(snapshot: snapshot)
            HStack(alignment: .top, spacing: 14) {
                ChunkCard(snapshot: snapshot)
                ExtrasCard(snapshot: snapshot)
            }
            EventFeed()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: 780)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if snapshot.stopping {
                StatusPill(text: "finishing", color: Theme.warn, pulsing: true)
            } else if snapshot.paused {
                StatusPill(text: "paused", color: Theme.warn)
            } else if snapshot.recording {
                StatusPill(text: "recording", color: Theme.recordRed, pulsing: true)
            } else {
                StatusPill(text: "idle", color: Theme.fgFaint)
            }

            if attached {
                Text("attached · started outside the app")
                    .font(.brandMono(10.5))
                    .foregroundStyle(Theme.info)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.info.opacity(0.13)))
            }

            Spacer()

            SessionClock(
                startedAt: snapshot.sessionStartedAt,
                endedAt: model.session.stopRequestedAt)

            if snapshot.stopping {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    model.session.pauseResume()
                } label: {
                    Label(
                        snapshot.paused ? "Resume" : "Pause",
                        systemImage: snapshot.paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
                .help(snapshot.paused ? "Resume recording" : "Pause recording")

                Button {
                    model.session.requestStop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(StopButtonStyle())
                .help("Finalize the current chunk, transcribe what's pending, and stop")
            }
        }
    }
}

struct SessionClock: View {
    let startedAt: Date?
    let endedAt: Date?
    /// Overridable so the compact transport in the sidebar can share this.
    var font: Font = .brandMono(13, .medium)
    var tint: Color = Theme.fgMuted

    @ViewBuilder
    var body: some View {
        if let startedAt {
            if let endedAt {
                clockText(at: endedAt, startedAt: startedAt)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    clockText(at: context.date, startedAt: startedAt)
                }
            }
        }
    }

    private func clockText(at date: Date, startedAt: Date) -> some View {
        Text(Self.format(date.timeIntervalSince(startedAt)))
            .font(font)
            .foregroundStyle(tint)
            .help(endedAt == nil ? "Session duration" : "Recorded duration")
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - warnings

struct WarningBanner: View {
    let warnings: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(warnings.sorted(by: { $0.key < $1.key }), id: \.key) { _, message in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warn)
                    Text(message)
                        .font(.brandSans(12.5))
                        .foregroundStyle(Theme.fg)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusMD, style: .continuous)
                .fill(Theme.warn.opacity(0.11))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusMD, style: .continuous)
                .strokeBorder(Theme.warn.opacity(0.38), lineWidth: 1)
        )
    }
}

// MARK: - meters

/// Frame-rate meter smoothing lives outside SwiftUI state: TimelineView
/// drives redraws, this object just advances the physics on demand.
final class MeterEngine {
    private var mic = SmoothedMeter()
    private var system = SmoothedMeter()

    func sample(micDb: Double, systemDb: Double, at date: Date) -> (mic: SmoothedMeter, system: SmoothedMeter) {
        mic.step(targetDb: micDb, now: date)
        system.step(targetDb: systemDb, now: date)
        return (mic, system)
    }
}

struct MetersCard: View {
    @Environment(AppModel.self) private var model
    let snapshot: ControlSnapshot
    @State private var engine = MeterEngine()

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    SectionLabel("Levels")
                    Spacer()
                    MicrophoneMenu(snapshot: snapshot)
                }
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: snapshot.paused)) { context in
                    let levels = engine.sample(
                        micDb: snapshot.paused ? -120 : snapshot.peakMicDb,
                        systemDb: snapshot.paused ? -120 : snapshot.peakSystemDb,
                        at: context.date
                    )
                    VStack(spacing: 13) {
                        MeterRow(
                            label: "Microphone",
                            db: snapshot.paused ? -120 : snapshot.peakMicDb,
                            meter: levels.mic)
                        MeterRow(
                            label: "System audio",
                            db: snapshot.paused ? -120 : snapshot.peakSystemDb,
                            meter: levels.system)
                    }
                }
            }
        }
    }
}

struct MicrophoneMenu: View {
    @Environment(AppModel.self) private var model
    let snapshot: ControlSnapshot

    var body: some View {
        Menu {
            if let devices = model.session.devices {
                ForEach(devices.devices) { device in
                    Button {
                        model.session.selectInputDevice(named: device.name)
                    } label: {
                        if device.index == devices.currentIndex {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Text(device.name)
                        }
                    }
                }
                Divider()
            }
            Button("Refresh Devices") { model.session.refreshDevices() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "mic")
                    .font(.system(size: 10))
                Text(snapshot.inputDeviceName ?? "Microphone")
                    .font(.brandSans(12))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.fgMuted)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .pointingCursor()
        .onAppear { model.session.refreshDevices() }
        .help("Switch the microphone input (takes effect immediately)")
    }
}

struct MeterRow: View {
    let label: String
    let db: Double
    let meter: SmoothedMeter

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.brandSans(12))
                .foregroundStyle(Theme.fgMuted)
                .frame(width: 92, alignment: .leading)
            MeterBar(level: meter.level, peak: meter.peak)
                .frame(height: 9)
            Text(db <= -119 ? "  —  " : String(format: "%5.1f dB", db))
                .font(.brandMono(11))
                .foregroundStyle(Theme.fgMuted)
                .frame(width: 62, alignment: .trailing)
        }
    }
}

struct MeterBar: View {
    let level: Double // 0…1
    let peak: Double // 0…1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.bgSunken)
                Capsule()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Theme.ok, location: 0.0),
                                .init(color: Theme.ok, location: 0.55),
                                .init(color: Theme.amber, location: 0.78),
                                .init(color: Theme.recordRed, location: 0.95),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .mask(
                        HStack {
                            Rectangle()
                                .frame(width: max(0, geo.size.width * level))
                            Spacer(minLength: 0)
                        }
                    )
                if peak > 0.01 {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Theme.fg.opacity(0.8))
                        .frame(width: 2)
                        .offset(x: max(0, geo.size.width * peak - 2))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Level meter")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}

// MARK: - chunk + extras cards

struct ChunkCard: View {
    let snapshot: ControlSnapshot

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Current chunk")
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(String(format: "%03d", snapshot.currentChunkSeq))
                        .font(.brandMono(28, .semibold))
                        .foregroundStyle(Theme.fg)
                    if let started = snapshot.chunkStartedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(SessionClock.format(context.date.timeIntervalSince(started)))
                                .font(.brandMono(14))
                                .foregroundStyle(Theme.fgMuted)
                        }
                    } else {
                        Text("waiting for speech")
                            .font(.brandSans(12))
                            .foregroundStyle(Theme.fgFaint)
                    }
                }
                Rectangle().fill(Theme.divider).frame(height: 1)
                HStack(spacing: 6) {
                    if snapshot.queueDepth > 0 {
                        ProgressView().controlSize(.mini)
                    }
                    Text(
                        snapshot.queueDepth == 0
                            ? "transcriptions up to date"
                            : "\(snapshot.queueDepth) transcription\(snapshot.queueDepth == 1 ? "" : "s") pending"
                    )
                    .font(.brandSans(12))
                    .foregroundStyle(snapshot.queueDepth > 0 ? Theme.fg : Theme.fgMuted)
                }
                if let name = snapshot.lastSavedName {
                    LastSavedLink(name: name, path: snapshot.lastSavedPath)
                }
            }
        }
    }
}

struct LastSavedLink: View {
    let name: String
    let path: String?

    var body: some View {
        Button {
            if let path {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "text.document")
                    .font(.system(size: 10))
                Text(name)
                    .font(.brandMono(11))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(LinkButtonStyle(fontSize: 11, tint: Theme.ok, hoverTint: Theme.ok))
        .disabled(path == nil)
        .help(path.map { "Open \($0)" } ?? "")
    }
}

struct ExtrasCard: View {
    @Environment(AppModel.self) private var model
    let snapshot: ControlSnapshot

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 11) {
                SectionLabel("Extras")
                Toggle(isOn: Binding(
                    get: { snapshot.screenshotsEnabled },
                    set: { _ in model.session.toggleScreenshots() }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Periodic screenshots")
                            .font(.brandSans(12))
                            .foregroundStyle(Theme.fg)
                        if snapshot.screenshotsEnabled {
                            Text("\(snapshot.screenshotsCount) captured")
                                .font(.brandMono(10))
                                .foregroundStyle(Theme.fgMuted)
                        }
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Toggle(isOn: Binding(
                    get: { snapshot.distillEnabled },
                    set: { _ in model.session.toggleDistill() }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("LLM distillation")
                            .font(.brandSans(12))
                            .foregroundStyle(Theme.fg)
                        Text(distillSubtitle)
                            .font(.brandSans(10.5))
                            .foregroundStyle(
                                snapshot.warnings["distill"] != nil ? Theme.warn : Theme.fgMuted)
                            .lineLimit(3)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(
                    "Distill finished transcripts into searchable statements with "
                        + "huske's built-in local model (downloads on first use).")

                Rectangle().fill(Theme.divider).frame(height: 1)

                Button {
                    model.session.send(.openTranscripts)
                } label: {
                    Label("Open transcripts folder", systemImage: "folder")
                }
                .buttonStyle(LinkButtonStyle())
            }
        }
        .frame(width: 252)
    }

    private var distillSubtitle: String {
        if let warning = snapshot.warnings["distill"] {
            return warning
        }
        if snapshot.distillEnabled {
            return "extracting statements for semantic search"
        }
        return "statements for semantic search — built-in model"
    }
}

// MARK: - events

struct EventFeed: View {
    @Environment(AppModel.self) private var model
    @Environment(\.screenRendering) private var rendering

    var body: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Activity")
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
                if rendering {
                    rows
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            rows
                        }
                        .frame(minHeight: 90, maxHeight: 170)
                        .onChange(of: model.session.eventLog.count) {
                            if let last = model.session.eventLog.last {
                                withAnimation(Theme.ease) {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(model.session.eventLog) { event in
                EventRow(event: event)
                    .id(event.id)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EventRow: View {
    let event: SessionEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(timeText)
                .font(.brandMono(10))
                .foregroundStyle(Theme.fgFaint)
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .offset(y: -1)
            Text(event.message)
                .font(.brandSans(12))
                .foregroundStyle(event.severity == .info ? Theme.fgMuted : Theme.fg)
                .textSelection(.enabled)
        }
    }

    private var timeText: String {
        guard let ts = event.ts else { return "--:--:--" }
        return ts.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }

    private var color: Color {
        switch event.severity {
        case .info: return Theme.fgFaint
        case .warn: return Theme.warn
        case .error: return Theme.err
        }
    }
}
