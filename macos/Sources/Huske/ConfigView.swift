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
                        if hasCleanupCLI {
                            DictionaryCard()
                        }
                        chunkingCard
                        audioCard
                        storageCard
                        if hasCleanupCLI {
                            TranscriptCleanupCard()
                        } else {
                            legacyCleanupCard
                        }
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
            await model.cleanup.loadLanguagesIfNeeded(
                binary: model.binaryURL, supported: model.capabilities?.languagesCLI == true)
        }
        .onChange(of: config.snapshot?.string("output_root")) {
            model.syncTranscriptRoot()
        }
    }

    /// The engine speaks `huske llm` (provider choice, keys, consent) and
    /// knows the dictionary keys that came with it.
    private var hasCleanupCLI: Bool { model.capabilities?.llmCLI == true }

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
                SettingToggle(
                    isOn: Binding(
                        get: { model.openAtLogin },
                        set: { model.setOpenAtLogin($0) }
                    ),
                    title: "Open Huske at login",
                    subtitle: model.canManageLoginItem
                        ? "Launches this app when you log in to your Mac."
                        : "Available when running the packaged Huske.app.")
                .disabled(!model.canManageLoginItem)
                if let error = model.loginItemError {
                    Text(error)
                        .font(.brandSans(11))
                        .foregroundStyle(Theme.err)
                }
                SettingToggle(
                    isOn: Binding(
                        get: { model.autoStartRecording },
                        set: { model.autoStartRecording = $0 }
                    ),
                    title: "Start recording when Huske opens",
                    subtitle: "Together with login, your Mac records from the moment you sign in.")
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

    /// The engine has a model catalog (`huske models`): one Model row and a
    /// picker sheet replace the engine / per-engine model pickers.
    private var hasModelsCLI: Bool { model.capabilities?.modelsCLI == true }

    private var transcriptionCard: some View {
        let config = model.config
        return Card {
            VStack(alignment: .leading, spacing: 13) {
                SectionLabel("Transcription")
                if hasModelsCLI {
                    modelRow
                } else {
                    legacyModelPickers
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
                    customPrompt: "ISO 639-1 code, e.g. nl",
                    note: languageNote
                ) { newValue in
                    if newValue.isEmpty {
                        config.unset("language")
                    } else {
                        config.set("language", to: .string(newValue))
                    }
                }
                SettingToggle(
                    isOn: config.boolBinding("whisper_idle_unload", default: true),
                    title: "Unload model when idle",
                    subtitle: "Recycles the ASR process after 2 min idle so macOS can reclaim Metal RAM.")
            }
        }
        // Ask again whenever the saved choice (or the language it is judged
        // against) changes — after a write, a Reload, or a choice in the sheet.
        .task(id: modelsTrigger) {
            guard hasModelsCLI else { return }
            await model.models.refresh(binary: model.binaryURL)
        }
        .sheet(
            isPresented: Binding(
                get: { model.models.pickerVisible },
                set: { model.models.pickerVisible = $0 })
        ) {
            ModelPickerSheet()
                .environment(model)
                .frame(height: 720)
        }
    }

    private var modelsTrigger: String {
        let saved = model.config.snapshot
        return [hasModelsCLI ? "1" : "0"]
            + ["asr_model", "asr_engine", "parakeet_model", "model", "language"]
            .map { saved?.string($0) ?? "" }
            .joined(separator: "|")
    }

    /// What the Language picker's setting does, from the model in use; the
    /// engine-name wording when the catalog isn't known.
    private var languageNote: String? {
        let config = model.config
        if hasModelsCLI, let current = model.models.current {
            return ModelWords.languageNote(
                model: current,
                code: config.string("language"),
                names: model.cleanup.languages,
                lockingChoice: model.models.catalog?.languageLockingChoice)
        }
        guard hasCleanupCLI else { return nil }
        return CleanupWords.languageNote(
            engine: config.string("asr_engine", default: "parakeet"),
            code: config.string("language"),
            languages: model.cleanup.languages)
    }

    /// The model in use, in words, and the way to change it.
    private var modelRow: some View {
        let config = model.config
        let store = model.models
        let explicit = ["asr_model", "asr_engine", "parakeet_model", "model"]
            .contains { config.isExplicit($0) }
        return LabeledRow("Model", explicit: explicit) {
            VStack(alignment: .leading, spacing: 4) {
                if let current = store.current {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(current.name)
                            .font(.brandSans(13, .medium))
                            .foregroundStyle(Theme.fg)
                        Spacer(minLength: 8)
                        Button("Change…") { store.pickerVisible = true }
                            .buttonStyle(SecondaryButtonStyle(size: .small))
                    }
                    if !current.summary.isEmpty {
                        Text(current.summary)
                            .font(.brandSans(12))
                            .foregroundStyle(Theme.fgMuted)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !current.inCatalog {
                        Text(current.repo)
                            .font(.brandMono(11))
                            .foregroundStyle(Theme.fgMuted)
                            .textSelection(.enabled)
                    }
                    if let download = store.downloads[current.id] {
                        HStack(spacing: 6) {
                            StateRing(kind: .progress(download.fraction), size: 10)
                            Text(
                                download.fraction.map { "Downloading · \(Int(($0 * 100).rounded(.down))) %" }
                                    ?? "Downloading")
                                .font(.brandSans(11.5))
                                .foregroundStyle(Theme.fg)
                                .monospacedDigit()
                        }
                    } else {
                        Text(ModelWords.cardFacts(current, names: model.cleanup.languages))
                            .font(.brandSans(11.5))
                            .foregroundStyle(Theme.fgMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                } else if let error = store.loadError {
                    FieldNote("Couldn't list the models: \(CleanupWords.sentence(error))", color: Theme.err)
                    Button("Try again") {
                        Task { await store.refresh(binary: model.binaryURL) }
                    }
                    .buttonStyle(LinkButtonStyle(fontSize: 12, tint: Theme.fgMuted, hoverTint: Theme.fg))
                } else {
                    HStack(spacing: 8) {
                        StateRing(kind: .progress(nil), size: 10)
                        Text("Looking up the model…")
                            .font(.brandSans(12))
                            .foregroundStyle(Theme.fgMuted)
                    }
                }
            }
            .frame(maxWidth: 400, alignment: .leading)
        }
    }

    /// Engines before `huske models`: pick the runtime, then its model.
    @ViewBuilder
    private var legacyModelPickers: some View {
        let config = model.config
        LabeledRow("Engine", explicit: config.isExplicit("asr_engine")) {
            OptionPicker(
                selection: config.stringBinding("asr_engine", default: "parakeet"),
                options: [
                    ("parakeet", "Parakeet — silence-robust, multilingual"),
                    ("whisper", "Whisper (legacy)"),
                ])
        }
        if config.string("asr_engine", default: "parakeet") == "whisper" {
            LabeledRow("Whisper model", explicit: config.isExplicit("model")) {
                OptionPicker(
                    selection: config.stringBinding("model", default: "base"),
                    options: [
                        ("tiny", "tiny — fastest"),
                        ("base", "base — default"),
                        ("small", "small"),
                        ("medium", "medium"),
                        ("large-v3-turbo", "large-v3-turbo — recommended"),
                        ("large-v3", "large-v3 — heaviest"),
                    ],
                    width: 240)
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
    }

    private var chunkingCard: some View {
        let config = model.config
        return Card {
            VStack(alignment: .leading, spacing: 13) {
                SectionLabel("Chunking")
                SettingToggle(
                    isOn: config.boolBinding("speech_gated", default: true),
                    title: "Split on pauses in speech",
                    subtitle: "Chunks close on real silence instead of a fixed clock; quiet gaps aren't recorded.")
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
                SettingToggle(
                    isOn: config.boolBinding("echo_cancel", default: true),
                    title: "Echo cancellation",
                    subtitle: "Removes what your speakers play from the mic (WebRTC AEC3), so remote voices aren't transcribed twice. No effect with headphones.")
                SettingToggle(
                    isOn: config.boolBinding("capture_sync", default: true),
                    title: "Record mic and system on one clock",
                    subtitle: "Keeps the two channels sample-aligned for echo cancellation. Falls back to separate streams if your mic can't join.")
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
                SettingToggle(
                    isOn: config.boolBinding("keep_audio"),
                    title: "Keep audio after transcription",
                    subtitle: "Retains a compressed copy of each chunk next to the transcript.")
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

    /// Engines before `huske llm` only know the built-in model and Ollama;
    /// keep their controls, and say what an update brings.
    private var legacyCleanupCard: some View {
        let config = model.config
        let backend = config.string("distill_backend", default: "mlx")
        return Card {
            VStack(alignment: .leading, spacing: 13) {
                SectionLabel("Transcript cleanup")
                SettingToggle(
                    isOn: config.boolBinding("distill_enabled"),
                    title: "Clean up transcripts with a language model",
                    subtitle: "Fixes misheard words in each finished transcript. The original stays next to it.")
                LabeledRow("Runs on", explicit: config.isExplicit("distill_backend")) {
                    OptionPicker(
                        selection: config.stringBinding("distill_backend", default: "mlx"),
                        options: [
                            ("mlx", "Built-in model (Qwen, downloads once)"),
                            ("ollama", "Ollama"),
                        ],
                        width: 400)
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
                FieldNote(
                    "Update the engine to clean up with Apple Intelligence, a local server, "
                        + "or a cloud provider with your own key.")
            }
        }
    }

    private var extrasCard: some View {
        let config = model.config
        return Card {
            VStack(alignment: .leading, spacing: 13) {
                SectionLabel("Extras")
                SettingToggle(
                    isOn: config.boolBinding("screenshots_enabled"),
                    title: "Periodic screenshots",
                    subtitle: "Capture every display on an interval alongside the transcript.")
                if config.bool("screenshots_enabled") {
                    CommittingSlider(
                        label: "Screenshot interval",
                        value: config.double("screenshots_interval_seconds", default: 60),
                        range: 5...600,
                        format: { "\(Int($0))s" }
                    ) { config.set("screenshots_interval_seconds", to: .number($0)) }
                }
                SettingToggle(
                    isOn: config.boolBinding("menu_bar_enabled", default: true),
                    title: "Menu bar icon for terminal sessions",
                    subtitle: "Shown when recording with `huske run` in a terminal — this app has its own.")
            }
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
    /// One plain line under the picker (what the setting does, or why a list
    /// is empty).
    var note: String?
    /// A small control beside the picker (e.g. Refresh).
    var accessory: AnyView?
    let onChange: (String) -> Void

    @State private var customMode = false
    @Environment(\.screenRendering) private var rendering

    private static let customTag = "__custom__"

    private var isKnown: Bool { options.contains { $0.0 == value } }
    private var showCustomField: Bool { customMode || !isKnown }

    var body: some View {
        LabeledRow(label, explicit: explicit) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    picker
                        .frame(maxWidth: 400)
                    if let accessory { accessory }
                }
                if showCustomField {
                    CommittingTextField(value: isKnown ? "" : value, prompt: customPrompt) {
                        customMode = false
                        onChange($0)
                    }
                    .frame(maxWidth: 400)
                }
                if let note {
                    FieldNote(note)
                        .frame(maxWidth: 400, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var picker: some View {
        if rendering {
            MenuStandIn(
                title: showCustomField ? "Custom…" : (options.first { $0.0 == value }?.1 ?? value))
        } else {
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
        }
    }
}

/// A plain menu of (value, title) options; draws a static stand-in under the
/// offscreen renderer, which cannot draw AppKit pop-up buttons.
struct OptionPicker: View {
    let selection: Binding<String>
    let options: [(String, String)]
    var width: CGFloat = 340

    @Environment(\.screenRendering) private var rendering

    var body: some View {
        if rendering {
            MenuStandIn(
                title: options.first { $0.0 == selection.wrappedValue }?.1 ?? selection.wrappedValue
            )
            .frame(maxWidth: width)
        } else {
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
            .labelsHidden()
            .frame(maxWidth: width)
        }
    }
}

/// A switch with a title and one line of explanation — every on/off setting
/// in the pane.
struct SettingToggle: View {
    let isOn: Binding<Bool>
    let title: String
    let subtitle: String

    @Environment(\.screenRendering) private var rendering

    var body: some View {
        if rendering {
            HStack(alignment: .center, spacing: 10) {
                label
                SwitchStandIn(isOn: isOn.wrappedValue)
            }
        } else {
            Toggle(isOn: isOn) { label }
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.brandSans(12.5))
                .foregroundStyle(Theme.fg)
            // Subtitles are authored literals and may carry Markdown code spans.
            Text(.init(subtitle))
                .font(.brandSans(11))
                .foregroundStyle(Theme.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One plain explanatory line under a control.
struct FieldNote: View {
    let text: String
    var color: Color = Theme.fgMuted

    init(_ text: String, color: Color = Theme.fgMuted) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(.init(text))
            .font(.brandSans(11.5))
            .foregroundStyle(color)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: offscreen stand-ins
// ImageRenderer draws AppKit-backed controls (pop-up buttons, switches, text
// fields) as placeholders. Under `screenRendering` these draw the same shape
// statically, so a rendered pane can be reviewed as a whole.

struct MenuStandIn: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.brandSans(12.5))
                .foregroundStyle(Theme.fg)
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(Theme.fgMuted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.bgElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Theme.cardBorder, lineWidth: 1)
        )
    }
}

struct SwitchStandIn: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? Theme.amber : Theme.bgSunken)
            .overlay(Capsule().strokeBorder(Theme.cardBorder.opacity(isOn ? 0 : 0.8), lineWidth: 1))
            .frame(width: 28, height: 16)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.18), radius: 0.8, y: 0.5)
                    .frame(width: 13, height: 13)
                    .padding(1.5)
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
    /// Mono for ids, paths and URLs; sans for words people read.
    var font: Font = .brandMono(11.5)
    let onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool
    @Environment(\.screenRendering) private var rendering

    var body: some View {
        field
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

    @ViewBuilder
    private var field: some View {
        if rendering {
            Text(value.isEmpty ? prompt : value)
                .font(font)
                .foregroundStyle(value.isEmpty ? Theme.fgFaint : Theme.fg)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(
                "", text: $draft,
                prompt: Text(prompt).font(font).foregroundStyle(Theme.fgFaint)
            )
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(Theme.fg)
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard trimmed != value else { return }
        onCommit(trimmed)
    }
}

/// Multi-line text that writes only on focus loss or ⌘↩ — the Dictionary's
/// word list and the cleanup instructions.
struct CommittingTextEditor: View {
    let value: String
    var placeholder: String = ""
    var font: Font = .brandSans(12.5)
    var minHeight: CGFloat = 60
    let onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool
    @Environment(\.screenRendering) private var rendering

    var body: some View {
        ZStack(alignment: .topLeading) {
            if rendering {
                Text(value.isEmpty ? placeholder : value)
                    .font(font)
                    .foregroundStyle(value.isEmpty ? Theme.fgFaint : Theme.fg)
                    .lineSpacing(3)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else {
                TextEditor(text: $draft)
                    .font(font)
                    .foregroundStyle(Theme.fg)
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 6)
                if draft.isEmpty {
                    Text(placeholder)
                        .font(font)
                        .foregroundStyle(Theme.fgFaint)
                        .lineSpacing(3)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous)
                .fill(Theme.bgSunken.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous)
                .strokeBorder(focused ? Theme.amber.opacity(0.55) : Theme.divider, lineWidth: 1)
        )
        .animation(Theme.easeFast, value: focused)
        // ⌘↩ commits without leaving the field. Mounted only while focused,
        // so two editors on one pane never fight over the shortcut.
        .background {
            if focused {
                Button("") { commit() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .onAppear { draft = value }
        .onChange(of: value) { _, newValue in
            if !focused { draft = newValue }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != value.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
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
