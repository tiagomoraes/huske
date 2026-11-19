// One recording, laid out like a document: date, title, where it is (one
// sentence beside its state ring), the player, then what was said in serif
// with its timecodes in the margin, and the quiet details last.

import SwiftUI

struct RecordingDetailView: View {
    let recordingID: String
    let library: LibraryStore
    let sync: SyncManager
    let recorder: RecorderController

    @State private var player = AudioPlayerModel()
    @State private var renaming = false
    @State private var draftTitle = ""
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let recording = library.recording(id: recordingID) {
                content(recording)
            } else {
                ContentUnavailableView("Recording deleted", systemImage: "waveform.slash")
                    .foregroundStyle(Brand.fgMuted)
            }
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Brand.bg, for: .navigationBar)
        .onDisappear { player.stop() }
    }

    @ViewBuilder
    private func content(_ recording: Recording) -> some View {
        let badge = sync.badge(for: recording)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(recording, badge: badge)
                if recording.capture == .complete {
                    PlayerCard(player: player, recordingActive: recorder.phase.isActive)
                } else if recording.capture == .inProgress {
                    Card {
                        Label("Recording in progress", systemImage: "record.circle")
                            .font(.plexSans(15, .medium))
                            .foregroundStyle(Brand.recordRed)
                    }
                }
                if let note = recording.note {
                    NoteBanner(text: note, isError: recording.capture == .damaged)
                }
                TranscriptSection(recording: recording, badge: badge, macName: sync.macName)
                DetailsCard(recording: recording, macName: sync.macName)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .task(id: recording.capture) {
            // Off the main thread and without touching audio hardware: a
            // synchronous AVAudioPlayer prepare here stalls the push transition.
            if recording.capture == .complete {
                await player.load(url: library.audioURL(for: recording), fallbackDuration: recording.duration)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if recording.capture == .complete {
                    ShareLink(item: library.audioURL(for: recording),
                              preview: SharePreview(recording.title, image: Image(systemName: "waveform"))) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share audio")
                }
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        draftTitle = recording.title
                        renaming = true
                    }
                    if let markdown = recording.transcript?.markdown {
                        ShareLink(item: markdown) {
                            Label("Share Transcript", systemImage: "text.quote")
                        }
                        Button("Copy Transcript", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = markdown
                        }
                    }
                    if recording.capture != .inProgress {
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            confirmingDelete = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
        .tint(Brand.amber)
        .alert("Rename recording", isPresented: $renaming) {
            TextField("Title", text: $draftTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if recording.id == recorder.recordingID {
                    recorder.renameCurrent(to: draftTitle)
                } else {
                    library.rename(recording.id, to: draftTitle)
                }
            }
        }
        .confirmationDialog("Delete “\(recording.title)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Recording", role: .destructive) {
                player.stop()
                library.delete(recording.id)
                dismiss()
            }
        } message: {
            Text(recording.sync.uploadedAt != nil || recording.transcript != nil
                 ? "This removes it from this iPhone. The copy on \(sync.macName) is kept."
                 : "This recording hasn't reached your Mac yet. Deleting it removes it for good.")
        }
    }

    private func header(_ recording: Recording, badge: SyncBadge) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(recording.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide))
                 + " · " + Format.clock(recording.startedAt) + " · " + Format.duration(recording.duration))
                .font(.plexSans(13, relativeTo: .footnote))
                .foregroundStyle(Brand.fgMuted)
                .monospacedDigit()
            Button {
                draftTitle = recording.title
                renaming = true
            } label: {
                Text(recording.title)
                    .font(.plexSerif(30, relativeTo: .title))
                    .foregroundStyle(Brand.fg)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Double-tap to rename")
            SyncStatusLine(recording: recording, badge: badge, sync: sync)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - player

private struct PlayerCard: View {
    let player: AudioPlayerModel
    let recordingActive: Bool

    var body: some View {
        Card(padding: 18) {
            VStack(spacing: 14) {
                Scrubber(player: player)
                HStack {
                    Text(Format.duration(player.currentTime))
                    Spacer()
                    Text("−" + Format.duration(max(0, player.duration - player.currentTime)))
                }
                .font(.plexMono(12, .medium, relativeTo: .caption))
                .foregroundStyle(Brand.fgMuted)
                .monospacedDigit()
                .accessibilityHidden(true)

                HStack(spacing: 28) {
                    Button { player.skip(by: -15) } label: {
                        Image(systemName: "gobackward.15")
                    }
                    .buttonStyle(CircleIconButtonStyle(diameter: 60, fill: .clear, bordered: false))
                    .accessibilityLabel("Back 15 seconds")

                    Button { player.togglePlay(recordingActive: recordingActive) } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .offset(x: player.isPlaying ? 0 : 2)
                    }
                    .buttonStyle(CircleIconButtonStyle(diameter: 64, fill: Brand.amber, foreground: Brand.fgOnAmber, bordered: false))
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                    Button { player.skip(by: 15) } label: {
                        Image(systemName: "goforward.15")
                    }
                    .buttonStyle(CircleIconButtonStyle(diameter: 60, fill: .clear, bordered: false))
                    .accessibilityLabel("Forward 15 seconds")
                }
                .disabled(!player.isAvailable || recordingActive)

                if !player.isAvailable {
                    Text("The audio file isn't available on this iPhone.")
                        .font(.plexSans(13, relativeTo: .footnote))
                        .foregroundStyle(Brand.fgMuted)
                } else if recordingActive {
                    Text("Playback is off while recording.")
                        .font(.plexSans(13, relativeTo: .footnote))
                        .foregroundStyle(Brand.fgMuted)
                }
            }
        }
    }
}

/// Thin terminal-precise scrubber: sunken track, amber progress, fg knob.
private struct Scrubber: View {
    let player: AudioPlayerModel
    @State private var dragValue: Double?

    var body: some View {
        GeometryReader { geo in
            let progress = fraction
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.bgSunken).frame(height: 4)
                Capsule().fill(Brand.amber).frame(width: max(4, geo.size.width * progress), height: 4)
                Circle()
                    .fill(Brand.fg)
                    .frame(width: dragValue == nil ? 12 : 18, height: dragValue == nil ? 12 : 18)
                    .offset(x: geo.size.width * progress - (dragValue == nil ? 6 : 9))
                    .animation(Brand.easeFast, value: dragValue == nil)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        player.isScrubbing = true
                        dragValue = min(max(0, value.location.x / geo.size.width), 1)
                    }
                    .onEnded { value in
                        let target = min(max(0, value.location.x / geo.size.width), 1)
                        player.seek(to: target * player.duration)
                        dragValue = nil
                        player.isScrubbing = false
                    })
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(Format.spokenDuration(player.currentTime))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.skip(by: 15)
            case .decrement: player.skip(by: -15)
            @unknown default: break
            }
        }
    }

    private var fraction: Double {
        if let dragValue { return dragValue }
        guard player.duration > 0 else { return 0 }
        return min(1, player.currentTime / player.duration)
    }
}

// MARK: - sync status

/// Where this recording is, as one sentence beside its state ring.
private struct SyncStatusLine: View {
    let recording: Recording
    let badge: SyncBadge
    let sync: SyncManager

    var body: some View {
        if let line = statusLine {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StateRing(kind: badge.ringKind, size: 12)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                VStack(alignment: .leading, spacing: 6) {
                    Text(line)
                        .font(.plexSans(15, relativeTo: .subheadline))
                        .foregroundStyle(badge.isProblem ? Brand.err : Brand.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .failed = badge {
                        Button("Try again") { sync.retry(recording.id) }
                            .font(.plexSans(15, .medium, relativeTo: .subheadline))
                            .foregroundStyle(Brand.amber)
                            .buttonStyle(.plain)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var statusLine: String? {
        let mac = sync.macName
        switch badge {
        case .recording: return "Recording now."
        case .damaged: return "This recording was cut off and can't be sent."
        case .onPhone: return "On this iPhone. Pair your Mac to have it transcribed."
        case .waitingForMac:
            return sync.lastError ?? (sync.isMacReachable
                ? "Ready to send to \(mac)."
                : "Waiting for \(mac). Open Huske on your Mac.")
        case let .uploading(fraction): return "Sending to \(mac) · \(Int(fraction * 100))%"
        case .onMac:
            return sync.engineAvailable == false
                ? "On \(mac). It's transcribed once Huske's engine is set up there."
                : "On \(mac), about to be transcribed."
        case .queued: return "On \(mac), next in line to be transcribed."
        case let .transcribing(done, total, _):
            if let done, let total, total > 1 { return "\(mac) is transcribing it · \(done) of \(total)" }
            return "\(mac) is transcribing it."
        case .transcribed:
            if let fetched = recording.transcript?.fetchedAt {
                return "Transcribed on \(mac) · \(Format.relative(fetched))"
            }
            return "Transcribed on \(mac)"
        case let .failed(reason):
            if recording.sync.failure != nil { return reason ?? "Couldn't send this recording." }
            return "\(mac) couldn't transcribe it" + (reason.map { ": \($0)" } ?? ".")
        }
    }
}

// MARK: - transcript

private struct TranscriptSection: View {
    let recording: Recording
    let badge: SyncBadge
    let macName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Rectangle().fill(Brand.divider).frame(height: 1)
            if let markdown = recording.transcript?.markdown, !markdown.isEmpty {
                TranscriptView(blocks: TranscriptParser.parse(markdown))
            } else if recording.transcript != nil {
                placeholder("\(macName) heard no speech in this recording.")
            } else if recording.capture == .complete {
                placeholder("The words appear here once \(macName) has transcribed it.")
            } else {
                placeholder("No transcript.")
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.plexSerif(17, relativeTo: .body))
            .foregroundStyle(Brand.fgFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What was said, set like a document: serif text, timecodes in the margin.
/// The source is named only when it isn't the microphone (a call, a video).
struct TranscriptView: View {
    let blocks: [TranscriptBlock]

    private let margin: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(visible) { block in
                switch block {
                case let .heading(text):
                    Text(text)
                        .font(.plexSans(12, relativeTo: .caption))
                        .foregroundStyle(Brand.fgFaint)
                        .lineLimit(1)
                        .padding(.leading, margin)
                        .accessibilityAddTraits(.isHeader)
                case let .run(time, source, text):
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(marginTimes[block.id] ?? "")
                                .font(.plexMono(11.5, relativeTo: .caption))
                                .foregroundStyle(Brand.fgFaint)
                                .monospacedDigit()
                            if !Self.isMic(source) {
                                Text(source)
                                    .font(.plexSans(11, relativeTo: .caption2))
                                    .foregroundStyle(Brand.fgFaint)
                            }
                        }
                        .frame(width: margin, alignment: .leading)
                        Text(text)
                            .font(.plexSerif(18, relativeTo: .body))
                            .foregroundStyle(Brand.fg)
                            .lineSpacing(6)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                case let .paragraph(text):
                    Text(LocalizedStringKey(text))
                        .font(.plexSerif(18, relativeTo: .body))
                        .foregroundStyle(text.hasPrefix("_(") ? Brand.fgMuted : Brand.fg)
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, margin)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One chunk's "09:30 – 09:45" heading repeats the date line above the
    /// transcript, so only multi-chunk transcripts keep their headings.
    private var visible: [TranscriptBlock] {
        let headings = blocks.filter { if case .heading = $0 { return true }; return false }.count
        guard headings <= 1 else { return blocks }
        return blocks.filter { if case .heading = $0 { return false }; return true }
    }

    /// The margin shows a time only when it changes from the run above.
    private var marginTimes: [TranscriptBlock.ID: String] {
        var out: [TranscriptBlock.ID: String] = [:]
        var last: String?
        for block in blocks {
            guard case let .run(time, _, _) = block else { continue }
            let short = String(time.prefix(5))
            if short != last { out[block.id] = short }
            last = short
        }
        return out
    }

    static func isMic(_ source: String) -> Bool {
        let s = source.lowercased()
        return s == "mic" || s == "microphone" || s.isEmpty
    }
}

// MARK: - details

private struct DetailsCard: View {
    let recording: Recording
    let macName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(Brand.divider).frame(height: 1).padding(.bottom, 8)
            row("Recorded", recording.startedAt.formatted(date: .abbreviated, time: .shortened))
            row("Length", Format.duration(recording.duration), mono: true)
            row("Size", recording.byteCount > 0 ? Format.bytes(recording.byteCount) : "—")
            row("Format", "AAC, 48 kHz, mono")
            if let input = recording.inputName { row("Microphone", input) }
            if let uploaded = recording.sync.uploadedAt {
                row("Sent to \(macName)", uploaded.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(Brand.fgMuted)
                .fixedSize()
            Spacer(minLength: 12)
            Text(value)
                .font(mono ? .plexMono(13, relativeTo: .footnote) : .plexSans(14, relativeTo: .footnote))
                .foregroundStyle(Brand.fg)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(.plexSans(14, relativeTo: .footnote))
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

private struct NoteBanner: View {
    let text: String
    let isError: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(isError ? Brand.err : Brand.info)
            Text(text)
                .font(.plexSans(15, relativeTo: .subheadline))
                .foregroundStyle(Brand.fg)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Brand.radiusLG, style: .continuous)
                .fill((isError ? Brand.err : Brand.info).opacity(0.1)))
    }
}
