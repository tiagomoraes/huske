import HuskeKit
import SwiftUI

/// "Transcription model": every model the engine knows, as a list on the
/// paper — read like a document, chosen with one plain button. The catalog,
/// its order, the facts and the evidence all come from `huske models`
/// (ADR 0006); this sheet only lays them out and runs `use`, `download` and
/// `try`.
struct ModelPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.screenRendering) private var rendering
    @Environment(\.dismiss) private var dismiss
    /// A Try that would download the model first, waiting for a yes.
    @State private var confirmTry: TranscriptionModel?

    var body: some View {
        let store = model.models
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Self.gutter)
                .padding(.top, 22)
                .padding(.bottom, 16)
            hairline
            PaneScroll {
                VStack(alignment: .leading, spacing: 0) {
                    if let catalog = store.catalog {
                        ForEach(Array(catalog.models.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { hairline }
                            ModelRow(item: item, language: language, confirmTry: $confirmTry)
                        }
                    } else if let error = store.loadError {
                        VStack(alignment: .leading, spacing: 6) {
                            FieldNote("Couldn't list the models: \(CleanupWords.sentence(error))", color: Theme.err)
                            Button("Try again") {
                                Task { await store.refresh(binary: model.binaryURL) }
                            }
                            .buttonStyle(LinkButtonStyle(fontSize: 12, tint: Theme.fgMuted, hoverTint: Theme.fg))
                        }
                        .padding(.vertical, 18)
                    } else {
                        HStack(spacing: 8) {
                            StateRing(kind: .progress(nil), size: 10)
                            Text("Asking the engine for its models…")
                                .font(.brandSans(12.5))
                                .foregroundStyle(Theme.fgMuted)
                        }
                        .padding(.vertical, 18)
                    }
                    hairline
                    AnotherModelSection()
                        .padding(.top, 18)
                        .padding(.bottom, 22)
                }
                .padding(.horizontal, Self.gutter)
            }
            hairline
            HStack {
                Spacer()
                Button("Done") {
                    store.pickerVisible = false
                    dismiss()
                }
                .buttonStyle(SecondaryButtonStyle())
                // Escape, not Return: Return belongs to the repo field.
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 680)
        .background(Theme.bg)
        .task {
            guard !rendering else { return }
            await store.refresh(binary: model.binaryURL)
        }
        .alert(
            confirmTry.map { "Download \($0.name) to try it?" } ?? "",
            isPresented: Binding(
                get: { confirmTry != nil },
                set: { if !$0 { confirmTry = nil } }),
            presenting: confirmTry
        ) { item in
            Button("Download and try") {
                store.tryModel(item.id, binary: model.binaryURL)
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(
                item.sizeMB.map { "This downloads \(ModelWords.size(mb: $0)) first." }
                    ?? "This downloads the model first.")
        }
    }

    static let gutter: CGFloat = 26

    /// The saved language setting — what the engine will actually use.
    private var language: String {
        model.config.snapshot?.string("language") ?? ""
    }

    private var hairline: some View {
        Rectangle().fill(Theme.divider).frame(height: 1)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Transcription model")
                .font(.brandSans(20, .semibold))
                .kerning(-0.2)
                .foregroundStyle(Theme.fg)
            Text(subtitle)
                .font(.brandSans(13))
                .foregroundStyle(Theme.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
            if model.session.isBusy {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Theme.recordRed)
                        .frame(width: 6, height: 6)
                    Text("The current recording keeps its model; the next one uses your choice.")
                        .font(.brandSans(12.5))
                        .foregroundStyle(Theme.fg)
                }
                .padding(.top, 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        let code = ModelWords.baseCode(language)
        let when = "Your choice applies from the next recording."
        guard !code.isEmpty else {
            return "Turns what's said into text, on this Mac. \(when)"
        }
        let name = ModelWords.languageName(code, names: model.cleanup.languages)
        return "Turns what's said into text, on this Mac. Your language is set to \(name). \(when)"
    }
}

// MARK: - one model

private struct ModelRow: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptionModel
    let language: String
    @Binding var confirmTry: TranscriptionModel?

    var body: some View {
        let names = model.cleanup.languages
        let notCovered = ModelWords.notCovered(item, code: language, names: names)
        let dim = notCovered != nil && !item.inUse
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                title
                    .opacity(dim ? Self.dimmed : 1)
                if let notCovered {
                    Text(notCovered)
                        .font(.brandSans(12.5, .medium))
                        .foregroundStyle(Theme.fg)
                }
                description(names: names)
                    .opacity(dim ? Self.dimmed : 1)
                tryArea
                problems
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            stateColumn
                .frame(width: 128, alignment: .trailing)
        }
        .padding(.vertical, 15)
    }

    private static let dimmed = 0.5

    // MARK: words

    private var title: Text {
        let name = Text(item.name)
            .font(.brandSans(13.5, .medium))
            .foregroundColor(Theme.fg)
        guard item.recommended else { return name }
        return name
            + Text("  ·  Recommended")
                .font(.brandSans(12.5))
                .foregroundColor(Theme.fgMuted)
    }

    @ViewBuilder
    private func description(names: [LanguageInfo]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !item.summary.isEmpty {
                Text(item.summary)
                    .font(.brandSans(12.5))
                    .foregroundStyle(Theme.fg)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !item.inCatalog {
                Text(item.repo)
                    .font(.brandMono(11.5))
                    .foregroundStyle(Theme.fgMuted)
                    .textSelection(.enabled)
            }
            if let note = ModelWords.rowNote(item, names: names) {
                Text(note)
                    .font(.brandSans(12))
                    .foregroundStyle(Theme.fg)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Each phrase holds together; the line wraps only between them.
            Text(
                ModelWords.rowFactParts(item, names: names)
                    .map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }
                    .joined(separator: " · ")
            )
            .font(.brandSans(11.5))
            .foregroundStyle(Theme.fgMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 1)
            if let measured = item.measured {
                Text("Measured: \(measured)")
                    .font(.brandSans(11))
                    .foregroundStyle(Theme.fgMuted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !item.runtimeAvailable {
                Text("This engine can't run \(item.familyLabel) models; updating it adds them.")
                    .font(.brandSans(12))
                    .foregroundStyle(Theme.fgMuted)
            }
        }
    }

    // MARK: try

    @ViewBuilder
    private var tryArea: some View {
        let store = model.models
        if store.trying == item.id {
            HStack(spacing: 8) {
                StateRing(kind: .progress(nil), size: 10)
                Text(item.downloaded ? "Transcribing a short sample…" : "Downloading, then transcribing a sample…")
                    .font(.brandSans(12))
                    .foregroundStyle(Theme.fgMuted)
                Button("Stop") { store.cancelTry() }
                    .buttonStyle(LinkButtonStyle(fontSize: 12, tint: Theme.fgMuted, hoverTint: Theme.fg))
            }
            .padding(.top, 6)
        } else {
            if let result = store.tries[item.id] {
                TrySampleView(result: result)
                    .padding(.top, 6)
            }
            if let error = store.tryErrors[item.id] {
                FieldNote("Couldn't try it: \(error)", color: Theme.err)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var tryButton: some View {
        let store = model.models
        if item.runtimeAvailable, store.trying != item.id {
            Button(store.tries[item.id] == nil ? "Try on this Mac" : "Try again") {
                if item.downloaded {
                    store.tryModel(item.id, binary: model.binaryURL)
                } else {
                    confirmTry = item
                }
            }
            .buttonStyle(LinkButtonStyle(fontSize: 12, tint: Theme.fgMuted, hoverTint: Theme.fg))
            .disabled(store.trying != nil)
            .help("Transcribes a short made-up sample in your language — nothing you recorded.")
        }
    }

    // MARK: errors
    // The engine's `notes` after a choice (first-use download, running
    // session) are not repeated here: the row's Download action and the
    // header's recording line already say both.

    @ViewBuilder
    private var problems: some View {
        let store = model.models
        if let error = store.useErrors[item.id] {
            Text(verbatim: CleanupWords.sentence(error))
                .font(.brandSans(12))
                .foregroundStyle(Theme.err)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error = store.downloadErrors[item.id] {
            FieldNote("Couldn't download it: \(error)", color: Theme.err)
        }
    }

    // MARK: state, on the right

    private var stateColumn: some View {
        let store = model.models
        return VStack(alignment: .trailing, spacing: 8) {
            if item.inUse {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.fgMuted)
                    Text("In use")
                        .font(.brandSans(12.5, .medium))
                        .foregroundStyle(Theme.fg)
                }
                .padding(.vertical, 4)
            } else if store.choosing == item.id {
                HStack(spacing: 6) {
                    StateRing(kind: .progress(nil), size: 10)
                    Text("Choosing…")
                        .font(.brandSans(12))
                        .foregroundStyle(Theme.fgMuted)
                }
                .padding(.vertical, 4)
            } else {
                Button("Use") {
                    Task {
                        await store.use(item.id, binary: model.binaryURL, config: model.config)
                    }
                }
                .buttonStyle(SecondaryButtonStyle(size: .small))
                // `models use` writes the config file itself; let queued
                // `config set` writes land first.
                .disabled(
                    !item.runtimeAvailable || store.choosing != nil || model.config.pendingWrites > 0)
            }
            if let download = store.downloads[item.id] {
                HStack(spacing: 6) {
                    StateRing(kind: .progress(download.fraction), size: 11)
                    if let fraction = download.fraction {
                        Text("\(Int((fraction * 100).rounded(.down))) %")
                            .font(.brandMono(11.5))
                            .foregroundStyle(Theme.fg)
                    } else {
                        Text("Downloading")
                            .font(.brandSans(12))
                            .foregroundStyle(Theme.fgMuted)
                    }
                    Button("Cancel") { store.cancelDownload(item.id) }
                        .buttonStyle(LinkButtonStyle(fontSize: 11.5, tint: Theme.fgMuted, hoverTint: Theme.fg))
                        .help("Stop downloading; the next try picks up where it stopped.")
                }
            } else if !item.downloaded, item.runtimeAvailable, store.trying != item.id {
                Button(item.sizeMB.map { "Download (\(ModelWords.size(mb: $0)))" } ?? "Download") {
                    store.download(item.id, binary: model.binaryURL)
                }
                .buttonStyle(LinkButtonStyle(fontSize: 12, tint: Theme.fgMuted, hoverTint: Theme.fg))
                .help("Fetch it now instead of on first use.")
            }
            tryButton
        }
    }
}

// MARK: - a Try result

/// "12.8× real time · loads in 2.8s", then what the model heard, set in
/// Plex Serif like every other thing someone said.
private struct TrySampleView: View {
    let result: ModelTryResult

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            speed
            if !result.text.isEmpty {
                Text(ModelWords.excerpt(result.text))
                    .font(.brandSerif(13))
                    .foregroundStyle(Theme.fg)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var speed: Text {
        ModelWords.tryPieces(result).reduce(Text("")) { line, piece in
            line + Text(piece.text).font(piece.number ? .brandMono(11.5) : .brandSans(11.5))
        }
        .foregroundColor(Theme.fgMuted)
    }
}

// MARK: - another model

private struct AnotherModelSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.models
        let draft = store.customDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 7) {
            Text("Another model")
                .font(.brandSans(13.5, .medium))
                .foregroundStyle(Theme.fg)
            Text("A Hugging Face repo (owner/name), or a folder on this Mac.")
                .font(.brandSans(12.5))
                .foregroundStyle(Theme.fg)
            HStack(spacing: 8) {
                ModelRepoField(
                    text: Binding(get: { store.customDraft }, set: { store.customDraft = $0 }),
                    prompt: "owner/model-name"
                ) { use(draft) }
                .frame(maxWidth: 380)
                if store.choosing != nil, store.choosing == draft {
                    StateRing(kind: .progress(nil), size: 10)
                } else {
                    Button("Use") { use(draft) }
                        .buttonStyle(SecondaryButtonStyle(size: .small))
                        .disabled(draft.isEmpty || store.choosing != nil || model.config.pendingWrites > 0)
                }
            }
            .padding(.top, 2)
            if store.convertible != nil {
                ConvertRow()
            } else if let error = store.customError {
                Text(verbatim: error)
                    .font(.brandSans(12))
                    .foregroundStyle(Theme.err)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460, alignment: .leading)
            }
            Text(familiesLine)
                .font(.brandSans(11.5))
                .foregroundStyle(Theme.fgMuted)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var familiesLine: String {
        let labels = model.models.catalog?.families.map(\.label) ?? []
        let named: String
        switch labels.count {
        case 0: named = "Parakeet and Whisper"
        case 1: named = labels[0]
        default: named = labels.dropLast().joined(separator: ", ") + " and " + labels[labels.count - 1]
        }
        return "New models of the \(named) famil\(labels.count == 1 ? "y" : "ies") work without an app update."
    }

    private func use(_ value: String) {
        guard !value.isEmpty, model.config.pendingWrites == 0 else { return }
        Task {
            await model.models.use(value, custom: true, binary: model.binaryURL, config: model.config)
        }
    }
}

/// Offered when the repo is a Whisper fine-tune in the transformers layout
/// (most language fine-tunes are): Huske converts it once into its own
/// models folder, then uses it.
private struct ConvertRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.models
        VStack(alignment: .leading, spacing: 6) {
            Text("This is a Whisper fine-tune in a format Huske converts once: it downloads the original and keeps a copy for this Mac.")
                .font(.brandSans(12))
                .foregroundStyle(Theme.fg)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460, alignment: .leading)
            HStack(spacing: 8) {
                if let progress = store.conversion {
                    StateRing(kind: .progress(progress.fraction), size: 10)
                    Text(progress.fraction.map { "\(Int(($0 * 100).rounded())) %" } ?? "Starting")
                        .font(.brandMono(11.5))
                        .foregroundStyle(Theme.fg)
                    Button("Cancel") { store.cancelConversion() }
                        .buttonStyle(.plain)
                        .font(.brandSans(12))
                        .foregroundStyle(Theme.fgMuted)
                } else {
                    Button("Convert and use") {
                        store.convertAndUse(binary: model.binaryURL, config: model.config)
                    }
                    .buttonStyle(SecondaryButtonStyle(size: .small))
                }
            }
            if let error = store.conversionError {
                Text(verbatim: error)
                    .font(.brandSans(12))
                    .foregroundStyle(Theme.err)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460, alignment: .leading)
            }
        }
    }
}

/// A one-line field in the pane's chrome for a repo id or a folder path
/// (mono: it is an identifier). Under the offscreen renderer it draws its
/// text or prompt statically.
private struct ModelRepoField: View {
    @Binding var text: String
    let prompt: String
    let onSubmit: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.screenRendering) private var rendering

    var body: some View {
        Group {
            if rendering {
                Text(text.isEmpty ? prompt : text)
                    .font(.brandMono(11.5))
                    .foregroundStyle(text.isEmpty ? Theme.fgFaint : Theme.fg)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(
                    "", text: $text,
                    prompt: Text(prompt).font(.brandMono(11.5)).foregroundStyle(Theme.fgFaint)
                )
                .textFieldStyle(.plain)
                .font(.brandMono(11.5))
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
