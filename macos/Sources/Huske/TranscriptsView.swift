import HuskeKit
import SwiftUI

struct TranscriptsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: TranscriptEntry?
    @State private var query = ""
    @State private var searchHits: [TranscriptEntry]?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        HSplitView {
            listPane
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            detailPane
                .frame(minWidth: 400, maxWidth: .infinity)
        }
        .background(Theme.bg)
        .navigationTitle("Transcripts")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.transcripts.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Rescan the transcripts folder")
                Button {
                    if let root = model.transcripts.root {
                        NSWorkspace.shared.open(root)
                    }
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help("Open the transcripts folder in Finder")
            }
        }
        .onAppear { model.transcripts.refresh() }
    }

    // MARK: list

    private var listPane: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if let hits = searchHits {
                searchResults(hits)
            } else if model.transcripts.days.isEmpty {
                emptyState
            } else {
                dayList
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.fgFaint)
            TextField("Search transcripts", text: $query)
                .textFieldStyle(.plain)
                .onChange(of: query) { _, newValue in
                    scheduleSearch(newValue)
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    searchHits = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.fgFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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

    private func searchResults(_ hits: [TranscriptEntry]) -> some View {
        List(selection: $selection) {
            Section("\(hits.count) match\(hits.count == 1 ? "" : "es")") {
                ForEach(hits) { entry in
                    TranscriptRow(entry: entry, showDay: true)
                        .tag(entry)
                }
            }
        }
        .listStyle(.inset)
    }

    private var dayList: some View {
        List(selection: $selection) {
            ForEach(model.transcripts.days) { day in
                Section(Self.dayTitle(day.date)) {
                    ForEach(day.entries) { entry in
                        TranscriptRow(entry: entry, showDay: false)
                            .tag(entry)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(Theme.fgFaint)
            Text("No transcripts yet")
                .font(.system(size: 14, weight: .semibold))
            Text("Finished chunks land here as Markdown,\norganized by day.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.fgMuted)
                .multilineTextAlignment(.center)
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
            VStack {
                Spacer()
                Text("Select a transcript")
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
        if Calendar.current.isDateInToday(date) { return "Today · \(isoDay)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday · \(isoDay)" }
        let out = DateFormatter()
        out.dateFormat = "EEE · yyyy-MM-dd"
        return out.string(from: date)
    }
}

struct TranscriptRow: View {
    let entry: TranscriptEntry
    let showDay: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(entry.timeString)
                .meterFigure(size: 12)
                .foregroundStyle(Theme.fgMuted)
            VStack(alignment: .leading, spacing: 1) {
                Text("chunk \(String(format: "%03d", entry.chunkSeq))")
                    .font(.system(size: 12, weight: .medium))
                Text(showDay ? entry.url.deletingLastPathComponent().lastPathComponent : "session \(entry.sessionId8)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.fgFaint)
            }
            Spacer()
        }
        .padding(.vertical, 2)
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
            Divider().overlay(Theme.divider)
            if showRaw {
                ScrollView {
                    Text(document.rawBody)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else if document.isEmpty {
                VStack {
                    Spacer()
                    Text("(no speech detected in this chunk)")
                        .foregroundStyle(Theme.fgFaint)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(document.runs) { run in
                            RunRow(run: run)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $showRaw) {
                    Label("Raw Markdown", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .help("Show the raw Markdown")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .help("Reveal this file in Finder")
                Button {
                    NSWorkspace.shared.open(entry.url)
                } label: {
                    Label("Open", systemImage: "arrow.up.forward.app")
                }
                .help("Open in the default Markdown editor")
            }
        }
    }

    private func detailHeader(_ document: TranscriptDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(document.heading ?? entry.filename)
                .font(.system(size: 17, weight: .bold))
            HStack(spacing: 6) {
                MetaChip(
                    text: Self.durationText(document.meta.durationActualSeconds),
                    symbol: "clock")
                MetaChip(text: document.meta.model, symbol: "cpu")
                if document.meta.language != "" {
                    MetaChip(text: document.meta.language, symbol: "globe")
                }
                ForEach(document.meta.audioSources, id: \.self) { source in
                    MetaChip(
                        text: source == "microphone" ? "mic" : source,
                        symbol: source == "microphone" ? "mic" : "speaker.wave.2")
                }
                if document.meta.incomplete {
                    MetaChip(text: "incomplete", symbol: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warn)
                }
                Spacer()
            }
        }
        .padding(16)
    }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        return "\(total / 60)m \(total % 60)s"
    }
}

struct MetaChip: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10.5, design: .monospaced))
        }
        .foregroundStyle(Theme.fgMuted)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Theme.bgSunken.opacity(0.7)))
    }
}

struct RunRow: View {
    let run: TranscriptRun

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(run.time)
                    .meterFigure(size: 11)
                    .foregroundStyle(Theme.fgFaint)
                sourceBadge
            }
            .frame(width: 74, alignment: .trailing)
            Text(run.text)
                .font(.system(size: 13))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sourceBadge: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }

    private var label: String {
        switch run.source {
        case .mic: return "MIC"
        case .system: return "SYSTEM"
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
