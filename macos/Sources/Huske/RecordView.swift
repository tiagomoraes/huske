import HuskeKit
import SwiftUI

struct RecordView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let session = model.session
        Group {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .navigationTitle("Record")
    }
}

// MARK: - idle

struct IdleView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            LogoMark(size: 64)
            VStack(spacing: 8) {
                Text("Ready to record")
                    .font(.system(size: 24, weight: .bold))
                Text("Microphone and system audio, transcribed on this Mac as you go.")
                    .foregroundStyle(Theme.fgMuted)
            }

            Button {
                model.startRecording()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Start Recording")
                        .font(.system(size: 15, weight: .semibold))
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 12)
            }
            .buttonStyle(RecordButtonStyle())
            .keyboardShortcut("r", modifiers: [.command])

            VStack(spacing: 6) {
                if let version = model.binaryVersion {
                    Text("huske \(version) · \(model.binaryURL?.path ?? "")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.fgFaint)
                }
                Button("Recover orphaned audio from a previous crash…") {
                    model.runRecover()
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
            Spacer()
            Text("The first chunk takes ~30 s while the speech model warms up.")
                .font(.footnote)
                .foregroundStyle(Theme.fgFaint)
                .padding(.bottom, 18)
        }
        .padding(32)
    }
}

struct RecordButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                Capsule().fill(
                    configuration.isPressed ? Theme.amberPressed : Theme.recordRed)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - launching

struct LaunchingView: View {
    @Environment(AppModel.self) private var model
    let status: String

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Starting session")
                .font(.system(size: 20, weight: .semibold))
            Text(status)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.fgMuted)
                .lineLimit(2)
                .frame(maxWidth: 520)
                .multilineTextAlignment(.center)
            Text("Loading the speech model onto the GPU — usually ~30 seconds.")
                .font(.footnote)
                .foregroundStyle(Theme.fgFaint)
            Button("Cancel") { model.session.cancelLaunch() }
                .padding(.top, 8)
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
                .font(.system(size: 34))
                .foregroundStyle(Theme.err)
            Text("The session ended unexpectedly")
                .font(.system(size: 20, weight: .semibold))
            Text(message)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.fgMuted)
                .frame(maxWidth: 560)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Button("Dismiss") { model.session.dismissFailure() }
                Button("Run Doctor") {
                    model.session.dismissFailure()
                    model.runDoctor()
                }
                Button("Try Again") {
                    model.session.dismissFailure()
                    model.startRecording()
                }
                .keyboardShortcut(.defaultAction)
            }
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
            if !snapshot.warnings.isEmpty {
                WarningBanner(warnings: snapshot.warnings)
            }
            MetersCard(snapshot: snapshot)
            HStack(alignment: .top, spacing: 14) {
                ChunkCard(snapshot: snapshot)
                ExtrasCard(snapshot: snapshot)
            }
            EventFeed()
        }
        .padding(20)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if snapshot.stopping {
                StatusPill(text: "FINISHING", color: Theme.warn, pulsing: true)
            } else if snapshot.paused {
                StatusPill(text: "PAUSED", color: Theme.warn)
            } else if snapshot.recording {
                StatusPill(text: "RECORDING", color: Theme.recordRed, pulsing: true)
            } else {
                StatusPill(text: "IDLE", color: Theme.fgFaint)
            }

            if attached {
                Text("attached to a session started outside the app")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.fgMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.info.opacity(0.15)))
            }

            Spacer()

            SessionClock(startedAt: snapshot.sessionStartedAt)

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
                .help(snapshot.paused ? "Resume recording" : "Pause recording")

                Button(role: .destructive) {
                    model.session.requestStop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Finalize the current chunk, transcribe what's pending, and stop")
            }
        }
    }
}

struct SessionClock: View {
    let startedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let startedAt {
                Text(Self.format(context.date.timeIntervalSince(startedAt)))
                    .meterFigure(size: 13)
                    .foregroundStyle(Theme.fgMuted)
                    .help("Session duration")
            }
        }
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
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warn)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.fg)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.warn.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.warn.opacity(0.4), lineWidth: 1)
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
            VStack(alignment: .leading, spacing: 14) {
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
                    VStack(spacing: 12) {
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
                    .font(.system(size: 11))
                Text(snapshot.inputDeviceName ?? "Microphone")
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
                .font(.system(size: 12))
                .foregroundStyle(Theme.fgMuted)
                .frame(width: 92, alignment: .leading)
            MeterBar(level: meter.level, peak: meter.peak)
                .frame(height: 10)
            Text(db <= -119 ? "—" : String(format: "%5.1f dB", db))
                .meterFigure(size: 11)
                .foregroundStyle(Theme.fgMuted)
                .frame(width: 64, alignment: .trailing)
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
                        .fill(Theme.fg.opacity(0.85))
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
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(format: "%03d", snapshot.currentChunkSeq))
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                    if let started = snapshot.chunkStartedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(SessionClock.format(context.date.timeIntervalSince(started)))
                                .meterFigure(size: 14)
                                .foregroundStyle(Theme.fgMuted)
                        }
                    } else {
                        Text("waiting for speech")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.fgFaint)
                    }
                }
                Divider().overlay(Theme.divider)
                HStack(spacing: 6) {
                    if snapshot.queueDepth > 0 {
                        ProgressView().controlSize(.mini)
                    }
                    Text(
                        snapshot.queueDepth == 0
                            ? "transcriptions up to date"
                            : "\(snapshot.queueDepth) transcription\(snapshot.queueDepth == 1 ? "" : "s") pending"
                    )
                    .font(.system(size: 12))
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
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                Text(name)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Theme.ok)
        }
        .buttonStyle(.plain)
        .disabled(path == nil)
        .help(path.map { "Open \($0)" } ?? "")
    }
}

struct ExtrasCard: View {
    @Environment(AppModel.self) private var model
    let snapshot: ControlSnapshot

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Extras")
                Toggle(isOn: Binding(
                    get: { snapshot.screenshotsEnabled },
                    set: { _ in model.session.toggleScreenshots() }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Periodic screenshots")
                            .font(.system(size: 12))
                        if snapshot.screenshotsEnabled {
                            Text("\(snapshot.screenshotsCount) captured")
                                .font(.system(size: 10, design: .monospaced))
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
                            .font(.system(size: 12))
                        Text("statements for semantic search")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.fgMuted)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Divider().overlay(Theme.divider)

                Button {
                    model.session.send(.openTranscripts)
                } label: {
                    Label("Open transcripts folder", systemImage: "folder")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.amber)
            }
        }
        .frame(width: 250)
    }
}

// MARK: - events

struct EventFeed: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Activity")
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(model.session.eventLog) { event in
                                EventRow(event: event)
                                    .id(event.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }
                    .frame(minHeight: 90, maxHeight: 170)
                    .onChange(of: model.session.eventLog.count) {
                        if let last = model.session.eventLog.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct EventRow: View {
    let event: SessionEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(timeText)
                .meterFigure(size: 10)
                .foregroundStyle(Theme.fgFaint)
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .offset(y: -1)
            Text(event.message)
                .font(.system(size: 11.5))
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
