// The persistent transport. Recording state and the controls that change it
// are chrome, not content: they live in the sidebar, so every pane has them at
// the same coordinates, and the box keeps one height in every state so
// starting or stopping a session never reflows the rail beneath it.
//
// The pulsing dot only proves the app believes it is recording. The two live
// meters — the same `MeterBar` the Record console uses — prove audio is
// actually arriving, which is the thing you really want to know from the
// Transcripts pane.
//
// Everything here is assembled from DESIGN.md's vocabulary rather than
// re-drawn: `Card` (bg-elev, radius 10, 1px border), `StatusPill` (compact),
// `MeterBar` (sunken track, spruce→amber→rec-red, peak tick), and the shared
// button styles. State color lives in the pill, never in the card's border —
// amber and rec-red are signal, never decoration.

import HuskeKit
import SwiftUI

struct TransportDock: View {
    @Environment(AppModel.self) private var model
    @Environment(\.screenRendering) private var screenRendering

    @State private var meterEngine = MeterEngine()
    /// Stop is two-step here: the ambient control is easy to hit by accident
    /// and a stop cannot be undone (restarting mints a new session id, so the
    /// recording splits). The Record console's labelled Stop and ⌘. stay
    /// single-action — going there is intent enough.
    @State private var stopArmed = false
    @State private var disarmTask: Task<Void, Never>?

    /// Content height, identical in every state — see the file comment. The
    /// live state is the tallest: pill + two meters + chunk line + controls.
    private static let contentHeight: CGFloat = 117
    private static let armedSeconds: UInt64 = 3

    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(height: Self.contentHeight, alignment: .top)
        }
        .animation(Theme.ease, value: status)
        .onChange(of: status) { _, new in
            disarmStop()
            announce(new)
        }
        .onChange(of: model.pane) { disarmStop() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording transport")
    }

    // MARK: state

    private enum Status: Equatable {
        case idle, starting, connecting, recording, paused, finishing, failed
    }

    private var status: Status {
        switch model.session.phase {
        case .idle: return .idle
        case .launching: return .starting
        case .failed: return .failed
        case .active:
            guard let snapshot = model.session.snapshot else { return .connecting }
            if snapshot.stopping { return .finishing }
            if snapshot.paused { return .paused }
            return snapshot.recording ? .recording : .connecting
        }
    }

    private var statusColor: Color {
        switch status {
        case .recording: return Theme.recordRed
        case .paused, .finishing, .starting: return Theme.warn
        case .failed: return Theme.err
        case .idle, .connecting: return Theme.fgFaint
        }
    }

    private var statusWord: String {
        switch status {
        case .idle: return "idle"
        case .starting: return "starting"
        case .connecting: return "connecting"
        case .recording: return "recording"
        case .paused: return "paused"
        case .finishing: return "finishing"
        case .failed: return "failed"
        }
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        switch model.session.phase {
        case .idle:
            idleContent
        case .launching(let statusText):
            pendingContent(statusText)
        case .failed(let message):
            failedContent(message)
        case .active:
            if let snapshot = model.session.snapshot {
                liveContent(snapshot)
            } else {
                pendingContent("connecting to the session…")
            }
        }
    }

    /// Idle is not a blank slot: it is where Start lives for every pane that
    /// isn't Record. Rec-red fill, matching the console's Start button — in
    /// this app red means "record", and it is the one primary action here.
    /// No `keyboardShortcut`: ⌘R is already bound by the app menu, which works
    /// from anywhere; this only advertises it.
    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusPill(text: statusWord, color: statusColor, compact: true)
            detailLine(idleSubtitle)
            Spacer(minLength: 0)
            Button {
                model.startRecording()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Start Recording")
                    Spacer(minLength: 0)
                    Text("⌘R")
                        .font(.brandMono(11))
                        .opacity(0.65)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(StopButtonStyle(size: .small))
            .disabled(model.engineOutdated)
            .help(
                model.engineOutdated
                    ? "Upgrade the engine before recording"
                    : "Start a recording session (⌘R)")
        }
    }

    /// The input that *would* be captured — more use than restating "idle",
    /// which the pill already says, and short enough not to truncate at 164pt.
    private var idleSubtitle: String {
        if model.engineOutdated { return "engine needs an upgrade" }
        let device = model.config.string("input_device")
        return device.isEmpty ? "system default input" : device
    }

    private func detailLine(_ text: String) -> some View {
        Text(text)
            .font(.brandMono(11))
            .foregroundStyle(Theme.fgMuted)
            .lineLimit(2)
            .truncationMode(.tail)
            .padding(.top, 10)
    }

    private func liveContent(_ snapshot: ControlSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                StatusPill(
                    text: statusWord,
                    color: statusColor,
                    pulsing: status == .recording,
                    compact: true)
                Spacer(minLength: 0)
                SessionClock(
                    startedAt: snapshot.sessionStartedAt,
                    endedAt: model.session.stopRequestedAt,
                    font: .brandMono(11, .medium),
                    // Dimmed while paused: the session clock still counts, but
                    // it is no longer counting recorded audio.
                    tint: status == .paused ? Theme.fgFaint : Theme.fgMuted)
            }

            meters(snapshot)
                .padding(.top, 10)

            Text(
                "chunk \(String(format: "%03d", snapshot.currentChunkSeq)) · queue \(snapshot.queueDepth)"
            )
            .font(.brandMono(11))
            .foregroundStyle(Theme.fgMuted)
            .padding(.top, 8)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Button {
                    disarmStop()
                    model.session.pauseResume()
                } label: {
                    controlLabel(
                        snapshot.paused ? "Resume" : "Pause",
                        symbol: snapshot.paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(SecondaryButtonStyle(size: .small))
                .disabled(snapshot.stopping)
                .help(snapshot.paused ? "Resume recording" : "Pause recording")

                stopButton(snapshot)
            }
        }
    }

    /// Secondary until armed, then the system's destructive fill — DESIGN.md
    /// reserves rec-red fill for Stop, and the armed click is the real stop.
    @ViewBuilder
    private func stopButton(_ snapshot: ControlSnapshot) -> some View {
        let action = {
            if stopArmed {
                disarmStop()
                model.session.requestStop()
            } else {
                armStop()
            }
        }
        let label = controlLabel(
            stopArmed ? "Confirm" : "Stop",
            symbol: stopArmed ? "checkmark" : "stop.fill")
        Group {
            if stopArmed {
                Button(action: action) { label }
                    .buttonStyle(StopButtonStyle(size: .small))
            } else {
                Button(action: action) { label }
                    .buttonStyle(SecondaryButtonStyle(size: .small))
            }
        }
        .disabled(snapshot.stopping)
        .help(
            stopArmed
                ? "Click again to stop — cancels itself in a moment"
                : "Stop recording (asks once more)")
        .accessibilityLabel(
            stopArmed ? "Confirm stop recording" : "Stop recording, needs confirmation")
    }

    private func controlLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
            Text(title)
        }
        .frame(maxWidth: .infinity)
    }

    /// 30 fps while audio is actually moving; a slow tick otherwise, so a
    /// paused session isn't redrawing flat bars at display rate.
    private func meters(_ snapshot: ControlSnapshot) -> some View {
        let quiet = snapshot.paused || snapshot.stopping
        return TimelineView(.animation(minimumInterval: quiet ? 0.5 : 1.0 / 30.0)) { context in
            let levels = meterEngine.sample(
                micDb: quiet ? -120 : snapshot.peakMicDb,
                systemDb: quiet ? -120 : snapshot.peakSystemDb,
                at: context.date)
            VStack(spacing: 5) {
                dockMeter("mic", levels.mic)
                dockMeter("sys", levels.system)
            }
        }
    }

    private func dockMeter(_ label: String, _ meter: SmoothedMeter) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.brandMono(11))
                .foregroundStyle(Theme.fgMuted)
                .frame(width: 22, alignment: .leading)
            MeterBar(level: meter.level, peak: meter.peak)
                .frame(height: 5)
        }
        .accessibilityElement()
        .accessibilityLabel("\(label) level")
        .accessibilityValue("\(Int(meter.level * 100)) percent")
    }

    private func pendingContent(_ statusText: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusPill(text: statusWord, color: statusColor, pulsing: true, compact: true)
            detailLine(statusText)
            Spacer(minLength: 0)
            Button { model.session.cancelLaunch() } label: {
                controlLabel("Cancel", symbol: "xmark")
            }
            .buttonStyle(SecondaryButtonStyle(size: .small))
            .help("Cancel starting the session")
        }
    }

    private func failedContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusPill(text: statusWord, color: statusColor, compact: true)
            detailLine(message)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Button { model.pane = .record } label: {
                    controlLabel("Details", symbol: "info.circle")
                }
                .buttonStyle(SecondaryButtonStyle(size: .small))
                .help("Open the Record pane")
                Button {
                    model.session.dismissFailure()
                    model.startRecording()
                } label: {
                    controlLabel("Retry", symbol: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle(size: .small))
                .help("Try starting again")
            }
        }
    }

    // MARK: two-step stop

    private func armStop() {
        stopArmed = true
        disarmTask?.cancel()
        disarmTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.armedSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            stopArmed = false
        }
    }

    private func disarmStop() {
        disarmTask?.cancel()
        disarmTask = nil
        stopArmed = false
    }

    // MARK: VoiceOver

    /// Without this a VoiceOver user gets no signal that recording started or
    /// stopped — the same gap this dock exists to close, only worse.
    private func announce(_ status: Status) {
        guard !screenRendering else { return }
        let message: String
        switch status {
        case .recording: message = "Recording started"
        case .paused: message = "Recording paused"
        case .finishing: message = "Finishing — transcribing the remaining audio"
        case .idle: message = "Recording stopped"
        case .failed: message = "Recording session failed"
        case .starting, .connecting: return
        }
        AccessibilityNotification.Announcement(message).post()
    }
}
