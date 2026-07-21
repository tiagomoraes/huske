import HuskeKit
import SwiftUI

struct TranscriptsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: TranscriptEntry?
    @State private var query = ""
    @State private var searchHits: [TranscriptEntry]?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            listPane
                .frame(width: 302)
            Rectangle()
                .fill(Theme.divider)
                .frame(width: 1)
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .onAppear { model.transcripts.refresh() }
    }

    // MARK: list

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transcripts")
                    .font(.brandSans(17, .semibold))
                    .foregroundStyle(Theme.fg)
                Spacer()
                Button {
                    model.transcripts.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.fgMuted)
                }
                .buttonStyle(.plain)
                .help("Rescan the transcripts folder")
                Button {
                    if let root = model.transcripts.root {
                        NSWorkspace.shared.open(root)
                    }
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.fgMuted)
                }
                .buttonStyle(.plain)
                .help("Open the transcripts folder in Finder")
            }
            .padding(.top, 34)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            if let hits = searchHits {
                resultsList(sections: [("\(hits.count) match\(hits.count == 1 ? "" : "es")", hits)], showDay: true)
            } else if model.transcripts.days.isEmpty {
                emptyState
            } else {
                resultsList(
                    sections: model.transcripts.days.map { (Self.dayTitle($0.date), $0.entries) },
                    showDay: false)
            }
        }
        .background(Theme.bgSubtle.opacity(0.35))
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.fgMuted)
            TextField("", text: $query, prompt: Text("Search transcripts").font(.brandSans(12)).foregroundStyle(Theme.fgMuted))
                .textFieldStyle(.plain)
                .font(.brandSans(12.5))
                .foregroundStyle(Theme.fg)
                .onChange(of: query) { _, newValue in
                    scheduleSearch(newValue)
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    searchHits = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.fgFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusMD, style: .continuous)
                .fill(Theme.bgSunken.opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusMD, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        )
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchHits = nil
            return
        }
        searchTask = Task { [store = model.transcripts] in
            try? await Task.sleep(nanoseconds: 250_000_000) // debounce
            guard !Task.isCancelled else { return }
            let hits = await store.search(trimmed)
            guard !Task.isCancelled else { return }
            searchHits = hits
        }
    }

    private func resultsList(sections: [(String, [TranscriptEntry])], showDay: Bool) -> some View {
        PaneScroll {
            LazyVStack(alignment: .leading, spacing: 1, pinnedViews: []) {
                ForEach(sections, id: \.0) { title, entries in
                    Text(title)
                        .font(.brandMono(10.5, .medium))
                        .kerning(0.6)
                        .foregroundStyle(Theme.fgMuted)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 5)
                    ForEach(entries) { entry in
                        TranscriptRowView(
                            entry: entry,
                            showDay: showDay,
                            selected: selection == entry
                        ) {
                            selection = entry
                        }
                        .padding(.horizontal, 8)
                    }
                }
            }
            .padding(.bottom, 14)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "text.document")
                .font(.system(size: 26))
                .foregroundStyle(Theme.fgFaint)
            Text("No transcripts yet")
                .font(.brandSans(13, .semibold))
                .foregroundStyle(Theme.fg)
            Text("Finished chunks land here as Markdown,\norganized by day.")
                .font(.brandSans(12))
                .foregroundStyle(Theme.fgMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: detail

    @ViewBuilder
    private var detailPane: some View {
        if let selection {
            TranscriptDetailView(entry: selection)
                .id(selection.url)
        } else {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.fgFaint)
                Text("Select a transcript")
                    .font(.brandSans(13))
                    .foregroundStyle(Theme.fgFaint)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    static func dayTitle(_ isoDay: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: isoDay) else { return isoDay }
        if Calendar.current.isDateInToday(date) { return "today · \(isoDay)" }
        if Calendar.current.isDateInYesterday(date) { return "yesterday · \(isoDay)" }
        let out = DateFormatter()
        out.dateFormat = "EEE"
        return "\(out.string(from: date).lowercased()) · \(isoDay)"
    }
}

struct TranscriptRowView: View {
    let entry: TranscriptEntry
    let showDay: Bool
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(entry.timeString)
                    .font(.brandMono(11.5, selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.amber : Theme.fgMuted)
                VStack(alignment: .leading, spacing: 1) {
                    Text("chunk \(String(format: "%03d", entry.chunkSeq))")
                        .font(.brandSans(12.5, .medium))
                        .foregroundStyle(Theme.fg)
                    Text(
                        showDay
                            ? entry.url.deletingLastPathComponent().lastPathComponent
                            : "session \(entry.sessionId8)"
                    )
                    .font(.brandMono(10))
                    .foregroundStyle(Theme.fgFaint)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMD, style: .continuous)
                    .fill(
                        selected
                            ? Theme.amber.opacity(0.14)
                            : (hovering ? Theme.divider.opacity(0.6) : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusMD))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - detail

struct TranscriptDetailView: View {
    @Environment(AppModel.self) private var model
    let entry: TranscriptEntry

    @State private var document: TranscriptDocument?
    @State private var loadFailed = false
    @State private var showRaw = false

    var body: some View {
        Group {
            if let document {
                loaded(document)
            } else if loadFailed {
                VStack {
                    Spacer()
                    Text("Could not read this transcript")
                        .font(.brandSans(13))
                        .foregroundStyle(Theme.err)
                    Spacer()
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: entry.url) {
            document = nil
            loadFailed = false
            if let doc = await model.transcripts.loadDocument(at: entry.url) {
                document = doc
            } else {
                loadFailed = true
            }
        }
    }

    private func loaded(_ document: TranscriptDocument) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            detailHeader(document)
            Rectangle().fill(Theme.divider).frame(height: 1)
            if showRaw {
                ScrollView {
                    Text(document.rawBody)
                        .font(.brandMono(12))
                        .foregroundStyle(Theme.fg)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            } else if document.isEmpty {
                VStack {
                    Spacer()
                    Text("(no speech detected in this chunk)")
                        .font(.brandSans(13))
                        .foregroundStyle(Theme.fgFaint)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(document.runs) { run in
                            RunRow(run: run)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 720, alignment: .leading)
                }
            }
        }
    }

    private func detailHeader(_ document: TranscriptDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(document.heading ?? entry.filename)
                    .font(.brandSans(17, .semibold))
                    .kerning(-0.2)
                    .foregroundStyle(Theme.fg)
                Spacer()
                HStack(spacing: 2) {
                    IconAction(
                        symbol: "chevron.left.forwardslash.chevron.right",
                        help: "Show the raw Markdown",
                        active: showRaw
                    ) { showRaw.toggle() }
                    IconAction(symbol: "folder", help: "Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                    }
                    IconAction(symbol: "arrow.up.forward.app", help: "Open in the default editor") {
                        NSWorkspace.shared.open(entry.url)
                    }
                }
            }
            HStack(spacing: 6) {
                MetaChip(
                    text: Self.durationText(document.meta.durationActualSeconds),
                    symbol: "clock")
                MetaChip(text: document.meta.model, symbol: "cpu")
                if !document.meta.language.isEmpty {
                    MetaChip(text: document.meta.language, symbol: "globe")
                }
                ForEach(document.meta.audioSources, id: \.self) { source in
                    MetaChip(
                        text: source == "microphone" ? "mic" : source,
                        symbol: source == "microphone" ? "mic" : "speaker.wave.2")
                }
                if document.meta.incomplete {
                    MetaChip(text: "incomplete", symbol: "exclamationmark.triangle")
                }
                Spacer()
            }
        }
        .padding(.top, 30)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        return "\(total / 60)m \(total % 60)s"
    }
}

struct IconAction: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? Theme.amber : Theme.fgMuted)
                .frame(width: 27, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous)
                        .fill(
                            active
                                ? Theme.amber.opacity(0.13)
                                : (hovering ? Theme.divider.opacity(0.7) : Color.clear))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct MetaChip: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 8.5))
            Text(text)
                .font(.brandMono(10.5))
        }
        .foregroundStyle(Theme.fgMuted)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous)
                .fill(Theme.bgSunken.opacity(0.65))
        )
    }
}

struct RunRow: View {
    let run: TranscriptRun

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(run.time)
                    .font(.brandMono(11))
                    .foregroundStyle(Theme.fgFaint)
                sourceBadge
            }
            .frame(width: 74, alignment: .trailing)
            Text(run.text)
                .font(.brandSans(13.5))
                .foregroundStyle(Theme.fg)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sourceBadge: some View {
        Text(label)
            .font(.brandMono(8.5, .semibold))
            .kerning(0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusXS, style: .continuous)
                    .fill(color.opacity(0.15))
            )
            .foregroundStyle(color)
    }

    private var label: String {
        switch run.source {
        case .mic: return "MIC"
        case .system: return "SYS"
        case .micEcho: return "ECHO"
        case .unknown: return "?"
        }
    }

    private var color: Color {
        switch run.source {
        case .mic: return Theme.amber
        case .system: return Theme.info
        case .micEcho: return Theme.fgFaint
        case .unknown: return Theme.fgFaint
        }
    }
}
