// ⌘K command palette — every app action one keystroke away. Mounted once as
// a full-window overlay in RootView and shown/hidden from
// AppModel.paletteVisible (the ⌘K menu item toggles it). Lists only the
// commands that are currently available, fuzzy-filters them by title, and
// runs entirely from the keyboard: ↑↓ select, ↩ runs, esc clears then
// dismisses.

import AppKit
import HuskeKit
import SwiftUI

// MARK: - overlay

struct CommandPaletteOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    @Environment(\.screenRendering) private var screenRendering

    @State private var query = ""
    /// Index into `filteredCommands` — the flat order ↑↓ walk (across
    /// sections when unfiltered).
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .top) {
            if model.paletteVisible {
                scrim
                panelColumn
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .animation(Theme.easeFast, value: model.paletteVisible)
        .onChange(of: model.paletteVisible) { _, visible in
            if visible {
                query = ""
                selectedIndex = 0
            }
        }
        .onChange(of: searchFocused) { _, focused in
            // Keep the keyboard anchored to the search field while open.
            if !focused, model.paletteVisible {
                searchFocused = true
            }
        }
    }

    // MARK: chrome

    private var scrim: some View {
        Color.black.opacity(0.20)
            .onTapGesture { close() }
            .transition(.opacity)
            .accessibilityHidden(true)
    }

    private var panelColumn: some View {
        VStack(spacing: 0) {
            panel
                .frame(width: 560)
            Spacer(minLength: 0)
        }
        .padding(.top, 90)
        .transition(
            reduceMotion
                ? .opacity
                : .opacity.combined(with: .scale(scale: 0.98)))
    }

    private var panel: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                searchRow(proxy: proxy)
                hairline
                commandList
                hairline
                footer
            }
            .onChange(of: filteredCommands.map(\.id)) { _, ids in
                if selectedIndex >= ids.count {
                    selectedIndex = 0
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous)
                .fill(Theme.bgElevated)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous)
                .strokeBorder(Theme.cardBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 24, y: 8)
        .onExitCommand { handleEscape() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    private var hairline: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(height: 1)
    }

    private func searchRow(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.fgMuted)
            if screenRendering {
                // ImageRenderer draws AppKit text fields as placeholders;
                // stand in with the same prompt for offscreen renders.
                Text("Type a command…")
                    .font(.brandSans(14))
                    .foregroundStyle(Theme.fgMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(
                    "",
                    text: $query,
                    prompt: Text("Type a command…")
                        .font(.brandSans(14))
                        .foregroundStyle(Theme.fgMuted)
                )
                .textFieldStyle(.plain)
                .font(.brandSans(14))
                .foregroundStyle(Theme.fg)
                .focused($searchFocused)
                .onAppear { searchFocused = true }
                .onSubmit { runSelected() }
                .onChange(of: query) { _, _ in selectedIndex = 0 }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1, proxy: proxy)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1, proxy: proxy)
                    return .handled
                }
                .onKeyPress(.escape) {
                    handleEscape()
                    return .handled
                }
                .accessibilityLabel("Search commands")
                .accessibilityAddTraits(.isSearchField)
            }
            escChip
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var escChip: some View {
        Text("esc")
            .font(.brandMono(10))
            .foregroundStyle(Theme.fgMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous)
                    .fill(Theme.bgSunken.opacity(0.65))
            )
    }

    @ViewBuilder
    private var commandList: some View {
        let filtered = filteredCommands
        let rows = filtered.enumerated().map { PaletteRow(index: $0.offset, command: $0.element) }
        if rows.isEmpty {
            Text("No matching command")
                .font(.brandSans(12.5))
                .foregroundStyle(Theme.fgFaint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
        } else if screenRendering {
            // ImageRenderer skips ScrollView content; render the plain stack.
            listStack(rows)
        } else {
            // Hug the content when it fits; cap at ~360 and scroll when not.
            ViewThatFits(in: .vertical) {
                listStack(rows)
                ScrollView {
                    listStack(rows)
                }
            }
            .frame(maxHeight: 360)
        }
    }

    private func listStack(_ rows: [PaletteRow]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if isFiltering {
                // Ranked flat list, no section headers.
                ForEach(rows) { row in
                    rowView(row)
                }
            } else {
                ForEach(paletteGroups(rows)) { group in
                    sectionHeader(group.section.rawValue)
                    ForEach(group.rows) { row in
                        rowView(row)
                    }
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowView(_ row: PaletteRow) -> some View {
        PaletteRowView(
            command: row.command,
            selected: row.index == selectedIndex,
            select: { selectedIndex = row.index },
            run: { run(row.command) }
        )
        .id(row.command.id)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.brandMono(10, .medium))
            .kerning(1.0)
            .foregroundStyle(Theme.fgMuted)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private var footer: some View {
        Text("↑↓ navigate · ↩ run · esc dismiss")
            .font(.brandMono(10.5))
            .foregroundStyle(Theme.fgFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
    }

    // MARK: selection + dispatch

    private func moveSelection(by delta: Int, proxy: ScrollViewProxy) {
        let commands = filteredCommands
        guard !commands.isEmpty else { return }
        let target = min(max(selectedIndex + delta, 0), commands.count - 1)
        guard target != selectedIndex else { return }
        selectedIndex = target
        withAnimation(Theme.easeFast) {
            proxy.scrollTo(commands[target].id, anchor: nil)
        }
    }

    private func runSelected() {
        let commands = filteredCommands
        guard commands.indices.contains(selectedIndex) else { return }
        run(commands[selectedIndex])
    }

    private func run(_ command: PaletteCommand) {
        command.action()
        close()
    }

    /// Esc clears a non-empty query first; a second esc dismisses.
    private func handleEscape() {
        if query.isEmpty {
            close()
        } else {
            query = ""
        }
    }

    private func close() {
        model.paletteVisible = false
    }

    // MARK: command catalog

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private var isFiltering: Bool {
        !trimmedQuery.isEmpty
    }

    /// The filtered flat order: everything available when the query is
    /// empty, otherwise fuzzy-ranked matches (ties keep catalog order).
    private var filteredCommands: [PaletteCommand] {
        let commands = availableCommands
        let q = trimmedQuery
        guard !q.isEmpty else { return commands }
        var ranked: [(rank: Int, order: Int, command: PaletteCommand)] = []
        for (order, command) in commands.enumerated() {
            if let rank = FuzzyMatcher.rank(query: q, title: command.title) {
                ranked.append((rank: rank, order: order, command: command))
            }
        }
        return ranked
            .sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }
            .map { $0.command }
    }

    /// Only commands whose preconditions hold are listed (hidden, not
    /// disabled). Section order: Session, Navigate, Tools.
    private var availableCommands: [PaletteCommand] {
        var commands: [PaletteCommand] = []
        let session = model.session
        let snapshot = session.snapshot

        // Session
        if !session.isBusy, !model.binaryMissing, !model.engineOutdated {
            commands.append(
                PaletteCommand(
                    id: "session.start",
                    title: "Start Recording",
                    symbol: "record.circle",
                    section: .session,
                    shortcut: "⌘R",
                    action: { [model] in
                        model.startRecording()
                        model.pane = .record
                    }))
        }
        if session.isBusy, !session.isDraining {
            commands.append(
                PaletteCommand(
                    id: "session.stop",
                    title: "Stop Recording",
                    symbol: "stop.circle",
                    section: .session,
                    shortcut: "⌘.",
                    action: { session.requestStop() }))
        }
        if session.isBusy, let snapshot, !snapshot.stopping {
            commands.append(
                PaletteCommand(
                    id: "session.pause-resume",
                    title: snapshot.paused ? "Resume Recording" : "Pause Recording",
                    symbol: snapshot.paused ? "play.circle" : "pause.circle",
                    section: .session,
                    action: { session.pauseResume() }))
        }
        if session.isBusy, let snapshot {
            commands.append(
                PaletteCommand(
                    id: "session.screenshots",
                    title: snapshot.screenshotsEnabled ? "Disable Screenshots" : "Enable Screenshots",
                    symbol: "camera",
                    section: .session,
                    action: { session.toggleScreenshots() }))
            commands.append(
                PaletteCommand(
                    id: "session.distill",
                    title: snapshot.distillEnabled ? "Disable Distillation" : "Enable Distillation",
                    symbol: "sparkles",
                    section: .session,
                    action: { session.toggleDistill() }))
        }

        // Navigate
        for (offset, pane) in Pane.allCases.enumerated() {
            commands.append(
                PaletteCommand(
                    id: "navigate.\(pane.rawValue)",
                    title: "Go to \(pane.title)",
                    symbol: pane.symbol,
                    section: .navigate,
                    shortcut: "⌘\(offset + 1)",
                    action: { [model] in model.pane = pane }))
        }
        commands.append(
            PaletteCommand(
                id: "navigate.search-transcripts",
                title: "Search Transcripts",
                symbol: "magnifyingglass",
                section: .navigate,
                action: { [model] in model.focusTranscriptSearch() }))

        // Tools
        if !model.doctorRunning, !model.binaryMissing {
            commands.append(
                PaletteCommand(
                    id: "tools.doctor",
                    title: "Run Doctor Checks",
                    symbol: "stethoscope",
                    section: .tools,
                    action: { [model] in
                        model.pane = .doctor
                        model.runDoctor()
                    }))
        }
        if !model.recoverRunning, !model.binaryMissing {
            commands.append(
                PaletteCommand(
                    id: "tools.recover",
                    title: "Recover Orphaned Audio",
                    symbol: "bandage",
                    section: .tools,
                    action: { [model] in model.runRecover() }))
        }
        commands.append(
            PaletteCommand(
                id: "tools.open-transcripts",
                title: "Open Transcripts Folder",
                symbol: "folder",
                section: .tools,
                action: { [model] in
                    if model.session.isBusy {
                        model.session.send(.openTranscripts)
                    } else if let root = model.transcripts.root {
                        NSWorkspace.shared.open(root)
                    }
                }))
        commands.append(
            PaletteCommand(
                id: "tools.settings",
                title: "Open App Settings",
                symbol: "gearshape",
                section: .tools,
                shortcut: "⌘,",
                action: { [openSettings] in openSettings() }))
        return commands
    }

    /// Groups an already section-ordered flat list for the unfiltered view.
    private func paletteGroups(_ rows: [PaletteRow]) -> [PaletteGroup] {
        var groups: [PaletteGroup] = []
        for row in rows {
            if let last = groups.indices.last, groups[last].section == row.command.section {
                groups[last].rows.append(row)
            } else {
                groups.append(PaletteGroup(section: row.command.section, rows: [row]))
            }
        }
        return groups
    }
}

// MARK: - command model

/// One palette entry. Availability is decided while building the catalog,
/// so every command in the list is runnable.
private struct PaletteCommand: Identifiable {
    enum Section: String, Equatable {
        case session = "Session"
        case navigate = "Navigate"
        case tools = "Tools"
    }

    let id: String
    let title: String
    var subtitle: String?
    let symbol: String
    let section: Section
    var shortcut: String?
    let action: @MainActor () -> Void

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        symbol: String,
        section: Section,
        shortcut: String? = nil,
        action: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.section = section
        self.shortcut = shortcut
        self.action = action
    }
}

/// A command plus its position in the filtered flat order.
private struct PaletteRow: Identifiable {
    let index: Int
    let command: PaletteCommand

    var id: String { command.id }
}

private struct PaletteGroup: Identifiable {
    let section: PaletteCommand.Section
    var rows: [PaletteRow]

    var id: String { section.rawValue }
}

// MARK: - fuzzy matching

/// Case-insensitive subsequence match over the title with a three-tier
/// rank: prefix (0) beats word-boundary starts (1) beats plain
/// subsequence (2). Non-matches rank nil.
private enum FuzzyMatcher {
    static func rank(query: String, title: String) -> Int? {
        let q = query.lowercased()
        let t = title.lowercased()
        guard !q.isEmpty else { return 0 }
        guard isSubsequence(Array(q), of: Array(t)) else { return nil }
        if t.hasPrefix(q) { return 0 }
        if wordAligned(Array(q), title: t) { return 1 }
        return 2
    }

    private static func isSubsequence(_ needle: [Character], of haystack: [Character]) -> Bool {
        var matched = 0
        for ch in haystack where matched < needle.count {
            if ch == needle[matched] { matched += 1 }
        }
        return matched == needle.count
    }

    /// The query lines up with word starts: some word carries the whole
    /// query as a prefix, or the query walks the word initials
    /// ("gtr" → "Go to Record").
    private static func wordAligned(_ needle: [Character], title: String) -> Bool {
        let words = title.split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: { $0.starts(with: needle) }) { return true }
        return isSubsequence(needle, of: words.compactMap(\.first))
    }
}

// MARK: - row

private struct PaletteRowView: View {
    let command: PaletteCommand
    let selected: Bool
    let select: @MainActor () -> Void
    let run: @MainActor () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: run) {
            HStack(spacing: 10) {
                Image(systemName: command.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Theme.amber : Theme.fgMuted)
                    .frame(width: 20)
                Text(command.title)
                    .font(.brandSans(13))
                    .foregroundStyle(Theme.fg)
                if let subtitle = command.subtitle {
                    Text(subtitle)
                        .font(.brandSans(11))
                        .foregroundStyle(Theme.fgFaint)
                }
                Spacer(minLength: 12)
                if let shortcut = command.shortcut {
                    Text(shortcut)
                        .font(.brandMono(10))
                        .foregroundStyle(Theme.fgMuted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radiusXS, style: .continuous)
                                .fill(Theme.bgSunken.opacity(0.5))
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMD, style: .continuous)
                    .fill(selected ? Theme.amber.opacity(0.14) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusMD, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingCursor(hovering: $hovering)
        .onChange(of: hovering) { _, isOver in
            if isOver { select() }
        }
        .accessibilityLabel(command.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
