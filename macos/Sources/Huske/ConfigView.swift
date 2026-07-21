import HuskeKit
import SwiftUI

/// Engine configuration. Every write goes through `huske config set`, so
/// values are validated by the engine itself; changes apply to the *next*
/// session (the running one keeps its frozen config).
struct ConfigView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let config = model.config
        PaneScroll {
            VStack(alignment: .leading, spacing: 14) {
                PaneHeader("Configuration", subtitle: config.snapshot?.path) {
                    if model.capabilities?.configCLI == true {
                        Button {
                            Task { await model.config.reload(binary: model.binaryURL) }
                        } label: {
                            Label("Reload", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(.top, 30)

                if model.capabilities != nil, model.capabilities?.configCLI != true, !model.isDemo {
                    outdatedNotice
                } else {
                    if model.session.isBusy {
                        noteBanner(
                            "A session is running — changes here apply when the next session starts.")
                    }
                    if let error = config.writeError {
                        errorBanner(error)
                    }
                    if let error = config.loadError {
                        errorBanner(error)
                    } else if config.snapshot != nil {
                        transcriptionCard
                        chunkingCard
                        audioCard
                        storageCard
                        extrasCard
                    } else if config.loading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .task {
            if model.config.snapshot == nil, model.capabilities?.configCLI == true {
                await model.config.reload(binary: model.binaryURL)
            }
            model.refreshDevices()
        }
        .onChange(of: config.snapshot?.string("output_root")) {
            model.syncTranscriptRoot()
        }
    }

    private var outdatedNotice: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("In-app configuration needs a newer engine")
                        .font(.brandSans(13, .semibold))
                        .foregroundStyle(Theme.fg)
                } icon: {
                    Image(systemName: "arrow.up.circle")
                        .foregroundStyle(Theme.warn)
                }
                Text(
                    "huske \(model.binaryVersion ?? "?") has no `config` command. Upgrade the engine "
                        + "(uv tool upgrade huske / brew upgrade huske), or edit "
                        + "~/.config/huske/config.toml directly."
                )
                .font(.brandSans(12.5))
                .foregroundStyle(Theme.fgMuted)
                .lineSpacing(3)
                Button("Open config.toml") {
                    let path = NSString(string: "~/.config/huske/config.toml").expandingTildeInPath
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
                .buttonStyle(SecondaryButtonStyle(size: .small))
            }
        }
    }

    private func noteBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.info)
            Text(text)
                .font(.brandSans(12))
                .foregroundStyle(Theme.fg)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusMD, style: .continuous)
                .fill(Theme.info.opacity(0.1))
        )
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.err)
            Text(text)
                .font(.brandSans(12))
                .foregroundStyle(Theme.fg)
                .textSelection(.enabled)
            Spacer()
            Button("Dismiss") { model.config.clearWriteError() }
                .buttonStyle(SecondaryButtonStyle(size: .small))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusMD, style: .continuous)
                .fill(Theme.err.opacity(0.1))
        )
    }

    // MARK: cards

    private var transcriptionCard: some View {
        let config = model.config
        return Card {
            VStack(alignment: .leading, spacing: 13) {
                SectionLabel("Transcription")
                LabeledRow("Engine", explicit: config.isExplicit("asr_engine")) {
                    Picker("", selection: config.stringBinding("asr_engine", default: "parakeet")) {
                        Text("Parakeet — silence-robust, multilingual").tag("parakeet")
                        Text("Whisper (legacy)").tag("whisper")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 340)
                }
                if config.string("asr_engine", default: "parakeet") == "whisper" {
                    LabeledRow("Whisper model", explicit: config.isExplicit("model")) {
                        Picker("", selection: config.stringBinding("model", default: "base")) {
                            ForEach(["tiny", "base", "small", "medium", "large-v3"], id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 200)
                    }
                } else {
                    LabeledRow("Parakeet model", explicit: config.isExplicit("parakeet_model")) {
                        CommittingTextField(
                            value: config.string(
                                "parakeet_model", default: "mlx-community/parakeet-tdt-0.6b-v3"),
                            prompt: "HF repo or local dir"
                        ) { config.set("parakeet_model", to: .string($0)) }
                    }
                }
                LabeledRow("Language", explicit: config.isExplicit("language")) {
                    CommittingTextField(
                        value: config.string("language"),
                        prompt: "auto-detect"
                    ) { newValue in
                        if newValue.isEmpty {
                            config.unset("language")
                        } else {
                            config.set("language", to: .string(newValue))
                        }
                    }
                    .frame(maxWidth: 140)
                }
                Toggle(isOn: config.boolBinding("whisper_idle_unload", default: true)) {
                    settingLabel(
                        "Unload model when idle",
                        "Frees RAM between chunks; the next chunk pays a few-second reload.")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
    }

    private var chunkingCard: some View {
        let config = model.config
        return Card {
            VStack(alignment: .leading, spacing: 13) {
                SectionLabel("Chunking")
                Toggle(isOn: config.boolBinding("speech_gated", default: true)) {
                    settingLabel(
                        "Split on pauses in speech",
                        "Chunks close on real silence instead of a fixed clock; quiet gaps aren't recorded.")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                if config.bool("speech_gated", default: true) {
                    CommittingSlider(
                        label: "Split after silence",
                        value: config.double("silence_split_seconds", default: 60),
                        range: 2...600,
                        format: { "\(Int($0))s" }
                    ) { config.set("silence_split_seconds", to: .number($0)) }
                }
                CommittingSlider(
                    label: "Max chunk length",
                    value: config.double("chunk_minutes", default: 30),
                    range: 1...60,
                    format: { "\(Int($0)) min" }
                ) { config.set("chunk_minutes", to: .number($0)) }
            }
        }
    }

    private var audioCard: some View {
        let config = model.config
        return Card {
            VStack(alignment: .leading, spacing: 13) {
                SectionLabel("Audio")
                LabeledRow("Microphone", explicit: config.isExplicit("input_device")) {
                    Picker(
                        "",
                        selection: Binding(
                            get: { config.string("input_device") },
                            set: { newValue in
                                if newValue.isEmpty {
                                    config.unset("input_device")
                                } else {
                                    config.set("input_device", to: .string(newValue))
                                }
                            }
                        )
                    ) {
                        Text("System default").tag("")
                        if let report = model.devicesReport {
                            Divider()
                            ForEach(report.devices) { device in
                                Text(device.name).tag(device.name)
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)
                }
                LabeledRow("System audio", explicit: config.isExplicit("system_audio_backend")) {
                    Picker("", selection: config.stringBinding("system_audio_backend", default: "auto")) {
                        Text("Auto (Core Audio tap when available)").tag("auto")
                        Text("Core Audio tap").tag("tap")
                        Text("ScreenCaptureKit").tag("sck")
                        Text("Off — microphone only").tag("off")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 340)
                }
                Toggle(isOn: config.boolBinding("echo_cancel", default: true)) {
                    settingLabel(
                        "Echo suppression",
                        "Reduces speaker bleed into the mic when not wearing headphones.")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                LabeledRow("Echo de-duplication", explicit: config.isExplicit("echo_dedup")) {
                    Picker("", selection: config.stringBinding("echo_dedup", default: "drop")) {
                        Text("Drop duplicated lines").tag("drop")
                        Text("Keep, tagged as echo").tag("annotate")
                        Text("Off").tag("off")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }
            }
        }
    }

    private var storageCard: some View {
        let config = model.config
        return Card {
            VStack(alignment: .leading, spacing: 13) {
                SectionLabel("Storage")
                PathRow(
                    label: "Transcripts",
                    path: config.string("output_root")
                ) { config.set("output_root", to: .string($0)) }
                PathRow(
                    label: "Working audio",
                    path: config.string("audio_root")
                ) { config.set("audio_root", to: .string($0)) }
                Toggle(isOn: config.boolBinding("keep_audio")) {
                    settingLabel(
                        "Keep audio after transcription",
                        "Retains a compressed copy of each chunk next to the transcript.")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                if config.bool("keep_audio") {
                    LabeledRow("Kept audio format", explicit: config.isExplicit("keep_audio_format")) {
                        Picker("", selection: config.stringBinding("keep_audio_format", default: "opus")) {
                            Text("Opus — smallest").tag("opus")
                            Text("FLAC — lossless").tag("flac")
                            Text("WAV — uncompressed").tag("wav")
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                    }
                }
            }
        }
    }

    private var extrasCard: some View {
        let config = model.config
        return Card {
            VStack(alignment: .leading, spacing: 13) {
                SectionLabel("Extras")
                Toggle(isOn: config.boolBinding("screenshots_enabled")) {
                    settingLabel(
                        "Periodic screenshots",
                        "Capture every display on an interval alongside the transcript.")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                if config.bool("screenshots_enabled") {
                    CommittingSlider(
                        label: "Screenshot interval",
                        value: config.double("screenshots_interval_seconds", default: 60),
                        range: 5...600,
                        format: { "\(Int($0))s" }
                    ) { config.set("screenshots_interval_seconds", to: .number($0)) }
                }
                Toggle(isOn: config.boolBinding("indexing_enabled")) {
                    settingLabel(
                        "Semantic search index",
                        "Embed finished transcripts for `huske mcp` search (needs the mcp extra).")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Toggle(isOn: config.boolBinding("distill_enabled")) {
                    settingLabel(
                        "LLM distillation",
                        "Distill transcripts into searchable statements with a local LLM (Ollama).")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                if config.bool("distill_enabled") {
                    LabeledRow("Distill model", explicit: config.isExplicit("distill_model")) {
                        CommittingTextField(
                            value: config.string("distill_model", default: "qwen3.5:0.8b"),
                            prompt: "ollama tag"
                        ) { config.set("distill_model", to: .string($0)) }
                        .frame(maxWidth: 220)
                    }
                }
                Toggle(isOn: config.boolBinding("menu_bar_enabled", default: true)) {
                    settingLabel(
                        "Menu bar icon for terminal sessions",
                        "Shown when recording with `huske run` in a terminal — this app has its own.")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
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

// MARK: - form building blocks

struct LabeledRow<Content: View>: View {
    let label: String
    let explicit: Bool
    @ViewBuilder var content: Content

    init(_ label: String, explicit: Bool, @ViewBuilder content: () -> Content) {
        self.label = label
        self.explicit = explicit
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.brandSans(12.5))
                    .foregroundStyle(Theme.fg)
                if explicit {
                    Circle()
                        .fill(Theme.amber)
                        .frame(width: 4, height: 4)
                        .help("Set explicitly in the config file")
                }
            }
            .frame(width: 160, alignment: .leading)
            content
            Spacer()
        }
    }
}

/// Text field that writes only on commit (Return or focus loss) — never per
/// keystroke, since each write shells out to the engine.
struct CommittingTextField: View {
    let value: String
    var prompt: String = ""
    let onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft, prompt: Text(prompt).font(.brandMono(11.5)))
            .textFieldStyle(.roundedBorder)
            .font(.brandMono(11.5))
            .focused($focused)
            .onAppear { draft = value }
            .onChange(of: value) { _, newValue in
                if !focused { draft = newValue }
            }
            .onSubmit { commit() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard trimmed != value else { return }
        onCommit(trimmed)
    }
}

/// Slider that writes only when the drag ends.
struct CommittingSlider: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    let onCommit: (Double) -> Void

    @State private var draft: Double = 0
    @State private var editing = false

    var body: some View {
        HStack {
            Text(label)
                .font(.brandSans(12.5))
                .foregroundStyle(Theme.fg)
                .frame(width: 160, alignment: .leading)
            Slider(
                value: $draft,
                in: range,
                onEditingChanged: { isEditing in
                    editing = isEditing
                    if !isEditing, draft != value {
                        onCommit(draft)
                    }
                }
            )
            .frame(maxWidth: 260)
            Text(format(draft))
                .font(.brandMono(11))
                .foregroundStyle(Theme.fgMuted)
                .frame(width: 56, alignment: .trailing)
        }
        .onAppear { draft = value }
        .onChange(of: value) { _, newValue in
            if !editing { draft = newValue }
        }
    }
}

struct PathRow: View {
    let label: String
    let path: String
    let onPick: (String) -> Void

    var body: some View {
        HStack {
            Text(label)
                .font(.brandSans(12.5))
                .foregroundStyle(Theme.fg)
                .frame(width: 160, alignment: .leading)
            Text(path.isEmpty ? "—" : path)
                .font(.brandMono(11))
                .foregroundStyle(Theme.fgMuted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                if !path.isEmpty {
                    panel.directoryURL = URL(fileURLWithPath: path)
                }
                if panel.runModal() == .OK, let url = panel.url {
                    onPick(url.path)
                }
            }
            .buttonStyle(SecondaryButtonStyle(size: .small))
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11))
            }
            .buttonStyle(SecondaryButtonStyle(size: .small))
            .disabled(path.isEmpty)
            .help("Open in Finder")
        }
    }
}
