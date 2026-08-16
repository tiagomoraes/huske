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

                appCard

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
                        distillationCard
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
                    .init(
                        "huske \(model.binaryVersion ?? "?") has no `config` command. Upgrade the "
                            + "engine (uv tool upgrade huske / brew upgrade huske), or edit "
                            + "`~/.config/huske/config.toml` directly.")
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

    /// App-level behavior (not engine config): login item + autostart. Also
    /// mirrored in Settings (⌘,); this is where people go looking for it.
    private var appCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 13) {
                SectionLabel("This app")
                Toggle(
                    isOn: Binding(
                        get: { model.openAtLogin },
                        set: { model.setOpenAtLogin($0) }
                    )
                ) {
                    settingLabel(
                        "Open Huske at login",
                        model.canManageLoginItem
                            ? "Launches this app when you log in to your Mac."
                            : "Available when running the packaged Huske.app.")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!model.canManageLoginItem)
                if let error = model.loginItemError {
                    Text(error)
                        .font(.brandSans(11))
                        .foregroundStyle(Theme.err)
                }
                Toggle(
                    isOn: Binding(
                        get: { model.autoStartRecording },
                        set: { model.autoStartRecording = $0 }
                    )
                ) {
                    settingLabel(
                        "Start recording when Huske opens",
                        "Together with login, your Mac records from the moment you sign in.")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                engineRow
            }
        }
    }

    /// Which engine this app drives. Worth stating plainly: the app is a shell
    /// over the CLI, so "which huske" decides what actually records — and a Mac
    /// with a uv tool *and* a Homebrew install has two that drift apart.
    @ViewBuilder
    private var engineRow: some View {
        if let url = model.binaryURL {
            Divider().overlay(Theme.cardBorder)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("Engine")
                        .font(.brandSans(12.5, .semibold))
                        .foregroundStyle(Theme.fg)
                    Text("huske \(model.binaryVersion ?? "…")")
                        .font(.brandMono(11.5))
                        .foregroundStyle(Theme.fgMuted)
                }
                Text(url.path)
                    .font(.brandMono(11))
                    .foregroundStyle(Theme.fgMuted)
                    .textSelection(.enabled)
                if !model.shadowedEngines.isEmpty {
                    Text(
                        "Also installed, not in use: "
                            + model.shadowedEngines
                                .map { "\($0.version.map { "huske \($0)" } ?? "unknown") at \($0.origin)" }
                                .joined(separator: ", ")
                            + ". Huske runs the newest one it finds."
                    )
                    .font(.brandSans(11))
                    .foregroundStyle(Theme.fgMuted)
                    .lineSpacing(2)
                }
            }
        }
    }

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
                            Text("tiny — fastest").tag("tiny")
                            Text("base — default").tag("base")
                            Text("small").tag("small")
                            Text("medium").tag("medium")
                            Text("large-v3-turbo — recommended").tag("large-v3-turbo")
                            Text("large-v3 — heaviest").tag("large-v3")
                        }
                        .labelsHidden()
                        .frame(maxWidth: 240)
                    }
                } else {
                    CuratedPicker(
                        label: "Parakeet model",
                        explicit: config.isExplicit("parakeet_model"),
                        options: [
                            ("mlx-community/parakeet-tdt-0.6b-v3",
                             "Parakeet TDT 0.6B v3 — multilingual (default)"),
                            ("mlx-community/parakeet-tdt-0.6b-v2",
                             "Parakeet TDT 0.6B v2 — English only"),
                        ],
                        value: config.string(
                            "parakeet_model", default: "mlx-community/parakeet-tdt-0.6b-v3"),
                        customPrompt: "Hugging Face repo or local path"
                    ) { config.set("parakeet_model", to: .string($0)) }
                }
                CuratedPicker(
                    label: "Language",
                    explicit: config.isExplicit("language"),
                    options: [
                        ("", "Auto-detect (recommended)"),
                        ("en", "English"),
                        ("pt", "Português"),
                        ("es", "Español"),
                        ("de", "Deutsch"),
                        ("fr", "Français"),
                        ("it", "Italiano"),
                        ("ja", "日本語"),
                        ("zh", "中文"),
                    ],
                    value: config.string("language"),
                    customPrompt: "ISO 639-1 code, e.g. nl"
                ) { newValue in
                    if newValue.isEmpty {
                        config.unset("language")
                    } else {
                        config.set("language", to: .string(newValue))
                    }
                }
                Toggle(isOn: config.boolBinding("whisper_idle_unload", default: true)) {
                    settingLabel(
                        "Unload model when idle",
                        "Recycles the ASR process after 2 min idle so macOS can reclaim Metal RAM.")
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
                    value: config.double("chunk_minutes", default: 15),
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

    private var distillationCard: some View {
        let config = model.config
        let backend = config.string("distill_backend", default: "mlx")
        return Card {
            VStack(alignment: .leading, spacing: 13) {
                SectionLabel("Distillation")
                Toggle(isOn: config.boolBinding("distill_enabled")) {
                    settingLabel(
                        "Correct transcript typos with a tiny local LLM",
                        "Fixes ASR errors in each finished transcript. Raw copy stays in .asr.txt.")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                LabeledRow("Runs on", explicit: config.isExplicit("distill_backend")) {
                    Picker("", selection: config.stringBinding("distill_backend", default: "mlx")) {
                        Text("Built-in — huske runs the model itself (recommended)").tag("mlx")
                        Text("Ollama daemon — bring your own").tag("ollama")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 400)
                }
                if backend == "ollama" {
                    CuratedPicker(
                        label: "Model",
                        explicit: config.isExplicit("distill_model"),
                        options: [
                            ("qwen3.5:0.8b", "Qwen3.5 0.8B — default, lightest"),
                            ("qwen3.5:2b", "Qwen3.5 2B — a bit stronger"),
                            ("qwen3.5:4b", "Qwen3.5 4B — heavier"),
                        ],
                        value: config.string("distill_model"),
                        customPrompt: "any pulled ollama tag"
                    ) { config.set("distill_model", to: .string($0)) }
                    LabeledRow("Endpoint", explicit: config.isExplicit("distill_endpoint")) {
                        CommittingTextField(
                            value: config.string(
                                "distill_endpoint", default: "http://127.0.0.1:11434"),
                            prompt: "http://127.0.0.1:11434"
                        ) { config.set("distill_endpoint", to: .string($0)) }
                        .frame(maxWidth: 260)
                    }
                } else {
                    CuratedPicker(
                        label: "Model",
                        explicit: config.isExplicit("distill_model"),
                        options: [
                            ("mlx-community/Qwen3.5-0.8B-4bit",
                             "Qwen3.5 0.8B — default, lightest"),
                            ("mlx-community/Qwen3.5-2B-4bit",
                             "Qwen3.5 2B — a bit stronger"),
                            ("mlx-community/Qwen3.5-4B-4bit",
                             "Qwen3.5 4B — heavier"),
                        ],
                        value: config.string(
                            "distill_model", default: "mlx-community/Qwen3.5-0.8B-4bit"),
                        customPrompt: "Hugging Face repo"
                    ) { config.set("distill_model", to: .string($0)) }
                    Text("Downloads automatically on first use and runs entirely on this Mac — nothing to install.")
                        .font(.brandSans(11))
                        .foregroundStyle(Theme.fgFaint)
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
            // Subtitles are authored literals and may carry Markdown code spans.
            Text(.init(subtitle))
                .font(.brandSans(11))
                .foregroundStyle(Theme.fgMuted)
        }
    }
}

// MARK: - form building blocks

/// A picker over curated, human-titled values with a "Custom…" escape hatch
/// that reveals a free-text field — no more guessing model ids into a blank
/// string field.
struct CuratedPicker: View {
    let label: String
    let explicit: Bool
    let options: [(String, String)] // (value, title)
    let value: String
    var customPrompt: String = ""
    let onChange: (String) -> Void

    @State private var customMode = false

    private static let customTag = "__custom__"

    private var isKnown: Bool { options.contains { $0.0 == value } }
    private var showCustomField: Bool { customMode || !isKnown }

    var body: some View {
        LabeledRow(label, explicit: explicit) {
            VStack(alignment: .leading, spacing: 6) {
                Picker(
                    "",
                    selection: Binding(
                        get: { showCustomField ? Self.customTag : value },
                        set: { selected in
                            if selected == Self.customTag {
                                customMode = true
                            } else {
                                customMode = false
                                onChange(selected)
                            }
                        }
                    )
                ) {
                    ForEach(options, id: \.0) { option in
                        Text(option.1).tag(option.0)
                    }
                    Divider()
                    Text("Custom…").tag(Self.customTag)
                }
                .labelsHidden()
                .frame(maxWidth: 400)
                if showCustomField {
                    CommittingTextField(value: isKnown ? "" : value, prompt: customPrompt) {
                        customMode = false
                        onChange($0)
                    }
                    .frame(maxWidth: 400)
                }
            }
        }
    }
}

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
        TextField(
            "", text: $draft,
            prompt: Text(prompt).font(.brandMono(11.5)).foregroundStyle(Theme.fgFaint)
        )
            .textFieldStyle(.plain)
            .font(.brandMono(11.5))
            .foregroundStyle(Theme.fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous)
                    .fill(Theme.bgSunken.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous)
                    .strokeBorder(
                        focused ? Theme.amber.opacity(0.55) : Theme.divider, lineWidth: 1)
            )
            .animation(Theme.easeFast, value: focused)
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
