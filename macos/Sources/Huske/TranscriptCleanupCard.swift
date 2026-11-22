import HuskeKit
import SwiftUI

/// "Transcript cleanup": which language model polishes finished transcripts,
/// and everything that choice needs — a model, an endpoint, an API key,
/// consent before text leaves the Mac. The engine owns all of it (ADR 0006):
/// config goes through `huske config`, the rest through `huske llm`, and the
/// status line repeats the engine's own words.
struct TranscriptCleanupCard: View {
    @Environment(AppModel.self) private var model
    /// The API key being typed. Lives only here, is handed to the engine on
    /// stdin, and is cleared the moment it is sent or the provider changes.
    @State private var keyDraft = ""
    @State private var replacingKey = false

    static let onThisMac: [(String, String)] = [
        ("apple", "Apple Intelligence"),
        ("mlx", "Built-in model (Qwen, downloads once)"),
        ("ollama", "Ollama"),
        ("openai_compatible", "OpenAI-compatible server (LM Studio and others)"),
    ]
    static let offThisMac: [(String, String)] = [
        ("openai", "OpenAI"),
        ("anthropic", "Anthropic"),
        ("openrouter", "OpenRouter"),
    ]
    /// Providers that take a key when the engine has not said yet.
    private static let keyProviders: Set<String> = [
        "openai", "anthropic", "openrouter", "openai_compatible",
    ]

    var body: some View {
        let config = model.config
        let cleanup = model.cleanup
        let backend = config.string("distill_backend", default: "mlx")
        // A status about another provider (the one just switched away from)
        // describes nothing on screen.
        let status = cleanup.status.flatMap { $0.backend == backend ? $0 : nil }
        Card {
            VStack(alignment: .leading, spacing: 13) {
                SectionLabel("Transcript cleanup")
                SettingToggle(
                    isOn: config.boolBinding("distill_enabled"),
                    title: "Clean up transcripts with a language model",
                    subtitle: "Fixes punctuation, misheard words and your dictionary's spellings "
                        + "after each transcript is saved. The original stays next to it.")
                hairline
                LabeledRow("Runs on", explicit: config.isExplicit("distill_backend")) {
                    VStack(alignment: .leading, spacing: 8) {
                        providerPicker(backend)
                        CleanupStatusLine(
                            status: status,
                            error: status == nil ? cleanup.statusError : nil,
                            checking: cleanup.checking
                        ) {
                            Task { await cleanup.refreshStatus(binary: model.binaryURL) }
                        }
                        .frame(maxWidth: 400, alignment: .leading)
                    }
                }
                // Setup order: where the server is, the key that opens it,
                // then which of its models (the list needs the key).
                if LLMProviderInfo.endpointProviders.contains(backend) {
                    endpointRow(backend, status)
                }
                if takesKey(backend, status) {
                    keyRow(backend, status)
                }
                if backend != "apple" {
                    modelRow(backend, status)
                }
                if let status, status.leavesMac, let host = status.host {
                    consentRow(status, host: host)
                }
                hairline
                LabeledRow("Extra instructions", explicit: config.isExplicit("distill_instructions")) {
                    CommittingTextEditor(
                        value: config.string("distill_instructions"),
                        placeholder: "Optional — for example: Remove filler words.",
                        minHeight: 52
                    ) { text in
                        if text.isEmpty {
                            config.unset("distill_instructions")
                        } else {
                            config.set("distill_instructions", to: .string(text))
                        }
                    }
                    .frame(maxWidth: 400)
                }
                LabeledRow("", explicit: false) {
                    tryIt(status)
                        .frame(maxWidth: 400, alignment: .leading)
                }
            }
        }
        // Refresh whenever what the engine would answer may have changed. The
        // ids read the *saved* config, not optimistic values, so a check never
        // races the write it is meant to follow.
        .task(id: statusTrigger) {
            await cleanup.refreshStatus(binary: model.binaryURL)
        }
        .task(id: "\(backend)|\(saved("distill_endpoint"))|\(cleanup.status?.keys[backend] ?? false)") {
            guard backend != "apple" else { return }
            await cleanup.refreshModels(binary: model.binaryURL, backend: backend)
        }
        .onChange(of: backend) {
            keyDraft = ""
            replacingKey = false
        }
        .onDisappear { keyDraft = "" }
    }

    private var statusTrigger: String {
        ["distill_backend", "distill_model", "distill_endpoint", "distill_cloud_consent", "language"]
            .map(saved)
            .joined(separator: "|")
    }

    private func saved(_ key: String) -> String {
        model.config.snapshot?.string(key) ?? ""
    }

    private var hairline: some View {
        Rectangle().fill(Theme.divider).frame(height: 1)
    }

    // MARK: provider

    @Environment(\.screenRendering) private var rendering

    @ViewBuilder
    private func providerPicker(_ backend: String) -> some View {
        let all = Self.onThisMac + Self.offThisMac
        if rendering {
            MenuStandIn(title: all.first { $0.0 == backend }?.1 ?? backend)
                .frame(maxWidth: 400)
        } else {
            Picker(
                "",
                selection: Binding(
                    get: { backend },
                    set: { choose($0, replacing: backend) }
                )
            ) {
                Section("On this Mac") {
                    ForEach(Self.onThisMac, id: \.0) { Text($0.1).tag($0.0) }
                }
                Section("Sends transcript text off this Mac") {
                    ForEach(Self.offThisMac, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
            .labelsHidden()
            .frame(maxWidth: 400)
        }
    }

    /// A new provider starts from its own defaults: the old model id and
    /// endpoint mean nothing to it (an Ollama tag is not an OpenAI model).
    private func choose(_ provider: String, replacing current: String) {
        guard provider != current else { return }
        keyDraft = ""
        replacingKey = false
        model.cleanup.providerChanged()
        model.config.apply([
            .unset("distill_model"),
            .unset("distill_endpoint"),
            .set("distill_backend", .string(provider)),
        ])
    }

    // MARK: model

    private func modelRow(_ backend: String, _ status: LLMStatus?) -> some View {
        let config = model.config
        let cleanup = model.cleanup
        let provider = status?.provider(named: backend)
        let list = cleanup.modelsBackend == backend ? cleanup.models : nil
        let defaultTitle: String
        if backend == "openai_compatible" {
            defaultTitle = "Uses the first model the server lists"
        } else if let fallback = provider?.defaultModel {
            defaultTitle = "\(fallback) (default)"
        } else {
            defaultTitle = "Choose a model"
        }
        var options: [(String, String)] = [("", defaultTitle)]
        var seen: Set<String> = [""]
        for id in list?.models ?? [] where id != provider?.defaultModel && !seen.contains(id) {
            seen.insert(id)
            options.append((id, id))
        }
        var note: String?
        if list == nil, cleanup.loadingModels {
            note = "Asking for the list of models…"
        } else if let error = list?.error, status?.reason != "needs_key" {
            note = CleanupWords.sentence(error)
        }
        return CuratedPicker(
            label: "Model",
            explicit: config.isExplicit("distill_model"),
            options: options,
            value: config.string("distill_model"),
            customPrompt: backend == "openai_compatible"
                ? "Uses the first model the server lists" : "Model id",
            note: note,
            accessory: AnyView(
                IconAction(symbol: "arrow.clockwise", help: "Ask again which models are available") {
                    Task { await cleanup.refreshModels(binary: model.binaryURL, backend: backend) }
                }
                .disabled(cleanup.loadingModels)
            )
        ) { value in
            if value.isEmpty {
                config.unset("distill_model")
            } else {
                config.set("distill_model", to: .string(value))
            }
        }
    }

    // MARK: endpoint

    private func endpointRow(_ backend: String, _ status: LLMStatus?) -> some View {
        let config = model.config
        let fallback =
            status?.provider(named: backend)?.defaultEndpoint
            ?? (backend == "ollama" ? "http://127.0.0.1:11434" : "http://127.0.0.1:1234/v1")
        return LabeledRow("Endpoint", explicit: config.isExplicit("distill_endpoint")) {
            CommittingTextField(value: config.string("distill_endpoint"), prompt: fallback) { value in
                if value.isEmpty {
                    config.unset("distill_endpoint")
                } else {
                    config.set("distill_endpoint", to: .string(value))
                }
            }
            .frame(maxWidth: 300)
        }
    }

    // MARK: key

    private func takesKey(_ backend: String, _ status: LLMStatus?) -> Bool {
        if let status, !status.keys.isEmpty { return status.keys[backend] != nil }
        return Self.keyProviders.contains(backend)
    }

    private func keyRow(_ backend: String, _ status: LLMStatus?) -> some View {
        let cleanup = model.cleanup
        let optional = !(status?.provider(named: backend)?.needsKey ?? (backend != "openai_compatible"))
        let saved = status?.keys[backend] ?? false
        let label = status?.label ?? backend
        return LabeledRow(optional ? "API key (optional)" : "API key", explicit: false) {
            VStack(alignment: .leading, spacing: 6) {
                if saved && !replacingKey {
                    HStack(spacing: 8) {
                        Text("Saved in your Keychain")
                            .font(.brandSans(12.5))
                            .foregroundStyle(Theme.fgMuted)
                        Button("Replace") { replacingKey = true }
                            .buttonStyle(SecondaryButtonStyle(size: .small))
                        Button("Remove") {
                            Task { await cleanup.removeKey(binary: model.binaryURL, provider: backend) }
                        }
                        .buttonStyle(SecondaryButtonStyle(size: .small))
                        .disabled(cleanup.keyBusy)
                    }
                } else {
                    HStack(spacing: 8) {
                        KeyField(text: $keyDraft, prompt: "Paste your \(label) API key") {
                            saveKey(backend)
                        }
                        .frame(maxWidth: 280)
                        saveButton(backend, primary: !optional)
                        if replacingKey {
                            Button("Cancel") {
                                replacingKey = false
                                keyDraft = ""
                            }
                            .buttonStyle(SecondaryButtonStyle(size: .small))
                        }
                    }
                    if optional {
                        FieldNote("Only if your server asks for one.")
                    }
                }
                if let error = cleanup.keyError {
                    FieldNote(CleanupWords.sentence(error), color: Theme.err)
                }
            }
        }
    }

    @ViewBuilder
    private func saveButton(_ backend: String, primary: Bool) -> some View {
        let disabled = keyDraft.trimmingCharacters(in: .whitespaces).isEmpty || model.cleanup.keyBusy
        if primary {
            Button("Save") { saveKey(backend) }
                .buttonStyle(PrimaryButtonStyle(size: .small))
                .disabled(disabled)
        } else {
            Button("Save") { saveKey(backend) }
                .buttonStyle(SecondaryButtonStyle(size: .small))
                .disabled(disabled)
        }
    }

    private func saveKey(_ backend: String) {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        keyDraft = ""
        guard !key.isEmpty else { return }
        Task {
            if await model.cleanup.saveKey(binary: model.binaryURL, provider: backend, key: key) {
                replacingKey = false
            }
        }
    }

    // MARK: consent

    private func consentRow(_ status: LLMStatus, host: String) -> some View {
        let cleanup = model.cleanup
        let busy = cleanup.consentBusy || model.config.pendingWrites > 0
        return LabeledRow("Privacy", explicit: model.config.isExplicit("distill_cloud_consent")) {
            VStack(alignment: .leading, spacing: 8) {
                if status.consent {
                    HStack(spacing: 8) {
                        Text("Allowed to send transcripts to \(host)")
                            .font(.brandSans(12.5))
                            .foregroundStyle(Theme.fgMuted)
                        Button("Stop sending") {
                            Task {
                                await cleanup.setCloudConsent(
                                    false, binary: model.binaryURL, config: model.config)
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle(size: .small))
                        .disabled(busy)
                    }
                } else {
                    Text(
                        "Cleanup with \(status.label) sends the text of every transcript to "
                            + "\(host). Audio never leaves this Mac. Until you allow it, "
                            + "transcripts stay raw."
                    )
                    .font(.brandSans(12.5))
                    .foregroundStyle(Theme.fg)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    allowButton(host, primary: !status.keyRequired || status.keyPresent, busy: busy)
                }
                if let error = cleanup.consentError {
                    FieldNote(CleanupWords.sentence(error), color: Theme.err)
                }
            }
            .frame(maxWidth: 400, alignment: .leading)
        }
    }

    /// Amber only once the key is in: one primary action on screen at a time.
    @ViewBuilder
    private func allowButton(_ host: String, primary: Bool, busy: Bool) -> some View {
        let action = {
            Task {
                await model.cleanup.setCloudConsent(
                    true, binary: model.binaryURL, config: model.config)
            }
        }
        if primary {
            Button("Allow sending to \(host)") { _ = action() }
                .buttonStyle(PrimaryButtonStyle(size: .small))
                .disabled(busy)
        } else {
            Button("Allow sending to \(host)") { _ = action() }
                .buttonStyle(SecondaryButtonStyle(size: .small))
                .disabled(busy)
        }
    }

    // MARK: try it

    private func tryIt(_ status: LLMStatus?) -> some View {
        let cleanup = model.cleanup
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button("Try it") {
                    Task { await cleanup.runTest(binary: model.binaryURL) }
                }
                .buttonStyle(SecondaryButtonStyle(size: .small))
                .disabled(cleanup.testing || model.config.pendingWrites > 0 || status?.ready != true)
                if cleanup.testing {
                    StateRing(kind: .progress(nil), size: 10)
                    Text("Cleaning up a short sample…")
                        .font(.brandSans(12))
                        .foregroundStyle(Theme.fgMuted)
                } else {
                    Text("Cleans up two made-up lines — nothing from your transcripts.")
                        .font(.brandSans(11.5))
                        .foregroundStyle(Theme.fgMuted)
                }
            }
            if let test = cleanup.test {
                CleanupSampleView(result: test)
            }
            if let error = cleanup.testError {
                FieldNote(
                    "Couldn't clean up the sample: \(CleanupWords.sentence(error))",
                    color: Theme.err)
            }
        }
    }
}

// MARK: - pieces

/// The provider's state in the quiet-instrument language: one glyph and the
/// engine's own sentence. Ready needs no colour. A step the rows below take
/// care of (key, consent, model) is plain ink beside a hairline ring; one to
/// take elsewhere (System Settings) is warn-coloured; a failure is
/// err-coloured with its way out underneath.
struct CleanupStatusLine: View {
    let status: LLMStatus?
    let error: String?
    let checking: Bool
    let recheck: () -> Void

    var body: some View {
        if let status {
            if status.ready {
                line(.done, status.detail, Theme.fgMuted, hint: nil, offerRecheck: false)
            } else {
                let appleDown = status.backend == "apple" && status.apple?.available == false
                let detail = appleDown ? (status.apple?.detail ?? status.detail) : status.detail
                let hint: String? =
                    appleDown
                    ? status.apple?.hint
                    : (LLMStatus.inlineReasons.contains(status.reason) ? nil : status.hint)
                let inline = LLMStatus.inlineReasons.contains(status.reason)
                line(
                    status.awaitingSetup ? .waiting : .failed,
                    detail,
                    inline ? Theme.fg : (status.awaitingSetup ? Theme.warn : Theme.err),
                    hint: hint,
                    offerRecheck: !inline)
            }
        } else if let error {
            line(.failed, error, Theme.err, hint: nil, offerRecheck: true)
        } else {
            line(.progress(nil), "Checking…", Theme.fgMuted, hint: nil, offerRecheck: false)
        }
    }

    private func line(
        _ kind: StateRing.Kind, _ text: String, _ color: Color, hint: String?, offerRecheck: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            StateRing(kind: kind, size: 10)
                .padding(.top, 2.5)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: CleanupWords.sentence(text))
                    .font(.brandSans(12.5))
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint, !hint.isEmpty {
                    FieldNote(hint)
                }
                if offerRecheck {
                    Button(checking ? "Checking…" : "Check again", action: recheck)
                        .buttonStyle(LinkButtonStyle(fontSize: 11.5, tint: Theme.fgMuted, hoverTint: Theme.fg))
                        .disabled(checking)
                        .padding(.top, 1)
                }
            }
        }
    }
}

/// The test's before/after pairs, set like a transcript: what was said in
/// Plex Serif, the margin words in sans, the duration in mono.
struct CleanupSampleView: View {
    let result: LLMTestResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(result.pairs.enumerated()), id: \.offset) { _, pair in
                VStack(alignment: .leading, spacing: 4) {
                    sampleLine("Before", pair.before, Theme.fgMuted)
                    sampleLine("After", pair.after, Theme.fg)
                }
            }
            summary
                .padding(.leading, Self.margin + 12)
        }
    }

    private static let margin: CGFloat = 40

    private func sampleLine(_ label: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.brandSans(11, .medium))
                .foregroundStyle(Theme.fgFaint)
                .frame(width: Self.margin, alignment: .trailing)
            Text(text)
                .font(.brandSerif(13.5))
                .foregroundStyle(color)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summary: Text {
        let lines = result.input.count
        var words = "Changed \(result.changed) of \(lines) line\(lines == 1 ? "" : "s")"
        if result.keptRaw > 0 {
            words += ", kept \(result.keptRaw) as heard"
        }
        let sans = Text(words + (result.seconds == nil ? "" : " in "))
            .font(.brandSans(11.5))
        guard let seconds = result.seconds else { return sans.foregroundColor(Theme.fgMuted) }
        return (sans + Text(CleanupWords.seconds(seconds)).font(.brandMono(11.5)))
            .foregroundColor(Theme.fgMuted)
    }
}

/// Secure entry for an API key, in the pane's field chrome. Never echoes the
/// key; under the offscreen renderer it draws only its prompt.
struct KeyField: View {
    @Binding var text: String
    let prompt: String
    let onSubmit: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.screenRendering) private var rendering

    var body: some View {
        Group {
            if rendering {
                Text(prompt)
                    .font(.brandSans(12.5))
                    .foregroundStyle(Theme.fgFaint)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                SecureField(
                    "", text: $text,
                    prompt: Text(prompt).font(.brandSans(12.5)).foregroundStyle(Theme.fgFaint)
                )
                .textFieldStyle(.plain)
                .font(.brandSans(12.5))
                .foregroundStyle(Theme.fg)
                .focused($focused)
                .onSubmit(onSubmit)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous)
                .fill(Theme.bgSunken.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous)
                .strokeBorder(focused ? Theme.amber.opacity(0.55) : Theme.divider, lineWidth: 1)
        )
        .animation(Theme.easeFast, value: focused)
    }
}
