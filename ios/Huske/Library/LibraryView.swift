// Recordings grouped by day, newest first — Voice Memos' shape, huske's
// voice: quiet day labels, the title with its duration, then either what was
// said (serif excerpt) or where the recording is (state ring + words).

import SwiftUI

struct LibraryView: View {
    let library: LibraryStore
    let sync: SyncManager
    let recorder: RecorderController
    var onPairTapped: () -> Void

    @State private var pendingDelete: Recording?
    @State private var renameTarget: Recording?
    @State private var draftTitle = ""

    var body: some View {
        let sections = library.sections()
        Group {
            if sections.isEmpty {
                EmptyLibraryView(isPaired: sync.isPaired, onPairTapped: onPairTapped)
            } else {
                List {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.recordings) { recording in
                                // Hidden link: row navigation without the disclosure chevron.
                                RecordingRow(recording: recording, badge: sync.badge(for: recording),
                                             onRetry: { sync.retry(recording.id) })
                                    .background(NavigationLink(value: recording.id) { EmptyView() }.opacity(0))
                                .listRowBackground(Brand.bg)
                                .listRowSeparatorTint(Brand.divider)
                                .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 16))
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if recording.capture != .inProgress {
                                        Button("Delete", systemImage: "trash", role: .destructive) {
                                            pendingDelete = recording
                                        }
                                        .tint(Brand.err)
                                    }
                                }
                                .contextMenu {
                                    Button("Rename", systemImage: "pencil") {
                                        draftTitle = recording.title
                                        renameTarget = recording
                                    }
                                    if recording.capture == .complete {
                                        ShareLink(item: library.audioURL(for: recording)) {
                                            Label("Share Audio", systemImage: "square.and.arrow.up")
                                        }
                                    }
                                    if recording.capture != .inProgress {
                                        Button("Delete", systemImage: "trash", role: .destructive) {
                                            pendingDelete = recording
                                        }
                                    }
                                }
                            }
                        } header: {
                            SectionHeader(day: section.day, count: section.recordings.count)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Brand.bg)
        .confirmationDialog(
            pendingDelete.map { "Delete “\($0.title)”?" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { recording in
            Button("Delete Recording", role: .destructive) {
                withAnimation(Brand.ease) { library.delete(recording.id) }
            }
        } message: { recording in
            Text(deleteMessage(for: recording))
        }
        .alert("Rename recording", isPresented: Binding(
            get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
        ) {
            TextField("Title", text: $draftTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let target = renameTarget {
                    if target.id == recorder.recordingID {
                        recorder.renameCurrent(to: draftTitle)
                    } else {
                        library.rename(target.id, to: draftTitle)
                    }
                }
            }
        }
    }

    private func deleteMessage(for recording: Recording) -> String {
        if recording.transcript != nil || recording.sync.uploadedAt != nil {
            return "This removes the audio and transcript from this iPhone. The copy on \(sync.macName) is kept."
        }
        return "This recording hasn't reached your Mac yet. Deleting it removes it for good."
    }
}

private struct SectionHeader: View {
    let day: Date
    let count: Int

    var body: some View {
        Text(Format.dayHeader(day))
            .font(.plexSans(13, .medium, relativeTo: .footnote))
            .foregroundStyle(Brand.fgMuted)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel("\(Format.dayHeader(day)), \(count) recordings")
            .padding(.horizontal, 4)
            .padding(.top, 18)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.bg)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }
}

struct RecordingRow: View {
    let recording: Recording
    let badge: SyncBadge
    /// The way out beside a failure that Retry can fix.
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(recording.title)
                    .font(.plexSans(17, .medium, relativeTo: .headline))
                    .foregroundStyle(Brand.fg)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(recording.capture == .damaged && recording.duration == 0
                     ? "—" : Format.duration(recording.duration))
                    .font(.plexMono(13, relativeTo: .subheadline))
                    .foregroundStyle(Brand.fgMuted)
                    .monospacedDigit()
            }
            if let excerpt {
                Text(excerpt)
                    .font(.plexSerif(15.5, relativeTo: .subheadline))
                    .foregroundStyle(Brand.fg.opacity(0.72))
                    .lineSpacing(2)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Text(Format.clock(recording.startedAt))
                    .font(.plexSans(13, relativeTo: .footnote))
                    .foregroundStyle(Brand.fgFaint)
                    .monospacedDigit()
                SyncBadgeView(badge: badge, onRetry: onRetry)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var excerpt: String? {
        guard let markdown = recording.transcript?.markdown else { return nil }
        return TranscriptParser.excerpt(markdown)
    }

    private var accessibilityText: String {
        "\(recording.title), \(Format.clock(recording.startedAt)), \(Format.spokenDuration(recording.duration)), \(badge.accessibilityLabel)"
    }
}

private struct PairPromptRow: View {
    var onPairTapped: () -> Void

    var body: some View {
        Button(action: onPairTapped) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pair your Mac")
                    .font(.plexSans(16, .medium, relativeTo: .headline))
                    .foregroundStyle(Brand.amber)
                Text("Recordings go to Huske on your Mac and come back as transcripts.")
                    .font(.plexSans(14, relativeTo: .subheadline))
                    .foregroundStyle(Brand.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct EmptyLibraryView: View {
    let isPaired: Bool
    var onPairTapped: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 10) {
                Text("Nothing recorded yet.")
                    .font(.plexSerif(26, relativeTo: .title))
                    .foregroundStyle(Brand.fg)
                Text("Press record. Your Mac transcribes it, and the words come back here.")
                    .font(.plexSans(16, relativeTo: .body))
                    .foregroundStyle(Brand.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            if !isPaired {
                PairPromptRow(onPairTapped: onPairTapped)
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
