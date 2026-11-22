import HuskeKit
import SwiftUI

/// The custom dictionary: words to spell your way (`vocabulary`) and fixed
/// corrections (`vocabulary_replacements`). The engine decides what each list
/// does per transcription model (`dictionary` in `huske models`: `prompt`,
/// `boost` or `none`); this card only edits them and says so.
struct DictionaryCard: View {
    @Environment(AppModel.self) private var model
    /// Correction rows as edited, in the order the user made them. Rebuilt
    /// from the config only when the config says something different, so a
    /// half-typed row survives a reload.
    @State private var rows: [CorrectionRow] = []
    @Environment(\.screenRendering) private var rendering

    struct CorrectionRow: Identifiable, Equatable {
        let id = UUID()
        var heard: String
        var written: String
    }

    var body: some View {
        let config = model.config
        let table = config.stringMap("vocabulary_replacements")
        // What the dictionary does depends on the model in use; the engine
        // name stands in when the catalog isn't known (older engines).
        let current = model.capabilities?.modelsCLI == true ? model.models.current : nil
        let engine = config.string("asr_engine", default: "parakeet")
        let mode = current?.dictionary ?? (engine == "whisper" ? "prompt" : "boost")
        Card {
            VStack(alignment: .leading, spacing: 13) {
                VStack(alignment: .leading, spacing: 3) {
                    SectionLabel("Dictionary")
                    Text("Names, products and jargon you want spelled your way.")
                        .font(.brandSans(12))
                        .foregroundStyle(Theme.fgMuted)
                }
                LabeledRow("Words", explicit: config.isExplicit("vocabulary")) {
                    VStack(alignment: .leading, spacing: 6) {
                        CommittingTextEditor(
                            value: config.stringList("vocabulary").joined(separator: "\n"),
                            placeholder: "Kubernetes\nOKR\nMarta Ribeiro",
                            minHeight: 86
                        ) { commitWords($0) }
                        FieldNote(
                            current.map(ModelWords.dictionaryNote)
                                ?? (mode == "prompt"
                                    ? "One per line, most important first. "
                                        + "Whisper also hears these words more readily."
                                    : "One per line, most important first."))
                    }
                    .frame(maxWidth: 400, alignment: .leading)
                }
                LabeledRow("Corrections", explicit: config.isExplicit("vocabulary_replacements")) {
                    corrections(table)
                        .frame(maxWidth: 400, alignment: .leading)
                }
                if mode == "boost" {
                    SettingToggle(
                        isOn: config.boolBinding("parakeet_word_boost"),
                        title: "Listen for these words while transcribing",
                        subtitle: "Spells more of them right; transcription takes about four times longer.")
                }
                Text("Corrections apply to every transcript, and both lists guide transcript cleanup.")
                    .font(.brandSans(11.5))
                    .foregroundStyle(Theme.fgMuted)
            }
        }
        .onAppear { syncRows(from: table) }
        .onChange(of: table) { _, newTable in syncRows(from: newTable) }
    }

    private func corrections(_ table: [String: String]) -> some View {
        // The offscreen renderer runs no onAppear; draw straight from config.
        let shown = rendering ? Self.rows(from: table) : rows
        return VStack(alignment: .leading, spacing: 6) {
            if !shown.isEmpty {
                HStack(spacing: 8) {
                    Text("Heard as")
                        .frame(width: Self.fieldWidth, alignment: .leading)
                    Color.clear.frame(width: 10, height: 1)
                    Text("Write as")
                }
                .font(.brandSans(11.5))
                .foregroundStyle(Theme.fgMuted)
                if rendering {
                    ForEach(shown) { row in correctionRow(.constant(row)) }
                } else {
                    ForEach($rows) { $row in correctionRow($row) }
                }
            }
            Button {
                rows.append(CorrectionRow(heard: "", written: ""))
            } label: {
                Label("Add a correction", systemImage: "plus")
            }
            .buttonStyle(LinkButtonStyle(fontSize: 12, tint: Theme.fgMuted, hoverTint: Theme.fg))
            .padding(.top, shown.isEmpty ? 2 : 0)
        }
    }

    private func correctionRow(_ row: Binding<CorrectionRow>) -> some View {
        HStack(spacing: 8) {
            CommittingTextField(
                value: row.wrappedValue.heard, prompt: "cube ernetes",
                font: .brandSans(12.5)
            ) {
                row.wrappedValue.heard = $0
                commitRows()
            }
            .frame(width: Self.fieldWidth)
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.fgFaint)
                .frame(width: 10)
            CommittingTextField(
                value: row.wrappedValue.written, prompt: "Kubernetes",
                font: .brandSans(12.5)
            ) {
                row.wrappedValue.written = $0
                commitRows()
            }
            .frame(width: Self.fieldWidth)
            IconAction(symbol: "minus.circle", help: "Remove this correction") {
                let id = row.wrappedValue.id
                rows.removeAll { $0.id == id }
                commitRows()
            }
        }
    }

    private static let fieldWidth: CGFloat = 160

    // MARK: writes

    private func commitWords(_ text: String) {
        let config = model.config
        let words = CleanupWords.vocabulary(fromLines: text)
        guard words != config.stringList("vocabulary") else { return }
        if words.isEmpty {
            config.unset("vocabulary")
        } else {
            config.set("vocabulary", to: .array(words.map { .string($0) }))
        }
    }

    private func commitRows() {
        let config = model.config
        let table = CleanupWords.replacements(fromRows: rows.map { ($0.heard, $0.written) })
        guard table != config.stringMap("vocabulary_replacements") else { return }
        if table.isEmpty {
            config.unset("vocabulary_replacements")
        } else {
            config.set("vocabulary_replacements", to: .object(table.mapValues { .string($0) }))
        }
    }

    private func syncRows(from table: [String: String]) {
        let current = CleanupWords.replacements(fromRows: rows.map { ($0.heard, $0.written) })
        guard current != table else { return }
        rows = Self.rows(from: table)
    }

    private static func rows(from table: [String: String]) -> [CorrectionRow] {
        table
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { CorrectionRow(heard: $0.key, written: $0.value) }
    }
}
